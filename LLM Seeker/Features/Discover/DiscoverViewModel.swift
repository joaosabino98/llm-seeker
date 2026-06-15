//
//  DiscoverViewModel.swift
//  LLM Seeker
//

import Foundation
import Combine

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var mlxOnly: Bool = true
    @Published var pipelineFilter: String? = nil
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var trending: [ModelSummary] = []
    @Published var popular: [ModelSummary] = []
    @Published var searchResults: [ModelSummary] = []

    private let client = HuggingFaceClient()
    private var searchTask: Task<Void, Never>?

    static let pipelineOptions: [(label: String, value: String?)] = [
        ("All", nil),
        ("Text gen", "text-generation"),
        ("Vision", "image-text-to-text"),
        ("Embeddings", "feature-extraction"),
        ("OCR", "image-to-text"),
    ]

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Trending: sorted by trendingScore (HF API supports sort=trendingScore)
            async let trendingPage = fetchTrending()
            async let popularPage = fetchPopular()

            let (t, p) = try await (trendingPage, popularPage)
            let tFiltered = applyMlxFilterIfNeeded(t.models)
            let pFiltered = applyMlxFilterIfNeeded(p.models)

            // Enrich top window for size hints (parallel fetchDetails).
            let enriched = await enrichSummaries(Array(Set(tFiltered + pFiltered)
                .sorted { ($0.downloads ?? 0) > ($1.downloads ?? 0) }))
            let byId = Dictionary(uniqueKeysWithValues: enriched.map { ($0.repoId, $0) })

            trending = tFiltered.map { byId[$0.repoId] ?? $0 }
            popular = pFiltered.map { byId[$0.repoId] ?? $0 }
        } catch {
            trending = []
            popular = []
            errorMessage = error.localizedDescription
        }
    }

    func performSearch() {
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await self.runSearch(query: q)
        }
    }

    private func runSearch(query: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var filters = SearchFilters()
            filters.mlxFriendlyOnly = mlxOnly
            if mlxOnly { filters.frameworks = ["mlx"] }
            filters.pipelineTag = pipelineFilter
            let page = try await client.search(query: query, filters: filters, cursor: nil, limit: 60)
            searchResults = applyMlxFilterIfNeeded(page.models)
        } catch {
            errorMessage = error.localizedDescription
            searchResults = []
        }
    }

    private func fetchTrending() async throws -> SearchPage {
        var filters = SearchFilters()
        filters.mlxFriendlyOnly = mlxOnly
        if mlxOnly { filters.frameworks = ["mlx"] }
        filters.pipelineTag = pipelineFilter
        return try await client.search(query: "", filters: filters, cursor: nil, limit: 60)
    }

    private func fetchPopular() async throws -> SearchPage {
        var filters = SearchFilters()
        filters.mlxFriendlyOnly = mlxOnly
        if mlxOnly { filters.frameworks = ["mlx"] }
        filters.pipelineTag = pipelineFilter
        return try await client.search(query: "", filters: filters, cursor: nil, limit: 60)
    }

    private func applyMlxFilterIfNeeded(_ models: [ModelSummary]) -> [ModelSummary] {
        guard mlxOnly else { return models }
        return models.filter { m in
            let repo = m.repoId.lowercased()
            if repo.hasPrefix("mlx-community/") || repo.hasPrefix("lmstudio-community/") { return true }
            return m.tags.contains { $0.lowercased().contains("mlx") }
        }
    }

    private func enrichSummaries(_ input: [ModelSummary]) async -> [ModelSummary] {
        let cap = min(60, input.count)
        guard cap > 0 else { return input }
        let prefix = Array(input.prefix(cap))
        let suffix = Array(input.dropFirst(cap))
        let detailsByRepo = await fetchDetailsMap(for: prefix)

        var out: [ModelSummary] = []
        out.reserveCapacity(prefix.count)
        for s in prefix {
            guard let d = detailsByRepo[s.repoId] else { out.append(s); continue }
            let resolvedSize = await resolveSize(summary: s, details: d)
            let params = s.paramCountB ?? d.paramCountB
                ?? MacFitEstimator.inferParamCountFromText("\(d.repoId) \(d.displayName)")
            out.append(ModelSummary(
                repoId: s.repoId,
                displayName: s.displayName,
                author: s.author,
                description: s.description,
                downloads: s.downloads,
                likes: s.likes,
                tags: s.tags,
                totalBytes: resolvedSize,
                paramCountB: params,
                pipelineTag: s.pipelineTag ?? d.pipelineTag,
                trendingScore: s.trendingScore,
                isAdapter: s.isAdapter
            ))
        }
        return out + suffix
    }

    private func resolveSize(summary: ModelSummary, details: ModelDetails) async -> Int64? {
        if let known = summary.totalBytes, known > 0 { return known }
        if let fromDetails = details.totalBytes, fromDetails > 0 { return fromDetails }
        if let tree = try? await client.fetchFileTree(repoId: summary.repoId, revision: "main") {
            let total = tree.reduce(Int64(0)) { $0 + $1.bytes }
            return total > 0 ? total : nil
        }
        return nil
    }

    private func fetchDetailsMap(for summaries: [ModelSummary]) async -> [String: ModelDetails] {
        await withTaskGroup(of: (String, ModelDetails?).self) { group in
            for s in summaries where s.totalBytes == nil || s.paramCountB == nil {
                group.addTask {
                    let d = try? await self.client.fetchDetails(repoId: s.repoId)
                    return (s.repoId, d)
                }
            }
            var map: [String: ModelDetails] = [:]
            for await result in group {
                if let d = result.1 { map[result.0] = d }
            }
            return map
        }
    }
}

extension ModelSummary: Hashable {
    static func == (lhs: ModelSummary, rhs: ModelSummary) -> Bool { lhs.repoId == rhs.repoId }
    func hash(into hasher: inout Hasher) { hasher.combine(repoId) }
}
