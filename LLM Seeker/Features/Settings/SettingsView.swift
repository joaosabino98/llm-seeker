//
//  SettingsView.swift
//  LLM Seeker
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MacProfile.name) private var profiles: [MacProfile]

    @AppStorage("maxConcurrentDownloads") private var maxConcurrentDownloads: Int = 2
    @AppStorage("wifiOnlyDownloads") private var wifiOnlyDownloads: Bool = true
    @AppStorage("shareAsZip") private var shareAsZip: Bool = false

    @State private var hfTokenInput: String = ""
    @State private var hasToken: Bool = KeychainService.hasHuggingFaceToken()
    @State private var showAddProfile = false

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackground()
                ScrollView {
                    VStack(spacing: Theme.Spacing.lg) {
                        macProfilesCard
                        hfTokenCard
                        downloadsCard
                        sharingCard
                        diagnosticsCard
                    }
                    .padding(Theme.Spacing.lg)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showAddProfile) {
                AddMacProfileSheet { profile in
                    modelContext.insert(profile)
                    if profiles.allSatisfy({ !$0.isDefault }) { profile.isDefault = true }
                    try? modelContext.save()
                    showAddProfile = false
                }
            }
            .onChange(of: maxConcurrentDownloads) { _, newValue in
                Task { await DownloadManager.shared.setConcurrencyLimit(newValue) }
            }
        }
    }

    private var macProfilesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack {
                    Text("Mac profiles").font(Theme.Typography.headline).foregroundStyle(Theme.text)
                    Spacer()
                    Button { showAddProfile = true } label: {
                        Label("Add", systemImage: "plus.circle.fill")
                    }
                }
                if profiles.isEmpty {
                    Text("Add a profile to estimate model fit.")
                        .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(profiles) { p in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(p.name).font(Theme.Typography.subheadline).foregroundStyle(Theme.text)
                                Text("\(p.chipFamily) · \(p.unifiedRAMGB) GB unified")
                                    .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if p.isDefault {
                                Text("Default").font(Theme.Typography.caption2)
                                    .padding(.horizontal, Theme.Spacing.sm).padding(.vertical, 2)
                                    .background(Theme.primary.opacity(0.2))
                                    .foregroundStyle(Theme.primary)
                                    .clipShape(Capsule())
                            } else {
                                Button("Make default") { setDefault(p) }
                                    .font(Theme.Typography.caption2)
                            }
                            Button(role: .destructive) {
                                modelContext.delete(p)
                                try? modelContext.save()
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Theme.danger)
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                    }
                }
            }
        }
    }

    private var hfTokenCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("HuggingFace token").font(Theme.Typography.headline).foregroundStyle(Theme.text)
                Text("Required for gated and private repos. Stored in Keychain.")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                if hasToken {
                    HStack {
                        Label("Token saved", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.success)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            KeychainService.huggingFaceToken = nil
                            hasToken = false
                            hfTokenInput = ""
                        }
                    }
                } else {
                    SecureField("hf_…", text: $hfTokenInput)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Save token") {
                        let trimmed = hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        KeychainService.huggingFaceToken = trimmed
                        hasToken = KeychainService.hasHuggingFaceToken()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var downloadsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Downloads").font(Theme.Typography.headline).foregroundStyle(Theme.text)
                Stepper("Max concurrent: \(maxConcurrentDownloads)",
                        value: $maxConcurrentDownloads, in: 1...3)
                    .foregroundStyle(Theme.text)
                Toggle("Wi-Fi only", isOn: $wifiOnlyDownloads).foregroundStyle(Theme.text)
            }
        }
    }

    private var sharingCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Sharing").font(Theme.Typography.headline).foregroundStyle(Theme.text)
                Toggle("Share as ZIP archive", isOn: $shareAsZip).foregroundStyle(Theme.text)
                Text(shareAsZip
                     ? "Sends one .zip file. Receiver must unzip into ~/.omlx/models/{owner}/{model}/."
                     : "Sends the folder as-is. Preserves oMLX layout on the Mac.")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var diagnosticsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Diagnostics").font(Theme.Typography.headline).foregroundStyle(Theme.text)
                Text("View / share download logs to investigate issues.")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    HStack {
                        Label("Open log viewer", systemImage: "text.alignleft")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                    .foregroundStyle(Theme.text)
                }
            }
        }
    }

    private func setDefault(_ profile: MacProfile) {
        for p in profiles { p.isDefault = (p.persistentModelID == profile.persistentModelID) }
        try? modelContext.save()
    }
}

private struct AddMacProfileSheet: View {
    let onSave: (MacProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = "My Mac"
    @State private var chip: AppleSiliconFamily = .m3Pro
    @State private var ram: Int = 18

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                }
                Section("Chip") {
                    Picker("Chip family", selection: $chip) {
                        ForEach(AppleSiliconCatalog.allChips) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    .onChange(of: chip) { _, newChip in
                        if !newChip.validRAMSKUs.contains(ram) {
                            ram = newChip.validRAMSKUs.first ?? 16
                        }
                    }
                }
                Section("Unified memory") {
                    Picker("RAM", selection: $ram) {
                        ForEach(chip.validRAMSKUs, id: \.self) { sku in
                            Text("\(sku) GB").tag(sku)
                        }
                    }
                }
            }
            .navigationTitle("Add Mac profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(MacProfile(name: name, chipFamily: chip.rawValue, unifiedRAMGB: ram))
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

#Preview { SettingsView() }
