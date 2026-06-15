//
//  DiagnosticsLog.swift
//  LLM Seeker
//
//  In-app rolling log buffer. Mirrored to os.Logger for Console.app
//  consumption when an iPhone is tethered, but also surfaced in the
//  Settings → Diagnostics screen so users can capture logs from a stand-
//  alone phone session and share them.
//

import Foundation
import os.log
import Combine

enum DiagnosticsLevel: String, Codable {
    case debug, info, warn, error
}

struct DiagnosticsEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let level: DiagnosticsLevel
    let category: String
    let message: String
}

/// Thread-safe rolling buffer of diagnostic entries. Safe to call from any
/// isolation domain. UI binds to `published` on the main actor.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    private let queue = DispatchQueue(label: "com.joaosabino.LLM-Seeker.diag", qos: .utility)
    private var buffer: [DiagnosticsEntry] = []
    private let capacity = 2_000

    /// Main-actor-bound published mirror used by SwiftUI views.
    @MainActor private(set) var published: [DiagnosticsEntry] = []
    @MainActor let objectWillChange = ObservableObjectPublisher()

    private init() {}

    func log(_ level: DiagnosticsLevel, category: String, _ message: @autoclosure @escaping () -> String) {
        let now = Date()
        let msg = message()
        // Mirror to os.Logger (visible in Console.app)
        let logger = Logger(subsystem: "com.joaosabino.LLM-Seeker", category: category)
        switch level {
        case .debug: logger.debug("\(msg, privacy: .public)")
        case .info:  logger.info("\(msg, privacy: .public)")
        case .warn:  logger.warning("\(msg, privacy: .public)")
        case .error: logger.error("\(msg, privacy: .public)")
        }

        let entry = DiagnosticsEntry(id: UUID(), timestamp: now, level: level, category: category, message: msg)
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(entry)
            if self.buffer.count > self.capacity {
                self.buffer.removeFirst(self.buffer.count - self.capacity)
            }
            let snapshot = self.buffer
            Task { @MainActor in
                self.published = snapshot
                self.objectWillChange.send()
            }
        }
    }

    func snapshot() -> [DiagnosticsEntry] {
        queue.sync { buffer }
    }

    func clear() {
        queue.async { [weak self] in
            self?.buffer.removeAll()
            Task { @MainActor in
                self?.published.removeAll()
                self?.objectWillChange.send()
            }
        }
    }

    /// Plain-text dump suitable for sharing.
    func plainText() -> String {
        let entries = snapshot()
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries.map { e in
            "\(fmt.string(from: e.timestamp))  [\(e.level.rawValue.uppercased())]  [\(e.category)]  \(e.message)"
        }.joined(separator: "\n")
    }
}

/// Convenience global so call sites stay short.
@inline(__always)
func DLog(_ level: DiagnosticsLevel, _ category: String, _ message: @autoclosure @escaping () -> String) {
    DiagnosticsLog.shared.log(level, category: category, message())
}
