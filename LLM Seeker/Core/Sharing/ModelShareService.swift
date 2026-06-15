//
//  ModelShareService.swift
//  LLM Seeker
//

import Foundation

struct ShareArchive {
    let archiveURL: URL
    let suggestedOMLXPath: String
}

enum ModelShareServiceError: LocalizedError {
    case missingLocalFolder
    case localFolderNotFound
    case archiveCreationFailed

    var errorDescription: String? {
        switch self {
        case .missingLocalFolder: return "This model has no local folder registered yet."
        case .localFolderNotFound: return "The local model folder could not be found on disk."
        case .archiveCreationFailed: return "Could not prepare archive for sharing."
        }
    }
}

enum ModelShareService {
    /// Default share: pass the folder URL itself. AirDrop preserves the folder
    /// hierarchy `{owner}/{model}/...` as-is.
    static func prepareArchive(for model: DownloadedModel) throws -> ShareArchive {
        let folder = try resolveLocalFolderURL(for: model)
        return ShareArchive(
            archiveURL: folder,
            suggestedOMLXPath: "~/.omlx/models/\(model.repoId)/"
        )
    }

    /// Optional ZIP variant when the receiver prefers a single file.
    static func prepareZipArchive(for model: DownloadedModel) throws -> ShareArchive {
        let folder = try resolveLocalFolderURL(for: model)
        let zipURL = try makeZip(at: folder, name: model.repoId.replacingOccurrences(of: "/", with: "__"))
        return ShareArchive(
            archiveURL: zipURL,
            suggestedOMLXPath: "~/.omlx/models/\(model.repoId)/"
        )
    }

    static func cleanupArchiveIfNeeded(_ url: URL) {
        guard url.pathExtension.lowercased() == "zip" else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func deleteLocalModelData(for model: DownloadedModel) {
        guard let bookmark = model.localFolderURL else { return }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private static func resolveLocalFolderURL(for model: DownloadedModel) throws -> URL {
        guard let bookmark = model.localFolderURL else { throw ModelShareServiceError.missingLocalFolder }
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw ModelShareServiceError.localFolderNotFound
        }
        return folder
    }

    private static func makeZip(at sourceFolder: URL, name: String) throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
        let zipURL = tmpDir.appendingPathComponent("\(name).zip")
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }

        // Use NSFileCoordinator to produce a ZIP via .forUploading.
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var resultURL: URL?
        coordinator.coordinate(readingItemAt: sourceFolder, options: [.forUploading], error: &coordError) { tempZipURL in
            do {
                try FileManager.default.copyItem(at: tempZipURL, to: zipURL)
                resultURL = zipURL
            } catch {
                resultURL = nil
            }
        }
        if let err = coordError { throw err }
        guard let out = resultURL else { throw ModelShareServiceError.archiveCreationFailed }
        return out
    }
}
