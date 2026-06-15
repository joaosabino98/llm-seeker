//
//  FavoritesService.swift
//  LLM Seeker
//

import Foundation
import SwiftData

enum FavoritesService {
    @MainActor
    static func isFavorite(repoId: String, in context: ModelContext) -> Bool {
        (try? context.fetch(FetchDescriptor<FavoriteModel>()))?
            .contains(where: { $0.repoId == repoId }) ?? false
    }

    @MainActor
    static func toggle(modelSummary: ModelSummary, in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<FavoriteModel>()))?
            .first(where: { $0.repoId == modelSummary.repoId })
        if let existing {
            context.delete(existing)
        } else {
            let fav = FavoriteModel(
                repoId: modelSummary.repoId,
                displayName: modelSummary.displayName,
                author: modelSummary.author,
                modelDescription: modelSummary.description,
                pipelineTag: modelSummary.pipelineTag,
                downloads: modelSummary.downloads,
                likes: modelSummary.likes,
                paramCountB: modelSummary.paramCountB,
                tags: modelSummary.tags
            )
            context.insert(fav)
        }
        try? context.save()
    }
}
