//
//  HuggingFaceDTOs.swift
//  LLM Seeker
//

import Foundation

// MARK: - Search response
struct HFSearchResponse: Codable {
    let models: [HFModel]?
    let links: HFLinks?

    enum CodingKeys: String, CodingKey {
        case models
        case links = "_links"
    }
}

struct HFModel: Codable {
    let id: String?
    let modelId: String?
    let name: String?
    let author: String?
    let description: String?
    let downloads: Int?
    let likes: Int?
    let tags: [String]?
    let lastModified: String?
    let siblings: [HFModelFile]?
    let isPrivate: Bool?
    let gated: Bool?
    let pipeline_tag: String?
    let trendingScore: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case modelId = "model_id"
        case name
        case author
        case description
        case downloads
        case likes
        case tags
        case lastModified = "last_modified"
        case siblings
        case isPrivate = "private"
        case gated
        case pipeline_tag
        case trendingScore
    }
}

struct HFModelFile: Codable {
    let rfilename: String
    let size: Int64?
    let blob_id: String?

    enum CodingKeys: String, CodingKey {
        case rfilename
        case size
        case blob_id
    }
}

struct HFLinks: Codable {
    let next: String?
}

// MARK: - Model details
struct HFModelDetails: Codable {
    let modelId: String?
    let id: String?
    let name: String?
    let author: String?
    let description: String?
    let downloads: Int?
    let likes: Int?
    let tags: [String]?
    let siblings: [HFModelFile]?
    let cardData: HFCardData?
    let pipeline_tag: String?
    let safetensors: HFSafetensors?

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case id, name, author, description, downloads, likes, tags, siblings
        case cardData = "card_data"
        case pipeline_tag, safetensors
    }
}

struct HFSafetensors: Codable {
    let parameters: [String: Int64]?
    let total: Int64?
}

struct HFCardData: Codable {
    let license: String?
    let tags: [String]?
    let model_index: [AnyCodable]?
    let datasets: [String]?

    enum CodingKeys: String, CodingKey {
        case license, tags, model_index, datasets
    }
}

// MARK: - Tree
struct HFTreeResponse: Codable {
    let tree: [HFTreeItem]
}

struct HFTreeItem: Codable {
    let path: String
    let size: Int64?
    let blob_id: String?
    let lfs: HFLFSInfo?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case path, size, blob_id, lfs, type
    }
}

struct HFLFSInfo: Codable {
    let size: Int64?
    let sha256: String?
}

// MARK: - AnyCodable
enum AnyCodable: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodable])
    case object([String: AnyCodable])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else if let v = try? container.decode([AnyCodable].self) { self = .array(v) }
        else if let v = try? container.decode([String: AnyCodable].self) { self = .object(v) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode AnyCodable") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}
