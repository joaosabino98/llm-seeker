//
//  LibraryView.swift
//  LLM Seeker
//

import SwiftUI
import SwiftData
import UIKit

private struct ShareSession: Identifiable {
    let id = UUID()
    let modelId: PersistentIdentifier
    let archiveURL: URL
    let suggestedPath: String
}

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DownloadedModel.addedAt, order: .reverse) private var models: [DownloadedModel]
    @StateObject private var progress = DownloadManager.shared.progressCenter

    @AppStorage("autoDeleteAfterAirDrop") private var autoDeleteAfterAirDrop = false
    @AppStorage("didShowAirDropHelper") private var didShowAirDropHelper = false
    @AppStorage("shareAsZip") private var shareAsZip = false

    @State private var pendingShareModelID: PersistentIdentifier?
    @State private var shareSession: ShareSession?
    @State private var showHelperSheet = false
    @State private var toastMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackground()
                if models.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                            ForEach(models) { model in modelCard(model) }
                        }
                        .padding(Theme.Spacing.lg)
                    }
                }
                if let msg = toastMessage {
                    VStack {
                        Spacer()
                        Text(msg)
                            .font(Theme.Typography.caption).foregroundStyle(.white)
                            .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.md)
                            .background(.black.opacity(0.8), in: Capsule())
                            .padding(.bottom, Theme.Spacing.xl)
                    }.transition(.opacity)
                }
            }
            .navigationTitle("Library")
            .sheet(item: $shareSession) { session in
                AirDropPresenter(
                    activityItems: [session.archiveURL],
                    excludedActivityTypes: [.postToFacebook, .postToTwitter, .assignToContact, .print]
                ) { completed in
                    handleShareCompletion(session: session, completed: completed)
                }
            }
            .sheet(isPresented: $showHelperSheet) { helperSheet }
        }
    }

    private var emptyState: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("No downloaded models yet")
                    .font(Theme.Typography.subheadline).foregroundStyle(Theme.text)
                Text("Discover and download models, then AirDrop them to your Mac.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(Theme.Spacing.lg)
    }

    private func modelCard(_ model: DownloadedModel) -> some View {
        let snapshot = progress.snapshotsByRepo[model.repoId]
        return GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(model.displayName)
                    .font(Theme.Typography.subheadline).foregroundStyle(Theme.text)
                Text(model.repoId)
                    .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)

                HStack(spacing: Theme.Spacing.md) {
                    Label(model.status.capitalized, systemImage: statusIcon(model.status))
                    Label(storageLabel(for: model), systemImage: "internaldrive")
                    Spacer(minLength: 0)
                }
                .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

                if model.quantization != nil || model.lastSharedAt != nil {
                    HStack(spacing: Theme.Spacing.md) {
                        if let q = model.quantization {
                            Label(q, systemImage: "rectangle.compress.vertical")
                        }
                        if let lastShared = model.lastSharedAt {
                            Label(lastShared.formatted(date: .numeric, time: .shortened), systemImage: "paperplane")
                        }
                        Spacer(minLength: 0)
                    }
                    .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                }

                if let snap = snapshot, model.status != "complete" {
                    ProgressView(value: snap.fractionCompleted)
                        .tint(Theme.primary)
                    Text("\(formatBytes(snap.writtenBytes)) of \(formatBytes(snap.totalBytes)) · \(formatBytesPerSec(snap.bytesPerSecond))\(formatETA(snap.etaSeconds))")
                        .font(Theme.Typography.caption2).foregroundStyle(Theme.textSecondary)
                } else if model.totalBytes > 0 && model.status != "complete" {
                    ProgressView(value: Double(model.bytesOnDisk), total: Double(model.totalBytes))
                        .tint(Theme.primary)
                }

                actionButtons(for: model)

                Toggle("Delete after AirDrop", isOn: binding(for: model, keyPath: \DownloadedModel.autoDeleteAfterShare))
                    .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func actionButtons(for model: DownloadedModel) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            switch model.status {
            case "downloading":
                Button { Task { await DownloadManager.shared.pause(repoId: model.repoId) } } label: {
                    Label("Pause", systemImage: "pause.circle")
                }
                .buttonStyle(.bordered)
                Button(role: .destructive) {
                    Task { await DownloadManager.shared.cancel(repoId: model.repoId, deletePartialFiles: true) }
                    deleteModel(model)
                } label: { Label("Cancel", systemImage: "xmark.circle") }
                .buttonStyle(.bordered)

            case "paused":
                Button { Task { await DownloadManager.shared.resume(repoId: model.repoId) } } label: {
                    Label("Resume", systemImage: "play.circle")
                }
                .buttonStyle(.borderedProminent)
                Button(role: .destructive) {
                    Task { await DownloadManager.shared.cancel(repoId: model.repoId, deletePartialFiles: true) }
                    deleteModel(model)
                } label: { Label("Discard", systemImage: "trash") }
                .buttonStyle(.bordered)

            case "complete":
                Button { beginShareFlow(for: model) } label: {
                    Label("AirDrop", systemImage: "airplane")
                }
                .buttonStyle(.borderedProminent)
                Button(role: .destructive) { deleteModel(model) } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)

            case "failed", "cancelled":
                Button { Task { await DownloadManager.shared.resume(repoId: model.repoId) } } label: {
                    Label("Retry", systemImage: "arrow.clockwise.circle")
                }
                .buttonStyle(.borderedProminent)
                Button(role: .destructive) { deleteModel(model) } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)

            default:
                Button(role: .destructive) { deleteModel(model) } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var helperSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("How AirDrop placement works")
                    .font(Theme.Typography.headline)

                Text("1. The shared folder lands in ~/Downloads on your Mac.\n2. Move it to ~/.omlx/models/<owner>/<model>/.\n3. Refresh oMLX or your local LLM runtime.")
                    .font(Theme.Typography.body).foregroundStyle(Theme.textSecondary)

                if let m = pendingShareModel {
                    let path = "~/.omlx/models/\(m.repoId)/"
                    Button {
                        UIPasteboard.general.string = path
                        showToast("Copied path: \(path)")
                    } label: { Label("Copy oMLX path", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("Continue to Share") {
                    didShowAirDropHelper = true
                    showHelperSheet = false
                    if let m = pendingShareModel { startShare(for: m) }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(Theme.Spacing.lg)
            .navigationTitle("First-time tip")
        }
    }

    private var pendingShareModel: DownloadedModel? {
        guard let id = pendingShareModelID else { return nil }
        return models.first(where: { $0.persistentModelID == id })
    }

    private func beginShareFlow(for model: DownloadedModel) {
        pendingShareModelID = model.persistentModelID
        if didShowAirDropHelper { startShare(for: model) }
        else { showHelperSheet = true }
    }

    private func startShare(for model: DownloadedModel) {
        do {
            let archive = shareAsZip
                ? try ModelShareService.prepareZipArchive(for: model)
                : try ModelShareService.prepareArchive(for: model)
            shareSession = ShareSession(
                modelId: model.persistentModelID,
                archiveURL: archive.archiveURL,
                suggestedPath: archive.suggestedOMLXPath
            )
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func handleShareCompletion(session: ShareSession, completed: Bool) {
        defer {
            ModelShareService.cleanupArchiveIfNeeded(session.archiveURL)
            shareSession = nil
            pendingShareModelID = nil
        }
        guard completed else { return }
        guard let model = models.first(where: { $0.persistentModelID == session.modelId }) else { return }
        model.lastSharedAt = Date()
        try? modelContext.save()
        if model.autoDeleteAfterShare || autoDeleteAfterAirDrop {
            deleteModel(model)
            showToast("Shared and deleted local copy")
        } else {
            showToast("Shared successfully")
        }
    }

    private func deleteModel(_ model: DownloadedModel) {
        ModelShareService.deleteLocalModelData(for: model)
        modelContext.delete(model)
        try? modelContext.save()
    }

    private func showToast(_ msg: String) {
        withAnimation { toastMessage = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { withAnimation { toastMessage = nil } }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter(); f.allowedUnits = [.useMB, .useGB]; f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    private func storageLabel(for model: DownloadedModel) -> String {
        if model.totalBytes > 0 && model.status != "complete" {
            return "\(formatBytes(model.bytesOnDisk)) / \(formatBytes(model.totalBytes))"
        }
        return formatBytes(model.bytesOnDisk)
    }

    private func formatBytesPerSec(_ bps: Double) -> String {
        let f = ByteCountFormatter(); f.allowedUnits = [.useKB, .useMB]; f.countStyle = .file
        return "\(f.string(fromByteCount: Int64(bps)))/s"
    }

    private func formatETA(_ eta: Double?) -> String {
        guard let eta, eta.isFinite, eta > 0 else { return "" }
        let mins = Int(eta) / 60
        let secs = Int(eta) % 60
        if mins > 0 { return " · \(mins)m \(secs)s left" }
        return " · \(secs)s left"
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "downloading": return "arrow.down.circle"
        case "paused": return "pause.circle"
        case "complete": return "checkmark.circle"
        case "failed", "cancelled": return "exclamationmark.triangle"
        default: return "tray.full"
        }
    }

    private func binding<Value>(for model: DownloadedModel, keyPath: ReferenceWritableKeyPath<DownloadedModel, Value>) -> Binding<Value> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { newValue in
                model[keyPath: keyPath] = newValue
                try? modelContext.save()
            }
        )
    }
}

#Preview { LibraryView() }
