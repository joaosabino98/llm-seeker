//
//  AppleSiliconCatalog.swift
//  LLM Seeker
//

import Foundation

enum AppleSiliconFamily: String, CaseIterable, Identifiable {
    case m1 = "M1"
    case m1Pro = "M1 Pro"
    case m1Max = "M1 Max"
    case m1Ultra = "M1 Ultra"
    case m2 = "M2"
    case m2Pro = "M2 Pro"
    case m2Max = "M2 Max"
    case m2Ultra = "M2 Ultra"
    case m3 = "M3"
    case m3Pro = "M3 Pro"
    case m3Max = "M3 Max"
    case m4 = "M4"
    case m4Pro = "M4 Pro"
    case m4Max = "M4 Max"
    case m5 = "M5"
    case m5Pro = "M5 Pro"
    case m5Max = "M5 Max"

    var id: String { rawValue }
    var displayName: String { rawValue }

    var generation: Int {
        switch self {
        case .m1, .m1Pro, .m1Max, .m1Ultra: return 1
        case .m2, .m2Pro, .m2Max, .m2Ultra: return 2
        case .m3, .m3Pro, .m3Max: return 3
        case .m4, .m4Pro, .m4Max: return 4
        case .m5, .m5Pro, .m5Max: return 5
        }
    }

    var memoryBandwidthGBps: Double {
        switch self {
        case .m1: return 100
        case .m1Pro: return 200
        case .m1Max: return 400
        case .m1Ultra: return 800
        case .m2: return 100
        case .m2Pro: return 200
        case .m2Max: return 400
        case .m2Ultra: return 800
        case .m3: return 100
        case .m3Pro: return 150
        case .m3Max: return 400
        case .m4: return 120
        case .m4Pro: return 273
        case .m4Max: return 546
        case .m5: return 153
        case .m5Pro: return 320
        case .m5Max: return 600
        }
    }

}

struct AppleSiliconCatalog {
    /// Standard unified-memory options shown in the Mac profile picker.
    /// These are the real physical RAM amounts Apple sells, expressed as
    /// round numbers — not Metal GPU memory caps, which can differ (e.g.
    /// the M3 Pro's Metal cap is ~16.7 GB, while the actual RAM is 16 or
    /// 24 GB depending on config).
    static let standardRAMOptions: [Int] = [16, 24, 32, 48, 64]

    static let allChips = AppleSiliconFamily.allCases
    static func getChip(byName name: String) -> AppleSiliconFamily? { AppleSiliconFamily(rawValue: name) }
}
