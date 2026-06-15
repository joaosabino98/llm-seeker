//
//  PersistenceModels.swift
//  LLM Seeker
//

import Foundation
import SwiftData

// MARK: - DownloadedModel

@Model
final class DownloadedModel {
    var repoId: String              // "mlx-community/Qwen3.6-35B-A3B-4bit"
    var displayName: String
    var author: String?
    var modelDescription: String?
    var totalBytes: Int64
    var bytesOnDisk: Int64
    var status: String              // queued | downloading | paused | complete | failed | cancelled
    var localFolderURL: Data?       // Bookmark to {Models}/{owner}/{model}
    var quantization: String?       // Q4_K_M | MXFP4 | 4-bit | 8-bit | BF16
    var framework: String?          // MLX | GGUF | safetensors
    var paramCountB: Double?
    var pipelineTag: String?
    var isAdapter: Bool
    var tagsCSV: String             // Comma-joined tags for SwiftData simplicity
    var modelCard: String?          // README without YAML front matter
    var trendingScore: Double?
    var downloads: Int?
    var likes: Int?
    var addedAt: Date
    var lastSharedAt: Date?
    var autoDeleteAfterShare: Bool

    @Relationship(deleteRule: .cascade, inverse: \FileItem.model) var files: [FileItem] = []

    init(
        repoId: String,
        displayName: String,
        author: String? = nil,
        modelDescription: String? = nil,
        totalBytes: Int64,
        quantization: String? = nil,
        framework: String? = nil,
        paramCountB: Double? = nil,
        pipelineTag: String? = nil,
        isAdapter: Bool = false,
        tags: [String] = [],
        modelCard: String? = nil,
        trendingScore: Double? = nil,
        downloads: Int? = nil,
        likes: Int? = nil
    ) {
        self.repoId = repoId
        self.displayName = displayName
        self.author = author
        self.modelDescription = modelDescription
        self.totalBytes = totalBytes
        self.bytesOnDisk = 0
        self.status = "queued"
        self.quantization = quantization
        self.framework = framework
        self.paramCountB = paramCountB
        self.pipelineTag = pipelineTag
        self.isAdapter = isAdapter
        self.tagsCSV = tags.joined(separator: ",")
        self.modelCard = modelCard
        self.trendingScore = trendingScore
        self.downloads = downloads
        self.likes = likes
        self.addedAt = Date()
        self.autoDeleteAfterShare = false
    }

    var tags: [String] {
        get { tagsCSV.split(separator: ",").map(String.init) }
        set { tagsCSV = newValue.joined(separator: ",") }
    }
}

// MARK: - FileItem

@Model
final class FileItem {
    var fileName: String
    var relativePath: String
    var bytes: Int64
    var sha: String?
    var downloaded: Bool
    var resumeData: Data?

    var model: DownloadedModel?

    init(fileName: String, relativePath: String, bytes: Int64, sha: String? = nil) {
        self.fileName = fileName
        self.relativePath = relativePath
        self.bytes = bytes
        self.sha = sha
        self.downloaded = false
    }
}

// MARK: - MacProfile

@Model
final class MacProfile {
    var name: String
    var chipFamily: String          // "M1" ... "M5 Max"
    var chipVariant: String
    var unifiedRAMGB: Int
    var isDefault: Bool

    init(name: String, chipFamily: String, unifiedRAMGB: Int, isDefault: Bool = false) {
        self.name = name
        self.chipFamily = chipFamily
        self.chipVariant = chipFamily
        self.unifiedRAMGB = unifiedRAMGB
        self.isDefault = isDefault
    }
}

// MARK: - SavedSearch

@Model
final class SavedSearch {
    var query: String
    var filters: Data?
    var pinned: Bool
    var createdAt: Date

    init(query: String, filters: Data? = nil, pinned: Bool = false) {
        self.query = query
        self.filters = filters
        self.pinned = pinned
        self.createdAt = Date()
    }
}

// MARK: - FavoriteModel
//
// Persisted star/heart entries. Stores enough fields to render a Discover
// row without re-fetching from HuggingFace, so favorites work offline too.

@Model
final class FavoriteModel {
    @Attribute(.unique) var repoId: String
    var displayName: String
    var author: String?
    var modelDescription: String?
    var pipelineTag: String?
    var downloads: Int?
    var likes: Int?
    var paramCountB: Double?
    var tagsCSV: String
    var addedAt: Date

    init(
        repoId: String,
        displayName: String,
        author: String? = nil,
        modelDescription: String? = nil,
        pipelineTag: String? = nil,
        downloads: Int? = nil,
        likes: Int? = nil,
        paramCountB: Double? = nil,
        tags: [String] = []
    ) {
        self.repoId = repoId
        self.displayName = displayName
        self.author = author
        self.modelDescription = modelDescription
        self.pipelineTag = pipelineTag
        self.downloads = downloads
        self.likes = likes
        self.paramCountB = paramCountB
        self.tagsCSV = tags.joined(separator: ",")
        self.addedAt = Date()
    }

    var tags: [String] {
        get { tagsCSV.split(separator: ",").map(String.init) }
        set { tagsCSV = newValue.joined(separator: ",") }
    }

    func toModelSummary() -> ModelSummary {
        ModelSummary(
            repoId: repoId,
            displayName: displayName,
            author: author,
            description: modelDescription,
            downloads: downloads,
            likes: likes,
            tags: tags,
            totalBytes: nil,
            paramCountB: paramCountB,
            pipelineTag: pipelineTag,
            trendingScore: nil,
            isAdapter: false
        )
    }
}
