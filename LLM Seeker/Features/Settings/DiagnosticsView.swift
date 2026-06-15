//
//  DiagnosticsView.swift
//  LLM Seeker
//
//  In-app log viewer for the rolling DiagnosticsLog buffer. Lets users
//  inspect download events without tethering the iPhone to a Mac, and
//  share the log via the iOS share sheet.
//

import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @State private var entries: [DiagnosticsEntry] = []
    @State private var filter: DiagnosticsLevel? = nil
    @State private var categoryFilter: String? = nil
    @State private var autoRefresh: Bool = true
    @State private var refreshTimer: Timer?
    @State private var showShareSheet = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        ZStack {
            LiquidGlassBackground()
            VStack(spacing: 0) {
                filterBar
                listView
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showShareSheet = true } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                Menu {
                    Button(role: .destructive) {
                        DiagnosticsLog.shared.clear()
                        refresh()
                    } label: { Label("Clear", systemImage: "trash") }
                    Toggle("Auto-refresh", isOn: $autoRefresh)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [DiagnosticsLog.shared.plainText()])
        }
        .onAppear {
            refresh()
            startTimer()
        }
        .onDisappear { stopTimer() }
        .onChange(of: autoRefresh) { _, on in
            if on { startTimer() } else { stopTimer() }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(label: "All", active: filter == nil) { filter = nil }
                chip(label: "Info", active: filter == .info) { filter = .info }
                chip(label: "Warn", active: filter == .warn) { filter = .warn }
                chip(label: "Error", active: filter == .error) { filter = .error }
                chip(label: "Debug", active: filter == .debug) { filter = .debug }
                Divider().frame(height: 20)
                ForEach(uniqueCategories, id: \.self) { cat in
                    chip(label: cat, active: categoryFilter == cat) {
                        categoryFilter = (categoryFilter == cat) ? nil : cat
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func chip(label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(active ? Theme.primary.opacity(0.25) : Color.white.opacity(0.06))
                .foregroundStyle(active ? Theme.primary : Theme.textSecondary)
                .clipShape(Capsule())
        }
    }

    private var uniqueCategories: [String] {
        Array(Set(entries.map(\.category))).sorted()
    }

    private var filtered: [DiagnosticsEntry] {
        entries.filter { e in
            (filter == nil || e.level == filter)
            && (categoryFilter == nil || e.category == categoryFilter)
        }
    }

    private var listView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filtered) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(Self.formatter.string(from: entry.timestamp))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                Text(entry.level.rawValue.uppercased())
                                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                                    .foregroundStyle(color(for: entry.level))
                                Text(entry.category)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(Theme.primary)
                            }
                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.03))
                        .id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 8)
            }
            .onChange(of: filtered.count) { _, _ in
                if autoRefresh { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func color(for level: DiagnosticsLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        }
    }

    private func refresh() {
        entries = DiagnosticsLog.shared.snapshot()
    }

    private func startTimer() {
        stopTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            refresh()
        }
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
