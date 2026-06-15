//
//  MacFitEstimator.swift
//  LLM Seeker
//

import Foundation

enum MacFit: String, Equatable {
    case comfortable = "Comfortable"
    case tight = "Tight"
    case overflow = "Overflow"

    var description: String {
        switch self {
        case .comfortable: return "Model runs smoothly with good headroom"
        case .tight: return "Model fits but may swap to disk during generation"
        case .overflow: return "Insufficient RAM; model will be swapped heavily"
        }
    }
}

struct MacFitEstimate {
    let fit: MacFit
    let estimatedTokensPerSec: String
    let requiredGB: Double
    let availableGB: Double
    let headroomGB: Double
}

struct MacFitEstimator {
    private static let systemReserveGB: Double = 4.0

    // bits per weight by quantization tag
    static func bitsPerWeightForQuantization(_ quant: String) -> Double {
        let s = quant.lowercased()
        if s.contains("mxfp4") { return 4.5 }
        if s.contains("q4") || s.contains("4bit") || s.contains("4-bit") { return 4.0 }
        if s.contains("q8") || s.contains("8bit") || s.contains("8-bit") { return 8.0 }
        if s.contains("bf16") || s.contains("fp16") || s.contains("16bit") { return 16.0 }
        return 16.0
    }

    static func inferParamCount(fromRepoName repoName: String, fromParamTag paramTag: String? = nil) -> Double? {
        if let tag = paramTag?.lowercased(), let parsed = parseParamFromTag(tag) {
            return parsed
        }
        return inferParamCountFromText(repoName)
    }

    static func inferParamCountFromText(_ text: String) -> Double? {
        let s = text.lowercased()
        let billionPatterns = [
            #"(\d+(?:\.\d+)?)\s*b"#,
            #"a(\d+(?:\.\d+)?)\s*b"#,
        ]
        for pattern in billionPatterns {
            if let r = s.range(of: pattern, options: .regularExpression) {
                let token = String(s[r])
                let numeric = token
                    .replacingOccurrences(of: "a", with: "")
                    .replacingOccurrences(of: "b", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let v = Double(numeric), v > 0 { return v }
            }
        }
        if let r = s.range(of: #"(\d+(?:\.\d+)?)\s*m"#, options: .regularExpression) {
            let token = String(s[r])
            let numeric = token.replacingOccurrences(of: "m", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let m = Double(numeric), m > 0 { return m / 1000.0 }
        }
        return nil
    }

    private static func parseParamFromTag(_ tag: String) -> Double? {
        let parts = tag.split(separator: ":")
        for part in parts {
            let p = String(part).lowercased()
            for needle in ["1b", "3b", "7b", "13b", "14b", "27b", "32b", "35b", "50b", "70b", "100b", "120b"] {
                if p.contains(needle), let v = Double(needle.replacingOccurrences(of: "b", with: "")) {
                    return v
                }
            }
        }
        return nil
    }

    static func estimateModelSizeGB(paramCountB: Double, quantBitsPerWeight: Double) -> Double {
        let weightsGB = (paramCountB * 1e9 * quantBitsPerWeight) / (8.0 * 1e9)
        return weightsGB * 1.1
    }

    static func estimateKVCacheSizeGB(paramCountB: Double, contextLength: Int = 4096) -> Double {
        return (paramCountB * Double(contextLength) * 2.0) / 1e9
    }

    static func estimateFit(
        paramCountB: Double,
        quantization: String,
        macProfile: MacProfile,
        contextLength: Int = 4096
    ) -> MacFitEstimate {
        let quantBits = bitsPerWeightForQuantization(quantization)
        let modelGB = estimateModelSizeGB(paramCountB: paramCountB, quantBitsPerWeight: quantBits)
        let kvGB = estimateKVCacheSizeGB(paramCountB: paramCountB, contextLength: contextLength)

        let requiredGB = modelGB + kvGB + systemReserveGB
        let usableGB = Double(macProfile.unifiedRAMGB)
        let availableGB = usableGB - systemReserveGB
        let headroomGB = availableGB - modelGB

        let fit: MacFit
        if headroomGB >= (kvGB + 2.0) { fit = .comfortable }
        else if headroomGB >= kvGB { fit = .tight }
        else { fit = .overflow }

        let tps = estimateTokensPerSec(
            paramCountB: paramCountB,
            chip: AppleSiliconCatalog.getChip(byName: macProfile.chipFamily),
            quantBitsPerWeight: quantBits,
            headroomGB: headroomGB
        )

        return MacFitEstimate(
            fit: fit,
            estimatedTokensPerSec: tps,
            requiredGB: requiredGB,
            availableGB: availableGB,
            headroomGB: headroomGB
        )
    }

    private static func estimateTokensPerSec(
        paramCountB: Double,
        chip: AppleSiliconFamily?,
        quantBitsPerWeight: Double,
        headroomGB: Double
    ) -> String {
        guard let chip = chip else { return "Unknown" }
        let bandwidthGBps = chip.memoryBandwidthGBps
        let bytesPerToken = paramCountB * 1e9 * (quantBitsPerWeight / 8.0)
        guard bytesPerToken > 0 else { return "Unknown" }
        let theoretical = (bandwidthGBps * 1e9) / bytesPerToken
        let penalty = max(0.3, min(1.0, headroomGB / 4.0))
        let realistic = theoretical * penalty
        let lower = max(1, Int(realistic * 0.6))
        let upper = max(lower + 1, Int(realistic * 0.9))
        return "\(lower)-\(upper) tokens/sec"
    }
}
