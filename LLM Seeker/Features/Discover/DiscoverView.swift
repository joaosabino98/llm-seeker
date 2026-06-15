//
//  DiscoverView.swift
//  LLM Seeker
//

import SwiftUI
import SwiftData

struct DiscoverView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = DiscoverViewModel()
    @Query(sort: \FavoriteModel.addedAt, order: .reverse) private var favorites: [FavoriteModel]

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        searchAndControls

                        if viewModel.isLoading && !viewModel.isSearching && viewModel.trending.isEmpty {
                            loadingSection
                        } else if let err = viewModel.errorMessage {
                            errorSection(message: err)
                        } else if viewModel.isSearching {
                            modelsSection(title: "Results", items: viewModel.searchResults)
                        } else {
                            if !favorites.isEmpty {
                                modelsSection(
                                    title: "Favorites",
                                    items: favorites.map { $0.toModelSummary() }
                                )
                            }
                            modelsSection(title: "Trending", items: Array(viewModel.trending.prefix(30)))
                            modelsSection(title: "Popular", items: Array(viewModel.popular.prefix(30)))
                        }
                    }
                    .padding(Theme.Spacing.lg)
                }
                .refreshable { await viewModel.reload() }
            }
            .navigationTitle("Discover")
        }
        .task { await viewModel.reload() }
    }

    private var favoriteRepoIds: Set<String> { Set(favorites.map(\.repoId)) }

    private var searchAndControls: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                    TextField("Search HuggingFace…", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .submitLabel(.search)
                        .onSubmit { viewModel.performSearch() }
                        .onChange(of: viewModel.searchText) { _, _ in viewModel.performSearch() }
                    if !viewModel.searchText.isEmpty {
                        Button { viewModel.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                        }
                    }
                }

                Toggle(isOn: $viewModel.mlxOnly) {
                    Text("MLX-friendly only").font(Theme.Typography.body).foregroundStyle(Theme.text)
                }
                .onChange(of: viewModel.mlxOnly) { _, _ in
                    if viewModel.isSearching { viewModel.performSearch() }
                    else { Task { await viewModel.reload() } }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(DiscoverViewModel.pipelineOptions, id: \.label) { opt in
                            GlassChip(
                                label: opt.label,
                                icon: nil,
                                backgroundColor: Theme.primary,
                                isSelected: viewModel.pipelineFilter == opt.value,
                                onTap: {
                                    viewModel.pipelineFilter = opt.value
                                    if viewModel.isSearching { viewModel.performSearch() }
                                    else { Task { await viewModel.reload() } }
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private var loadingSection: some View {
        GlassCard {
            HStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Fetching models from HuggingFace…")
                    .foregroundStyle(Theme.textSecondary).font(Theme.Typography.body)
            }
        }
    }

    private func errorSection(message: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Could not load models")
                    .font(Theme.Typography.subheadline).foregroundStyle(Theme.danger)
                Text(message).font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                Button("Try Again") { Task { await viewModel.reload() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func modelsSection(title: String, items: [ModelSummary]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(title).font(Theme.Typography.headline).foregroundStyle(Theme.text)
            if items.isEmpty {
                GlassCard {
                    Text("No models found").foregroundStyle(Theme.textSecondary).font(Theme.Typography.body)
                }
            } else {
                ForEach(items, id: \.repoId) { model in modelRow(model) }
            }
        }
    }

    private func modelRow(_ model: ModelSummary) -> some View {
        let isFavorite = favoriteRepoIds.contains(model.repoId)
        return NavigationLink {
            ModelDetailView(summary: model)
        } label: {
            GlassCard {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                                .font(Theme.Typography.subheadline)
                                .foregroundStyle(Theme.text).lineLimit(2)
                            Text(model.repoId)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        Button {
                            FavoritesService.toggle(modelSummary: model, in: modelContext)
                        } label: {
                            Image(systemName: isFavorite ? "heart.fill" : "heart")
                                .font(.title3)
                                .foregroundStyle(isFavorite ? Theme.danger : Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: Theme.Spacing.md) {
                        Label(formatNumber(model.downloads), systemImage: "arrow.down.circle")
                        Label(formatNumber(model.likes), systemImage: "heart")
                        Label(formatBytes(model.totalBytes), systemImage: "internaldrive")
                        Label(formatParams(model), systemImage: "cpu")
                    }
                    .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func formatNumber(_ value: Int?) -> String {
        guard let v = value else { return "-" }
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    private func formatBytes(_ bytes: Int64?) -> String {
        guard let b = bytes else { return "—" }
        let f = ByteCountFormatter(); f.allowedUnits = [.useMB, .useGB]; f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    private func formatParams(_ model: ModelSummary) -> String {
        let params = model.paramCountB
            ?? MacFitEstimator.inferParamCountFromText("\(model.repoId) \(model.displayName)")
        guard let p = params else { return "—" }
        return p >= 1 ? String(format: "%.1fB", p) : String(format: "%.0fM", p * 1000)
    }
}

#Preview { DiscoverView() }
