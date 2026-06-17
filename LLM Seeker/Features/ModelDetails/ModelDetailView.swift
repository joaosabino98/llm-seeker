//
//  ModelDetailView.swift
//  LLM Seeker
//

import SwiftUI
import SwiftData

struct ModelDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var downloadedModels: [DownloadedModel]
    @Query(filter: #Predicate<MacProfile> { $0.isDefault == true }) private var defaultProfiles: [MacProfile]
    @Query private var allProfiles: [MacProfile]
    @Query private var favorites: [FavoriteModel]

    @StateObject private var viewModel: ModelDetailViewModel
    @State private var toastMessage: String?

    init(summary: ModelSummary) {
        _viewModel = StateObject(wrappedValue: ModelDetailViewModel(summary: summary))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                headerCard
                overviewCard
                compatibilityCard
                if let benchmarks = viewModel.resolvedDetails.benchmarks, !benchmarks.isEmpty {
                    benchmarksCard(benchmarks)
                }
                if let readme = viewModel.resolvedDetails.readme, !readme.isEmpty {
                    modelCardCard(readme)
                }
                filesCard
                if let err = viewModel.errorMessage { errorCard(message: err) }
            }
            .padding(Theme.Spacing.lg)
        }
        .background(LiquidGlassBackground())
        .navigationTitle(viewModel.summary.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .refreshable { await viewModel.refresh() }
        .overlay(alignment: .bottom) {
            if let msg = toastMessage {
                Text(msg)
                    .font(Theme.Typography.caption).foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.md)
                    .background(.black.opacity(0.8), in: Capsule())
                    .padding(.bottom, Theme.Spacing.xl).transition(.opacity)
            }
        }
    }

    private var currentDownloadedModel: DownloadedModel? {
        downloadedModels.first(where: { $0.repoId == viewModel.summary.repoId })
    }

    private var activeMacProfile: MacProfile? {
        defaultProfiles.first ?? allProfiles.first
    }

    private var headerCard: some View {
        let isFavorite = favorites.contains(where: { $0.repoId == viewModel.summary.repoId })
        return GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.resolvedDetails.displayName)
                            .font(Theme.Typography.headline).foregroundStyle(Theme.text)
                        Text(viewModel.resolvedDetails.repoId)
                            .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button {
                        FavoritesService.toggle(modelSummary: viewModel.summary, in: modelContext)
                        showToast(isFavorite ? "Removed from favorites" : "Added to favorites")
                    } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.title2)
                            .foregroundStyle(isFavorite ? Theme.danger : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: Theme.Spacing.sm) {
                    QuantBadge(text: viewModel.quantizationLabel, backgroundColor: Theme.accent)
                    FrameworkBadge(text: viewModel.frameworkLabel, icon: "cube.fill")
                    if let fit = viewModel.macFitEstimate(profile: activeMacProfile) {
                        FitIndicatorBadge(fit: mapFit(fit.fit), macName: activeMacProfile?.name ?? "Mac")
                    }
                }
                HStack(spacing: Theme.Spacing.md) {
                    if !isDownloadInProgress {
                        Button {
                            Task { await downloadModel() }
                        } label: {
                            Label(downloadButtonTitle, systemImage: downloadButtonIcon)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isDownloading || downloadDisabled)
                    }

                    if let dm = currentDownloadedModel {
                        Text(dm.status.capitalized)
                            .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private var overviewCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Overview").font(Theme.Typography.subheadline).foregroundStyle(Theme.text)
                Text(viewModel.resolvedDetails.description ?? "No description published for this model.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.textSecondary)
                HStack(spacing: Theme.Spacing.md) {
                    Label(formatNumber(viewModel.resolvedDetails.downloads), systemImage: "arrow.down.circle")
                    Label(formatNumber(viewModel.resolvedDetails.likes), systemImage: "heart")
                    Label(formatBytes(viewModel.resolvedDetails.totalBytes), systemImage: "internaldrive")
                    Label(formatParams(), systemImage: "cpu")
                }
                .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var compatibilityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Mac compatibility").font(Theme.Typography.subheadline).foregroundStyle(Theme.text)
                if let fit = viewModel.macFitEstimate(profile: activeMacProfile) {
                    Text("Estimated speed: \(fit.estimatedTokensPerSec)")
                        .font(Theme.Typography.body).foregroundStyle(Theme.text)
                    Text("Required: \(String(format: "%.1f", fit.requiredGB)) GB · Available: \(String(format: "%.1f", fit.availableGB)) GB")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                    Text(fitDescription(fit.fit))
                        .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Add a Mac profile in Settings to estimate fit on your hardware.")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                }
                Text("Quantization: \(viewModel.quantizationLabel) · Framework: \(viewModel.frameworkLabel)")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                if viewModel.resolvedDetails.isAdapter {
                    Text("⚠︎ This is an adapter (LoRA / PEFT). Requires a base model on the Mac.")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func benchmarksCard(_ benchmarks: [BenchmarkResult]) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Benchmarks").font(Theme.Typography.subheadline).foregroundStyle(Theme.text)
                ForEach(Array(benchmarks.prefix(8)), id: \.self) { b in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(b.metric).font(Theme.Typography.caption).foregroundStyle(Theme.text)
                            Text(b.task).font(Theme.Typography.caption2).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text(String(format: "%.3f", b.value))
                            .font(Theme.Typography.caption).foregroundStyle(Theme.primary)
                    }
                }
            }
        }
    }

    private func modelCardCard(_ readme: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Model card").font(Theme.Typography.subheadline).foregroundStyle(Theme.text)
                Text(readme.prefix(2000) + (readme.count > 2000 ? "…" : ""))
                    .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var filesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Files").font(Theme.Typography.subheadline).foregroundStyle(Theme.text)
                let files = viewModel.resolvedDetails.files
                if viewModel.isLoading && files.isEmpty {
                    ProgressView()
                } else if files.isEmpty {
                    Text("Loading file manifest…")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(Array(files.prefix(10).enumerated()), id: \.offset) { _, file in
                        HStack {
                            Text(file.path).font(Theme.Typography.caption)
                                .foregroundStyle(Theme.textSecondary).lineLimit(1)
                            Spacer()
                            Text(formatBytes(file.bytes))
                                .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    if files.count > 10 {
                        Text("+ \(files.count - 10) more files")
                            .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private func errorCard(message: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Could not load full details")
                    .font(Theme.Typography.subheadline).foregroundStyle(Theme.danger)
                Text(message).font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: - Actions

    private var downloadButtonTitle: String {
        if viewModel.isDownloading { return "Queueing…" }
        if let dm = currentDownloadedModel {
            switch dm.status {
            case "downloading": return "Downloading"
            case "complete": return "Downloaded"
            case "paused": return "Resume"
            case "failed": return "Retry"
            default: return "Download"
            }
        }
        return "Download"
    }

    private var downloadButtonIcon: String {
        if currentDownloadedModel?.status == "complete" { return "checkmark.circle" }
        return "arrow.down.circle"
    }

    private var downloadDisabled: Bool { currentDownloadedModel?.status == "complete" }

    /// True while a download is actively queued or running. Used to hide the
    /// Download button once tapped so the status (e.g. "Downloading") only
    /// shows once instead of duplicated on the button and label.
    private var isDownloadInProgress: Bool {
        if viewModel.isDownloading { return true }
        switch currentDownloadedModel?.status {
        case "queued", "downloading": return true
        default: return false
        }
    }

    private func downloadModel() async {
        viewModel.isDownloading = true
        defer { viewModel.isDownloading = false }
        do {
            if viewModel.details == nil { await viewModel.load() }
            if let dm = currentDownloadedModel, dm.status == "paused" {
                await DownloadManager.shared.resume(repoId: dm.repoId)
                showToast("Resumed download")
                return
            }
            try await ModelDownloadService.enqueueDownload(for: viewModel.resolvedDetails, in: modelContext)
            showToast("Download queued")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func showToast(_ msg: String) {
        withAnimation { toastMessage = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation { toastMessage = nil }
        }
    }

    // MARK: - Formatting

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

    private func formatParams() -> String {
        let p = currentDownloadedModel?.paramCountB
            ?? viewModel.resolvedDetails.paramCountB
            ?? viewModel.summary.paramCountB
            ?? MacFitEstimator.inferParamCountFromText("\(viewModel.summary.repoId) \(viewModel.summary.displayName)")
        guard let v = p else { return "—" }
        return v >= 1 ? String(format: "%.1fB", v) : String(format: "%.0fM", v * 1000)
    }

    private func mapFit(_ f: MacFit) -> FitIndicatorBadge.Fit {
        switch f {
        case .comfortable: return .comfortable
        case .tight: return .tight
        case .overflow: return .overflow
        }
    }

    private func fitDescription(_ f: MacFit) -> String { f.description }
}
