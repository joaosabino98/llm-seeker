//
//  ModelDownloadService.swift
//  LLM Seeker
//

import Foundation
import SwiftData

enum ModelDownloadService {
    /// Subset of files we want to keep for a model. Drops `original/**` PyTorch
    /// duplicates when safetensors / GGUF are present, and drops bare `.bin`
    /// when safetensors exist (matches HF / oMLX conventions).
    static func filterFiles(_ files: [RemoteFile]) -> [RemoteFile] {
        let hasSafetensors = files.contains(where: { $0.path.lowercased().hasSuffix(".safetensors") })
        let hasGGUF = files.contains(where: { $0.path.lowercased().hasSuffix(".gguf") })

        return files.filter { file in
            let lower = file.path.lowercased()
            if lower.hasPrefix("original/") { return false }
            if lower.hasPrefix("consolidated.") { return false }
            if lower.hasSuffix(".bin"), hasSafetensors { return false }
            if lower.hasSuffix(".pt"), hasSafetensors || hasGGUF { return false }
            if lower.hasSuffix(".pth"), hasSafetensors || hasGGUF { return false }
            return true
        }
    }

    @MainActor
    static func enqueueDownload(for details: ModelDetails, in context: ModelContext) async throws {
        let filtered = filterFiles(details.files)
        let totalBytes = details.totalBytes ?? filtered.reduce(0) { $0 + $1.bytes }

        let existing = try context.fetch(FetchDescriptor<DownloadedModel>())
            .first(where: { $0.repoId == details.repoId })
        let model: DownloadedModel
        if let existing {
            model = existing
            if model.files.isEmpty { attachFiles(to: model, from: filtered) }
            model.totalBytes = totalBytes
            model.author = details.author
            model.modelDescription = details.description
            model.quantization = model.quantization ?? details.quantization
            model.framework = model.framework ?? details.framework
            model.paramCountB = model.paramCountB ?? details.paramCountB
            model.modelCard = details.readme
            model.tags = details.tags
            model.pipelineTag = details.pipelineTag
        } else {
            model = DownloadedModel(
                repoId: details.repoId,
                displayName: details.displayName,
                author: details.author,
                modelDescription: details.description,
                totalBytes: totalBytes,
                quantization: details.quantization,
                framework: details.framework,
                paramCountB: details.paramCountB,
                pipelineTag: details.pipelineTag,
                isAdapter: details.isAdapter,
                tags: details.tags,
                modelCard: details.readme,
                downloads: details.downloads,
                likes: details.likes
            )
            attachFiles(to: model, from: filtered)
            context.insert(model)
        }
        try context.save()

        let destination = try destinationRoot(for: details.repoId)

        try await DownloadManager.shared.enqueueModelDownload(
            repoId: model.repoId,
            revision: "main",
            files: filtered,
            destinationRoot: destination
        )
    }

    private static func attachFiles(to model: DownloadedModel, from files: [RemoteFile]) {
        let existing = Set(model.files.map(\.relativePath))
        for file in files where !existing.contains(file.path) {
            model.files.append(
                FileItem(
                    fileName: URL(fileURLWithPath: file.path).lastPathComponent,
                    relativePath: file.path,
                    bytes: file.bytes,
                    sha: file.sha
                )
            )
        }
    }

    /// `Application Support/Models/{owner}/{model}/`
    private static func destinationRoot(for repoId: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(repoId, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
