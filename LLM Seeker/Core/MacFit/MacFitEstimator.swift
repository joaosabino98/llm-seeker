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
    /// Total parameter count (drives memory). For MoE models this is the full
    /// expert pool; for dense models it equals the param count.
    var totalParamsB: Double = 0
    /// Active parameters per token (drives speed). Equals `totalParamsB` for
    /// dense models; smaller for MoE.
    var activeParamsB: Double = 0
    var isMixtureOfExperts: Bool { activeParamsB > 0 && activeParamsB < totalParamsB }
}

struct MacFitEstimator {
    /// Memory the OS + app + runtime overhead need that is NOT available to the
    /// model. oMLX enforces a "system RAM − 8 GB" ceiling to avoid system-wide
    /// OOM; we mirror that for larger machines and scale it down for small ones
    /// so an 8/16 GB Mac isn't left with nothing.
    static func systemReserveGB(forRAMGB ramGB: Int) -> Double {
        let ram = Double(ramGB)
        if ram >= 32 { return 8.0 }
        return Swift.min(8.0, Swift.max(2.5, ram * 0.2))
    }

    /// Realistic fraction of peak memory bandwidth actually achieved during
    /// token generation (memory-bandwidth-bound regime) on Apple Silicon.
    /// Calibrated from public llama.cpp / MLX benchmarks (e.g. M3 Pro 150 GB/s
    /// runs 7B-Q4 at ~31 tok/s ⇒ ~0.78 MBU; MLX runs slightly hotter). 0.80 fits
    /// the observed range across chips without per-model tuning.
    private static let memoryBandwidthUtilization: Double = 0.80

    // Effective BYTES-per-weight including quantization overhead (group scales,
    // biases). MLX 4-bit is not exactly 4 bits/weight on disk — it's ~4.5.
    static func bitsPerWeightForQuantization(_ quant: String) -> Double {
        let s = quant.lowercased()
        if s.contains("mxfp4") { return 4.25 }
        if s.contains("q2") || s.contains("2bit") || s.contains("2-bit") { return 2.5 }
        if s.contains("q3") || s.contains("3bit") || s.contains("3-bit") { return 3.5 }
        if s.contains("q4") || s.contains("4bit") || s.contains("4-bit") { return 4.5 }
        if s.contains("q5") || s.contains("5bit") || s.contains("5-bit") { return 5.5 }
        if s.contains("q6") || s.contains("6bit") || s.contains("6-bit") { return 6.5 }
        if s.contains("q8") || s.contains("8bit") || s.contains("8-bit") { return 8.5 }
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
        // Match "<num>b" where the trailing "b" is a billion-parameter suffix and
        // NOT part of another token ("4bit", "bf16", "blob"...). We take the LARGEST
        // match so MoE / multi-number names (e.g. "Qwen3-30B-A3B", "235B-A22B")
        // resolve to the total parameter count that actually drives memory use,
        // not the smaller active-expert count.
        if let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*b(?![a-z0-9])"#) {
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            var best: Double?
            for m in matches where m.numberOfRanges > 1 {
                let token = ns.substring(with: m.range(at: 1))
                if let v = Double(token), v > 0 { best = Swift.max(best ?? 0, v) }
            }
            if let best { return best }
        }
        if let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*m(?![a-z0-9])"#) {
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            var best: Double?
            for m in matches where m.numberOfRanges > 1 {
                let token = ns.substring(with: m.range(at: 1))
                if let v = Double(token), v > 0 { best = Swift.max(best ?? 0, v) }
            }
            if let best { return best / 1000.0 }
        }
        return nil
    }

    /// Parses the MoE "active parameters" count from the conventional `A<num>B`
    /// naming (e.g. "Qwen3-30B-A3B" ⇒ 3, "Qwen3-235B-A22B" ⇒ 22). Mixture-of-
    /// Experts models only read the *active* expert weights per token, so token
    /// generation speed is governed by this number, NOT the total parameter
    /// count. Returns nil for dense models.
    static func inferActiveParamCount(fromText text: String) -> Double? {
        let s = text.lowercased()
        guard let regex = try? NSRegularExpression(pattern: #"a(\d+(?:\.\d+)?)\s*b(?![a-z0-9])"#) else { return nil }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var best: Double?
        for m in matches where m.numberOfRanges > 1 {
            let token = ns.substring(with: m.range(at: 1))
            if let v = Double(token), v > 0 { best = Swift.max(best ?? 0, v) }
        }
        return best
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
        return weightsGB * 1.05
    }

    /// Approximate fp16 KV-cache footprint. KV scales with layers × hidden ×
    /// context, which tracks TOTAL parameters (even for MoE). Calibrated so an
    /// 8B model at 4k context ≈ 0.5 GB, a 70B ≈ 4–5 GB — matching observed runs.
    static func estimateKVCacheSizeGB(paramCountB: Double, contextLength: Int = 4096) -> Double {
        return 0.06 * paramCountB * (Double(contextLength) / 4096.0)
    }

    static func estimateFit(
        paramCountB: Double,
        quantization: String,
        macProfile: MacProfile,
        actualModelBytes: Int64? = nil,
        activeParamCountB: Double? = nil,
        contextLength: Int = 4096
    ) -> MacFitEstimate {
        let quantBits = bitsPerWeightForQuantization(quantization)
        let estimatedModelGB = estimateModelSizeGB(paramCountB: paramCountB, quantBitsPerWeight: quantBits)
        // Prefer the real on-disk weight size when we have it. The actual byte
        // total reflects the true memory footprint far more reliably than a
        // param×bits estimate, which is what made some large models look like
        // they fit when they don't.
        let modelGB: Double
        if let bytes = actualModelBytes, bytes > 0 {
            modelGB = Double(bytes) / 1e9
        } else {
            modelGB = estimatedModelGB
        }
        let kvGB = estimateKVCacheSizeGB(paramCountB: paramCountB, contextLength: contextLength)

        // Active parameters govern token-generation speed (MoE reads only the
        // active experts per token). Default to dense (active == total).
        let activeParamsB = (activeParamCountB.map { Swift.min($0, paramCountB) }) ?? paramCountB

        let reserveGB = systemReserveGB(forRAMGB: macProfile.unifiedRAMGB)
        let availableGB = Double(macProfile.unifiedRAMGB) - reserveGB
        let requiredGB = modelGB + kvGB
        let headroomGB = availableGB - requiredGB

        // Fit tiers: must hold weights + KV inside the usable budget. "Tight"
        // leaves <15% of the usable budget free (real-world swap risk on macOS).
        let fit: MacFit
        if requiredGB > availableGB { fit = .overflow }
        else if headroomGB < availableGB * 0.15 { fit = .tight }
        else { fit = .comfortable }

        let tps = estimateTokensPerSec(
            activeParamsB: activeParamsB,
            chip: AppleSiliconCatalog.getChip(byName: macProfile.chipFamily),
            quantBitsPerWeight: quantBits,
            fitsInMemory: fit != .overflow
        )

        return MacFitEstimate(
            fit: fit,
            estimatedTokensPerSec: tps,
            requiredGB: requiredGB + reserveGB,
            availableGB: availableGB,
            headroomGB: headroomGB,
            totalParamsB: paramCountB,
            activeParamsB: activeParamsB
        )
    }

    private static func estimateTokensPerSec(
        activeParamsB: Double,
        chip: AppleSiliconFamily?,
        quantBitsPerWeight: Double,
        fitsInMemory: Bool
    ) -> String {
        guard let chip = chip else { return "Unknown" }
        let bandwidthGBps = chip.memoryBandwidthGBps
        // Bytes streamed per generated token = active weights at their quantized
        // size. This is the memory-bandwidth-bound term that sets TG throughput.
        let bytesPerToken = activeParamsB * 1e9 * (quantBitsPerWeight / 8.0)
        guard bytesPerToken > 0 else { return "Unknown" }
        // tok/s ≈ MBU × peak_bandwidth / bytes_per_token.
        var realistic = (bandwidthGBps * 1e9 * memoryBandwidthUtilization) / bytesPerToken
        // If the model overflows RAM it swaps to SSD, collapsing throughput by
        // roughly an order of magnitude.
        if !fitsInMemory { realistic *= 0.1 }
        let lower = max(1, Int((realistic * 0.85).rounded()))
        let upper = max(lower + 1, Int((realistic * 1.05).rounded()))
        return "\(lower)-\(upper) tokens/sec"
    }
}
