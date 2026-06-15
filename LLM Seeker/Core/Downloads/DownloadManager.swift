//
//  DownloadManager.swift
//  LLM Seeker
//
//  HF-only background download manager with oMLX-compatible layout.
//  Files are downloaded into `{root}/_____temp/{path}` then atomically
//  moved to `{root}/{path}` on completion. `{root}` itself is
//  `Application Support/Models/{owner}/{model}/`.
//

import Foundation
import SwiftData
import Combine
import os.log
import UIKit

struct DownloadQueueItem: Sendable {
    let repoId: String
    let revision: String
    let file: RemoteFile
    let destinationRoot: URL
}

struct DownloadProgressSnapshot: Sendable {
    let repoId: String
    let writtenBytes: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double
    let fractionCompleted: Double
    let etaSeconds: Double?
}

final class DownloadProgressCenter: ObservableObject {
    @Published var snapshotsByRepo: [String: DownloadProgressSnapshot] = [:]

    func update(_ snapshot: DownloadProgressSnapshot) { snapshotsByRepo[snapshot.repoId] = snapshot }
    func clear(repoId: String) { snapshotsByRepo[repoId] = nil }
}

enum DownloadManagerError: LocalizedError {
    case insufficientDiskSpace(required: Int64, available: Int64)
    case invalidDownloadURL
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let required, let available):
            return "Insufficient storage: required \(required) bytes, available \(available) bytes."
        case .invalidDownloadURL: return "Invalid download URL."
        case .modelNotFound(let id): return "Model not found in local database: \(id)."
        }
    }
}

private struct ActiveTaskMetadata: Sendable {
    let repoId: String
    let revision: String
    let relativePath: String
    let expectedBytes: Int64
    let stagingURL: URL
    let finalURL: URL
    let startedAt: Date
}

private final class DownloadSessionDelegateBridge: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    var onProgress: (@Sendable (_ taskId: Int, _ written: Int64, _ totalWritten: Int64, _ totalExpected: Int64, _ url: URL?) -> Void)?
    var onDownloaded: (@Sendable (_ taskId: Int, _ temporaryURL: URL, _ url: URL?) -> Void)?
    var onCompleted: (@Sendable (_ taskId: Int, _ error: Error?, _ url: URL?) -> Void)?
    var onSessionDidFinishEvents: (@Sendable () -> Void)?

    /// Stable directory we stash finished downloads into BEFORE the actor
    /// can pick them up. URLSession deletes its CFNetworkDownload_*.tmp the
    /// moment this delegate method returns, so we MUST move synchronously.
    private static let pendingRoot: URL = {
        let fm = FileManager.default
        let caches = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = caches.appendingPathComponent("PendingDownloads", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress?(downloadTask.taskIdentifier, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite, downloadTask.originalRequest?.url)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // CRITICAL: The CFNetworkDownload_*.tmp file at `location` is deleted
        // by URLSession the instant this method returns. We cannot hop to an
        // actor first — the file would be gone. Move it synchronously to a
        // stable cache directory; the actor then promotes it to its final
        // resting place.
        let fm = FileManager.default
        let staged = Self.pendingRoot
            .appendingPathComponent("\(downloadTask.taskIdentifier)-\(UUID().uuidString).bin")
        var handoff: URL = location
        do {
            try fm.moveItem(at: location, to: staged)
            handoff = staged
        } catch {
            // If move failed, the actor will likely also fail — but at least
            // try; the original URL might still be valid for a brief window.
            DLog(.error, "DelegateBridge", "sync stage move failed taskId=\(downloadTask.taskIdentifier) err=\(error.localizedDescription)")
        }
        onDownloaded?(downloadTask.taskIdentifier, handoff, downloadTask.originalRequest?.url)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onCompleted?(task.taskIdentifier, error, task.originalRequest?.url)
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onSessionDidFinishEvents?()
    }
}

actor DownloadManager {
    /// Hidden temp folder name (matches oMLX convention).
    static let tempFolderName = "_____temp"

    static let shared: DownloadManager = DownloadManager(modelContainer: LLM_SeekerApp.sharedContainer)

    private let log = Logger(subsystem: "com.joaosabino.LLM-Seeker", category: "DownloadManager")
    private let modelContainer: ModelContainer
    private let fileManager = FileManager.default
    private let delegateBridge: DownloadSessionDelegateBridge
    private let backgroundSession: URLSession

    private var activeTasks: [Int: ActiveTaskMetadata] = [:]
    private var pendingQueue: [DownloadQueueItem] = []
    private var maxConcurrentTasks = 2

    private var taskBytesWritten: [Int: Int64] = [:]
    /// Wall-clock of last progress callback per task. Used by the watchdog
    /// to detect stalled tasks.
    private var taskLastProgressAt: [Int: Date] = [:]
    private var taskStallCount: [Int: Int] = [:]
    /// Tasks the watchdog has marked as stalled. handleCompletion treats
    /// the resulting NSURLErrorCancelled as a re-enqueue request.
    private var stallCancelledTasks: Set<Int> = []
    private var repoCompletedBytes: [String: Int64] = [:]
    private var repoTotalBytes: [String: Int64] = [:]
    private var repoSessionStart: [String: Date] = [:]
    private var lastDBWriteAt: [String: Date] = [:]

    private var watchdogStarted = false
    /// If a task makes no progress for this many seconds, restart it.
    private let stallTimeoutSeconds: TimeInterval = 90
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid
    /// Last time we logged progress for a task (for throttling progress logs).
    private var lastProgressLogAt: [Int: Date] = [:]

    nonisolated let progressCenter = DownloadProgressCenter()

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        let bridge = DownloadSessionDelegateBridge()
        self.delegateBridge = bridge
        self.backgroundSession = URLSessionFactory.background(delegate: bridge)

        bridge.onProgress = { [weak self] taskId, w, tw, te, url in
            Task { await self?.handleProgress(taskId: taskId, bytesWritten: w, totalBytesWritten: tw, totalBytesExpected: te, originalURL: url) }
        }
        bridge.onDownloaded = { [weak self] taskId, tmp, url in
            Task { await self?.handleFinishedDownload(taskId: taskId, temporaryURL: tmp, originalURL: url) }
        }
        bridge.onCompleted = { [weak self] taskId, err, url in
            Task { await self?.handleCompletion(taskId: taskId, error: err, originalURL: url) }
        }
        bridge.onSessionDidFinishEvents = {
            // iOS told us all queued events for this background session are
            // delivered. Hand back the system-supplied completion handler so
            // the OS can finish suspending us cleanly.
            DLog(.info, "DownloadManager", "urlSessionDidFinishEvents — flushing handler")
            Task { @MainActor in
                if let handler = AppDelegate.backgroundSessionCompletionHandler {
                    AppDelegate.backgroundSessionCompletionHandler = nil
                    handler()
                }
            }
        }
        DLog(.info, "DownloadManager", "init — bg session attached id=\(self.backgroundSession.configuration.identifier ?? "nil")")
    }

    // MARK: - Public API

    func setConcurrencyLimit(_ limit: Int) {
        maxConcurrentTasks = max(1, min(3, limit))
        Task { await maybeStartMoreTasks() }
    }

    /// Spawns a long-running stall detector. Idempotent — only the first call
    /// arms the watchdog. Loops every 30s, checks each active task; if a
    /// task hasn't reported progress in `stallTimeoutSeconds`, it cancels it
    /// (preserving resumeData when possible) and re-enqueues the file with a
    /// fresh URLRequest. This covers:
    ///   * HuggingFace CDN presigned URL expiration after long suspends
    ///   * Connections silently dropped by the server during sleep
    ///   * `nsurlsessiond` deciding the task is "discretionary"
    func startWatchdog() async {
        guard !watchdogStarted else { return }
        watchdogStarted = true
        log.info("watchdog armed (stallTimeout=\(self.stallTimeoutSeconds)s)")
        DLog(.info, "Watchdog", "armed (stallTimeout=\(self.stallTimeoutSeconds)s, tickEvery=30s)")
        Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.watchdogTick()
            }
        }
    }

    private func watchdogTick() async {
        guard !activeTasks.isEmpty else {
            DLog(.debug, "Watchdog", "tick — no active tasks")
            return
        }
        let now = Date()
        var stalledTaskIds: [Int] = []
        for (taskId, _) in activeTasks {
            let last = taskLastProgressAt[taskId] ?? Date.distantPast
            let idle = now.timeIntervalSince(last)
            DLog(.debug, "Watchdog", "tick taskId=\(taskId) idle=\(Int(idle))s bytes=\(self.taskBytesWritten[taskId] ?? 0)")
            if idle > stallTimeoutSeconds {
                stalledTaskIds.append(taskId)
            }
        }
        guard !stalledTaskIds.isEmpty else { return }
        for taskId in stalledTaskIds {
            guard let meta = activeTasks[taskId] else { continue }
            let count = (taskStallCount[taskId] ?? 0) + 1
            taskStallCount[taskId] = count
            stallCancelledTasks.insert(taskId)
            log.info("stall detected repo=\(meta.repoId, privacy: .public) path=\(meta.relativePath, privacy: .public) attempt=\(count, privacy: .public)")
            DLog(.warn, "Watchdog", "STALL repo=\(meta.repoId) path=\(meta.relativePath) attempt=\(count) — cancelling for re-enqueue")
            // Cancel the stuck task; handleCompletion sees the stall flag and
            // re-enqueues with a fresh request URL (so HF redirects to a new
            // CDN presigned URL, bypassing the expired one).
            if let task = await taskByIdentifier(taskId) {
                task.cancel()
            }
        }
    }

    func rehydrateActiveTasks() async {
        let tasks = await backgroundSession.allTasks
        DLog(.info, "Rehydrate", "begin — \(tasks.count) tasks reported by URLSession")
        var recovered = 0
        for task in tasks {
            guard activeTasks[task.taskIdentifier] == nil,
                  let url = task.originalRequest?.url,
                  let parsed = parseHFDownloadURL(url),
                  let meta = await rebuildMetadata(repoId: parsed.repoId, revision: parsed.revision, relativePath: parsed.relativePath)
            else {
                DLog(.warn, "Rehydrate", "skip taskId=\(task.taskIdentifier) state=\(task.state.rawValue) url=\(task.originalRequest?.url?.absoluteString ?? "nil") — could not rebuild metadata")
                continue
            }
            activeTasks[task.taskIdentifier] = meta
            taskLastProgressAt[task.taskIdentifier] = Date()
            recovered += 1
            DLog(.info, "Rehydrate", "recovered taskId=\(task.taskIdentifier) repo=\(meta.repoId) path=\(meta.relativePath) state=\(task.state.rawValue) countOfBytesReceived=\(task.countOfBytesReceived)")
        }
        DLog(.info, "Rehydrate", "end — recovered=\(recovered) of \(tasks.count)")
        await reconcileAllPersistedModels()
    }

    func enqueueModelDownload(
        repoId: String,
        revision: String,
        files: [RemoteFile],
        destinationRoot: URL
    ) async throws {
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.bytes }
        DLog(.info, "Enqueue", "repo=\(repoId) rev=\(revision) files=\(files.count) total=\(totalBytes / 1_048_576)MB dest=\(destinationRoot.lastPathComponent)")
        try ensureEnoughDiskSpace(requiredBytes: Int64(Double(totalBytes) * 1.1))

        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let stagingRoot = destinationRoot.appendingPathComponent(Self.tempFolderName, isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        await setModelStatus(repoId: repoId, status: "queued")
        await setModelFolderBookmark(repoId: repoId, folder: destinationRoot)

        repoTotalBytes[repoId] = totalBytes
        repoSessionStart[repoId] = Date()
        let alreadyFinalized = files.reduce(Int64(0)) { acc, f in
            let final = destinationRoot.appendingPathComponent(f.path)
            return acc + (fileManager.fileExists(atPath: final.path) ? f.bytes : 0)
        }
        repoCompletedBytes[repoId] = alreadyFinalized
        await setBytesOnDisk(repoId: repoId, bytes: alreadyFinalized)

        let pending = files.filter { file in
            let final = destinationRoot.appendingPathComponent(file.path)
            return !fileManager.fileExists(atPath: final.path)
        }

        DLog(.info, "Enqueue", "repo=\(repoId) alreadyFinalized=\(alreadyFinalized / 1_048_576)MB pending=\(pending.count) files")

        let queueItems = pending.map {
            DownloadQueueItem(repoId: repoId, revision: revision, file: $0, destinationRoot: destinationRoot)
        }
        pendingQueue.append(contentsOf: queueItems)
        await maybeStartMoreTasks()
        emitSnapshot(repoId: repoId)
    }

    func pause(repoId: String) async {
        let taskIds = activeTasks.compactMap { $0.value.repoId == repoId ? $0.key : nil }
        DLog(.info, "Pause", "repo=\(repoId) activeTasks=\(taskIds.count)")
        for taskId in taskIds {
            guard let task = await taskByIdentifier(taskId) as? URLSessionDownloadTask else { continue }
            task.cancel { resumeData in
                Task {
                    if let resumeData, let meta = await self.activeTasks[taskId] {
                        await self.persistResumeData(repoId: meta.repoId, path: meta.relativePath, resumeData: resumeData)
                    }
                }
            }
        }
        pendingQueue.removeAll { $0.repoId == repoId }
        await setModelStatus(repoId: repoId, status: "paused")
        // Active tasks will eventually fire didCompleteWithError; their slot frees there.
        // Kick the queue so any other repo's pending items can start.
        await maybeStartMoreTasks()
    }

    func resume(repoId: String) async {
        guard let plan = await loadResumePlan(repoId: repoId) else {
            DLog(.error, "Resume", "repo=\(repoId) FAILED — loadResumePlan returned nil")
            await setModelStatus(repoId: repoId, status: "failed")
            return
        }

        let alreadyFinalized = plan.files.reduce(Int64(0)) { acc, f in
            let final = plan.root.appendingPathComponent(f.path)
            return acc + (fileManager.fileExists(atPath: final.path) ? f.bytes : 0)
        }
        DLog(.info, "Resume", "repo=\(repoId) plan.files=\(plan.files.count) total=\(plan.totalBytes / 1_048_576)MB alreadyFinalized=\(alreadyFinalized / 1_048_576)MB")
        repoTotalBytes[repoId] = plan.totalBytes
        repoCompletedBytes[repoId] = alreadyFinalized
        repoSessionStart[repoId] = Date()
        await setBytesOnDisk(repoId: repoId, bytes: alreadyFinalized)

        let stagingRoot = plan.root.appendingPathComponent(Self.tempFolderName, isDirectory: true)
        try? fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        var resumedAny = false
        var resumedCount = 0
        var enqueuedCount = 0
        for file in plan.files {
            let final = plan.root.appendingPathComponent(file.path)
            if fileManager.fileExists(atPath: final.path) { continue }

            let staging = stagingRoot.appendingPathComponent(file.path)
            if let data = file.resumeData {
                let task = backgroundSession.downloadTask(withResumeData: data)
                activeTasks[task.taskIdentifier] = ActiveTaskMetadata(
                    repoId: repoId,
                    revision: plan.revision,
                    relativePath: file.path,
                    expectedBytes: file.bytes,
                    stagingURL: staging,
                    finalURL: final,
                    startedAt: Date()
                )
                taskLastProgressAt[task.taskIdentifier] = Date()
                DLog(.info, "Resume", "resumeData taskId=\(task.taskIdentifier) repo=\(repoId) path=\(file.path) resumeBytes=\(data.count)")
                task.resume()
                await clearResumeData(repoId: repoId, path: file.path)
                resumedAny = true
                resumedCount += 1
            } else {
                if fileManager.fileExists(atPath: staging.path) {
                    try? fileManager.removeItem(at: staging)
                }
                DLog(.info, "Resume", "no resumeData — enqueueing fresh repo=\(repoId) path=\(file.path)")
                pendingQueue.append(
                    DownloadQueueItem(
                        repoId: repoId,
                        revision: plan.revision,
                        file: RemoteFile(path: file.path, bytes: file.bytes, sha: file.sha),
                        destinationRoot: plan.root
                    )
                )
                enqueuedCount += 1
            }
        }

        let hasWork = resumedAny || pendingQueue.contains(where: { $0.repoId == repoId })
        DLog(.info, "Resume", "repo=\(repoId) resumed=\(resumedCount) enqueued=\(enqueuedCount) hasWork=\(hasWork)")
        await setModelStatus(repoId: repoId, status: hasWork ? "downloading" : "complete")
        await maybeStartMoreTasks()
        emitSnapshot(repoId: repoId)
    }

    func cancel(repoId: String, deletePartialFiles: Bool = false) async {
        let taskIds = activeTasks.compactMap { $0.value.repoId == repoId ? $0.key : nil }
        DLog(.info, "Cancel", "repo=\(repoId) activeTasks=\(taskIds.count) deletePartialFiles=\(deletePartialFiles)")
        for taskId in taskIds {
            if let task = await taskByIdentifier(taskId) { task.cancel() }
            activeTasks[taskId] = nil
            taskBytesWritten[taskId] = nil
            taskLastProgressAt[taskId] = nil
            taskStallCount[taskId] = nil
            stallCancelledTasks.remove(taskId)
        }
        pendingQueue.removeAll { $0.repoId == repoId }
        repoCompletedBytes[repoId] = nil
        repoTotalBytes[repoId] = nil
        repoSessionStart[repoId] = nil
        await setModelStatus(repoId: repoId, status: "cancelled")

        if deletePartialFiles {
            await deleteLocalFolder(repoId: repoId)
        } else {
            await deleteTempFolder(repoId: repoId)
        }

        await MainActor.run { progressCenter.clear(repoId: repoId) }
        // CRITICAL: pull any other repo's pending items into the freed slots.
        await maybeStartMoreTasks()
    }

    func availableDiskSpaceBytes() throws -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    // MARK: - Queue mgmt

    private func maybeStartMoreTasks() async {
        while activeTasks.count < maxConcurrentTasks, !pendingQueue.isEmpty {
            let next = pendingQueue.removeFirst()
            do { try await startTask(for: next) }
            catch { await setModelStatus(repoId: next.repoId, status: "failed") }
        }
        if !activeTasks.isEmpty {
            let repos = Set(activeTasks.values.map { $0.repoId })
            for repo in repos { await setModelStatus(repoId: repo, status: "downloading") }
        }
    }

    private func startTask(for item: DownloadQueueItem) async throws {
        guard let url = buildHFDownloadURL(repoId: item.repoId, revision: item.revision, relativePath: item.file.path) else {
            throw DownloadManagerError.invalidDownloadURL
        }

        let stagingRoot = item.destinationRoot.appendingPathComponent(Self.tempFolderName, isDirectory: true)
        let staging = stagingRoot.appendingPathComponent(item.file.path)
        let final = item.destinationRoot.appendingPathComponent(item.file.path)
        try fileManager.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)

        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        if let token = KeychainService.huggingFaceToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let task = backgroundSession.downloadTask(with: request)
        activeTasks[task.taskIdentifier] = ActiveTaskMetadata(
            repoId: item.repoId,
            revision: item.revision,
            relativePath: item.file.path,
            expectedBytes: item.file.bytes,
            stagingURL: staging,
            finalURL: final,
            startedAt: Date()
        )
        taskLastProgressAt[task.taskIdentifier] = Date()
        log.info("startTask repo=\(item.repoId, privacy: .public) path=\(item.file.path, privacy: .public) bytes=\(item.file.bytes, privacy: .public) taskId=\(task.taskIdentifier, privacy: .public)")
        DLog(.info, "StartTask", "taskId=\(task.taskIdentifier) repo=\(item.repoId) path=\(item.file.path) expected=\(item.file.bytes / 1_048_576)MB url=\(url.absoluteString)")
        task.resume()
    }

    private func buildHFDownloadURL(repoId: String, revision: String, relativePath: String) -> URL? {
        let encoded = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
        return URL(string: "https://huggingface.co/\(repoId)/resolve/\(revision)/\(encoded)")
    }

    private func parseHFDownloadURL(_ url: URL) -> (repoId: String, revision: String, relativePath: String)? {
        let path = url.path
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let resolveIdx = comps.firstIndex(of: "resolve"),
              resolveIdx >= 2,
              resolveIdx + 1 < comps.count else { return nil }
        let repoId = comps.prefix(resolveIdx).joined(separator: "/")
        let revision = comps[resolveIdx + 1]
        let raw = comps.suffix(from: resolveIdx + 2).joined(separator: "/")
        let relativePath = raw.removingPercentEncoding ?? raw
        return (repoId, revision, relativePath)
    }

    private func rebuildMetadata(repoId: String, revision: String, relativePath: String) async -> ActiveTaskMetadata? {
        guard let (root, expected) = await fetchFileLocation(repoId: repoId, path: relativePath) else { return nil }
        let staging = root.appendingPathComponent(Self.tempFolderName, isDirectory: true).appendingPathComponent(relativePath)
        let final = root.appendingPathComponent(relativePath)
        return ActiveTaskMetadata(
            repoId: repoId,
            revision: revision,
            relativePath: relativePath,
            expectedBytes: expected,
            stagingURL: staging,
            finalURL: final,
            startedAt: Date()
        )
    }

    // MARK: - Delegate handlers

    private func handleProgress(taskId: Int, bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpected: Int64, originalURL: URL?) async {
        if activeTasks[taskId] == nil, let url = originalURL, let parsed = parseHFDownloadURL(url),
           let meta = await rebuildMetadata(repoId: parsed.repoId, revision: parsed.revision, relativePath: parsed.relativePath) {
            DLog(.warn, "Progress", "rebuilt missing metadata taskId=\(taskId) repo=\(meta.repoId) path=\(meta.relativePath)")
            activeTasks[taskId] = meta
        }
        guard let meta = activeTasks[taskId] else {
            DLog(.error, "Progress", "DROP taskId=\(taskId) totalBytesWritten=\(totalBytesWritten) — no metadata")
            return
        }

        // RESTART DETECTION: log when totalBytesWritten goes backwards.
        // This is the smoking gun for a perceived "download restarted".
        let prev = taskBytesWritten[taskId] ?? 0
        if totalBytesWritten < prev {
            DLog(.error, "Progress", "REGRESSION taskId=\(taskId) repo=\(meta.repoId) path=\(meta.relativePath) prev=\(prev) now=\(totalBytesWritten) drop=\(prev - totalBytesWritten) — task likely restarted from 0 (resumeData invalid?)")
        } else if prev == 0 && totalBytesWritten > 0 {
            DLog(.info, "Progress", "FIRST_BYTES taskId=\(taskId) repo=\(meta.repoId) path=\(meta.relativePath) bytes=\(totalBytesWritten) expected=\(totalBytesExpected)")
        }

        taskBytesWritten[taskId] = totalBytesWritten
        taskLastProgressAt[taskId] = Date()
        taskStallCount[taskId] = 0

        if repoTotalBytes[meta.repoId] == nil {
            await initializeAggregates(forRepo: meta.repoId)
        }

        emitSnapshot(repoId: meta.repoId)

        // Throttled progress log every 10s per task (so users get a heartbeat).
        let now = Date()
        if let lastLog = lastProgressLogAt[taskId], now.timeIntervalSince(lastLog) < 10 {
            // skip log
        } else {
            lastProgressLogAt[taskId] = now
            let pct = totalBytesExpected > 0 ? Int(Double(totalBytesWritten) * 100 / Double(totalBytesExpected)) : 0
            DLog(.debug, "Progress", "taskId=\(taskId) repo=\(meta.repoId) path=\(meta.relativePath) \(totalBytesWritten / 1_048_576)/\(totalBytesExpected / 1_048_576)MB \(pct)%")
        }

        if let last = lastDBWriteAt[meta.repoId], now.timeIntervalSince(last) < 0.6 { return }
        lastDBWriteAt[meta.repoId] = now
        await setBytesOnDisk(repoId: meta.repoId, bytes: liveBytes(forRepo: meta.repoId))
    }

    private func handleFinishedDownload(taskId: Int, temporaryURL: URL, originalURL: URL?) async {
        if activeTasks[taskId] == nil, let url = originalURL, let parsed = parseHFDownloadURL(url),
           let meta = await rebuildMetadata(repoId: parsed.repoId, revision: parsed.revision, relativePath: parsed.relativePath) {
            activeTasks[taskId] = meta
        }
        guard let meta = activeTasks[taskId] else {
            DLog(.error, "Finished", "DROP taskId=\(taskId) — no metadata")
            // Make sure we don't leak the staged tmp file.
            try? fileManager.removeItem(at: temporaryURL)
            return
        }

        // Sanity-check the staged tmp actually exists. If the synchronous
        // delegate-side move succeeded, this is true. If it failed, the URL
        // we got is the original URLSession path — likely already gone.
        guard fileManager.fileExists(atPath: temporaryURL.path) else {
            DLog(.error, "Finished", "TMP_MISSING taskId=\(taskId) repo=\(meta.repoId) path=\(meta.relativePath) tmpPath=\(temporaryURL.lastPathComponent) — re-enqueueing for fresh download")
            taskBytesWritten[taskId] = nil
            lastProgressLogAt[taskId] = nil
            // Re-enqueue: the download bytes are unrecoverable but we can refetch.
            if let plan = await loadResumePlan(repoId: meta.repoId) {
                pendingQueue.append(
                    DownloadQueueItem(
                        repoId: meta.repoId,
                        revision: meta.revision,
                        file: RemoteFile(path: meta.relativePath, bytes: meta.expectedBytes, sha: nil),
                        destinationRoot: plan.root
                    )
                )
            }
            return
        }

        do {
            // Make sure the destination folder tree exists. createDirectory
            // with withIntermediateDirectories=true is idempotent.
            try fileManager.createDirectory(at: meta.stagingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: meta.stagingURL.path) {
                try fileManager.removeItem(at: meta.stagingURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: meta.stagingURL)

            try fileManager.createDirectory(at: meta.finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: meta.finalURL.path) {
                try fileManager.removeItem(at: meta.finalURL)
            }
            try fileManager.moveItem(at: meta.stagingURL, to: meta.finalURL)

            taskBytesWritten[taskId] = nil
            lastProgressLogAt[taskId] = nil
            repoCompletedBytes[meta.repoId, default: 0] += meta.expectedBytes
            DLog(.info, "Finished", "taskId=\(taskId) repo=\(meta.repoId) path=\(meta.relativePath) bytes=\(meta.expectedBytes / 1_048_576)MB")
            await markFileDownloaded(repoId: meta.repoId, path: meta.relativePath, totalBytes: liveBytes(forRepo: meta.repoId))
            emitSnapshot(repoId: meta.repoId)
            // Don't wait for handleCompletion — finalize here if this was the
            // last file. This avoids a race where handleCompletion runs before
            // markFileDownloaded's SwiftData save and sees the file as
            // un-downloaded, missing the complete transition.
            await finalizeIfRepoComplete(repoId: meta.repoId)
        } catch {
            DLog(.error, "Finished", "FILE_MOVE_FAILED taskId=\(taskId) repo=\(meta.repoId) path=\(meta.relativePath) err=\(error.localizedDescription) — re-enqueueing")
            // Best-effort cleanup of the staged tmp.
            try? fileManager.removeItem(at: temporaryURL)
            taskBytesWritten[taskId] = nil
            lastProgressLogAt[taskId] = nil
            // Don't flip the whole model to "failed" for one file move issue.
            // Re-enqueue this single file so the download can keep going.
            if let plan = await loadResumePlan(repoId: meta.repoId) {
                pendingQueue.append(
                    DownloadQueueItem(
                        repoId: meta.repoId,
                        revision: meta.revision,
                        file: RemoteFile(path: meta.relativePath, bytes: meta.expectedBytes, sha: nil),
                        destinationRoot: plan.root
                    )
                )
            }
        }
    }

    private func handleCompletion(taskId: Int, error: Error?, originalURL: URL?) async {
        let meta = activeTasks[taskId]
        let wasStallCancelled = stallCancelledTasks.remove(taskId) != nil
        let lastBytes = taskBytesWritten[taskId] ?? 0
        defer {
            activeTasks[taskId] = nil
            taskBytesWritten[taskId] = nil
            taskLastProgressAt[taskId] = nil
            taskStallCount[taskId] = nil
            lastProgressLogAt[taskId] = nil
        }

        if let error, let meta {
            let ns = error as NSError
            let resumeBytes = (ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data)?.count ?? 0
            log.error("task completed with error repo=\(meta.repoId, privacy: .public) path=\(meta.relativePath, privacy: .public) domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) desc=\(ns.localizedDescription, privacy: .public) stall=\(wasStallCancelled, privacy: .public)")
            DLog(.error, "Completion", "ERR taskId=\(taskId) repo=\(meta.repoId) path=\(meta.relativePath) bytesAtFail=\(lastBytes) domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription) stallCancelled=\(wasStallCancelled) resumeDataBytes=\(resumeBytes)")
            if wasStallCancelled {
                // Watchdog cancelled — re-enqueue with a fresh request so the
                // HF redirect resolves to a new CDN presigned URL.
                if let plan = await loadResumePlan(repoId: meta.repoId) {
                    DLog(.info, "Completion", "WATCHDOG_REQUEUE repo=\(meta.repoId) path=\(meta.relativePath) — lost progress=\(lastBytes) bytes")
                    pendingQueue.append(
                        DownloadQueueItem(
                            repoId: meta.repoId,
                            revision: meta.revision,
                            file: RemoteFile(path: meta.relativePath, bytes: meta.expectedBytes, sha: nil),
                            destinationRoot: plan.root
                        )
                    )
                } else {
                    DLog(.error, "Completion", "WATCHDOG_REQUEUE_FAILED repo=\(meta.repoId) — no resume plan")
                }
            } else if ns.domain == NSURLErrorDomain,
               ns.code == NSURLErrorCancelled,
               let resumeData = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                DLog(.info, "Completion", "USER_PAUSE_OK repo=\(meta.repoId) path=\(meta.relativePath) resumeData=\(resumeData.count)B")
                await persistResumeData(repoId: meta.repoId, path: meta.relativePath, resumeData: resumeData)
                await setModelStatus(repoId: meta.repoId, status: "paused")
            } else if ns.domain != NSURLErrorDomain || ns.code != NSURLErrorCancelled {
                // Non-cancel failure: attempt automatic restart with a fresh
                // request URL (covers HF CDN presigned URL expiration: 403 /
                // timed-out / network-lost during long suspension).
                if let plan = await loadResumePlan(repoId: meta.repoId) {
                    log.info("auto-retry repo=\(meta.repoId, privacy: .public) path=\(meta.relativePath, privacy: .public)")
                    DLog(.warn, "Completion", "AUTO_RETRY repo=\(meta.repoId) path=\(meta.relativePath) — lost progress=\(lastBytes) bytes (will restart from 0)")
                    pendingQueue.append(
                        DownloadQueueItem(
                            repoId: meta.repoId,
                            revision: meta.revision,
                            file: RemoteFile(path: meta.relativePath, bytes: meta.expectedBytes, sha: nil),
                            destinationRoot: plan.root
                        )
                    )
                } else {
                    DLog(.error, "Completion", "FAILED repo=\(meta.repoId) path=\(meta.relativePath) — no resume plan")
                    await setModelStatus(repoId: meta.repoId, status: "failed")
                }
            } else {
                DLog(.info, "Completion", "USER_CANCEL repo=\(meta.repoId) path=\(meta.relativePath) — no resumeData")
            }
            await maybeStartMoreTasks()
            return
        }

        guard let meta else {
            // Task already removed by cancel(). Still try to advance the queue.
            DLog(.warn, "Completion", "NO_META taskId=\(taskId) url=\(originalURL?.host ?? "nil")")
            if let url = originalURL, let parsed = parseHFDownloadURL(url) {
                await finalizeIfRepoComplete(repoId: parsed.repoId)
            }
            await maybeStartMoreTasks()
            return
        }

        let done = await areAllFilesDownloaded(repoId: meta.repoId)
        DLog(.info, "Completion", "OK taskId=\(taskId) repo=\(meta.repoId) path=\(meta.relativePath) repoComplete=\(done)")
        if done {
            await finalizeIfRepoComplete(repoId: meta.repoId)
        }
        await maybeStartMoreTasks()
    }

    /// Idempotent finalization: if every file for `repoId` is on disk, flip
    /// the model to `complete`, clean up temp folder, and clear in-memory
    /// progress aggregates. Safe to call multiple times.
    private func finalizeIfRepoComplete(repoId: String) async {
        let done = await areAllFilesDownloaded(repoId: repoId)
        guard done else { return }
        // Already complete? Skip.
        let already = await isModelStatus(repoId: repoId, "complete")
        if already { return }
        DLog(.info, "Finalize", "repo=\(repoId) all files on disk — marking complete")
        await deleteTempFolder(repoId: repoId)
        await setModelStatus(repoId: repoId, status: "complete")
        if let total = repoTotalBytes[repoId] {
            await setBytesOnDisk(repoId: repoId, bytes: total)
        }
        repoCompletedBytes[repoId] = nil
        repoTotalBytes[repoId] = nil
        repoSessionStart[repoId] = nil
        await MainActor.run { progressCenter.clear(repoId: repoId) }
    }

    @MainActor
    private func isModelStatus(repoId: String, _ status: String) -> Bool {
        let context = ModelContext(modelContainer)
        guard let models = try? context.fetch(FetchDescriptor<DownloadedModel>()) else { return false }
        return models.first(where: { $0.repoId == repoId })?.status == status
    }

    // MARK: - Aggregation helpers

    private func liveBytes(forRepo repoId: String) -> Int64 {
        let completed = repoCompletedBytes[repoId] ?? 0
        let inFlight = activeTasks
            .filter { $0.value.repoId == repoId }
            .map { taskBytesWritten[$0.key] ?? 0 }
            .reduce(0, +)
        let total = repoTotalBytes[repoId] ?? .max
        return min(completed + inFlight, total)
    }

    private func emitSnapshot(repoId: String) {
        guard let total = repoTotalBytes[repoId], total > 0 else { return }
        let written = liveBytes(forRepo: repoId)
        let started = repoSessionStart[repoId] ?? Date()
        let elapsed = max(Date().timeIntervalSince(started), 0.001)
        let sessionWritten = max(0, written - (repoCompletedBytes[repoId] ?? 0))
        let bps = Double(sessionWritten) / elapsed
        let frac = min(1.0, Double(written) / Double(total))
        let remaining = max(0, total - written)
        let eta = bps > 1 ? Double(remaining) / bps : nil

        let snap = DownloadProgressSnapshot(
            repoId: repoId,
            writtenBytes: written,
            totalBytes: total,
            bytesPerSecond: bps,
            fractionCompleted: frac,
            etaSeconds: eta
        )
        Task { @MainActor [progressCenter] in progressCenter.update(snap) }
    }

    private func initializeAggregates(forRepo repoId: String) async {
        guard let plan = await loadResumePlan(repoId: repoId) else { return }
        let alreadyFinalized = plan.files.reduce(Int64(0)) { acc, f in
            let final = plan.root.appendingPathComponent(f.path)
            return acc + (fileManager.fileExists(atPath: final.path) ? f.bytes : 0)
        }
        repoTotalBytes[repoId] = plan.totalBytes
        repoCompletedBytes[repoId] = alreadyFinalized
        repoSessionStart[repoId] = Date()
    }

    // MARK: - Disk

    private func ensureEnoughDiskSpace(requiredBytes: Int64) throws {
        let avail = (try? availableDiskSpaceBytes()) ?? 0
        if avail < requiredBytes {
            throw DownloadManagerError.insufficientDiskSpace(required: requiredBytes, available: avail)
        }
    }

    private func taskByIdentifier(_ taskId: Int) async -> URLSessionTask? {
        let tasks = await backgroundSession.allTasks
        return tasks.first { $0.taskIdentifier == taskId }
    }

    private func reconcileAllPersistedModels() async {
        let states = await loadAllPersistedDownloadStates()
        let liveRepos = Set(activeTasks.values.map { $0.repoId })
        DLog(.info, "Reconcile", "begin — persistedModels=\(states.count) liveRepos=\(liveRepos.count)")
        for state in states {
            var onDisk: Int64 = 0
            for file in state.files {
                let final = state.root.appendingPathComponent(file.path)
                if fileManager.fileExists(atPath: final.path) {
                    onDisk += fileSizeOnDisk(at: final) ?? file.bytes
                    if !file.downloaded {
                        await markFileDownloadedFlag(repoId: state.repoId, path: file.path, downloaded: true)
                    }
                } else {
                    let staging = state.root.appendingPathComponent(Self.tempFolderName).appendingPathComponent(file.path)
                    onDisk += fileSizeOnDisk(at: staging) ?? 0
                }
            }
            await setBytesOnDisk(repoId: state.repoId, bytes: onDisk)
            DLog(.info, "Reconcile", "repo=\(state.repoId) status=\(state.status) onDisk=\(onDisk / 1_048_576)MB live=\(liveRepos.contains(state.repoId))")

            switch state.status {
            case "downloading":
                if !liveRepos.contains(state.repoId) {
                    let allDone = state.files.allSatisfy { fileManager.fileExists(atPath: state.root.appendingPathComponent($0.path).path) }
                    let newStatus = allDone ? "complete" : "paused"
                    DLog(.warn, "Reconcile", "repo=\(state.repoId) was 'downloading' but no live task — transitioning to '\(newStatus)'")
                    await setModelStatus(repoId: state.repoId, status: newStatus)
                }
            case "queued":
                if !liveRepos.contains(state.repoId) {
                    DLog(.warn, "Reconcile", "repo=\(state.repoId) was 'queued' but no live task — transitioning to 'paused'")
                    await setModelStatus(repoId: state.repoId, status: "paused")
                }
            default: break
            }
        }
        DLog(.info, "Reconcile", "end")
    }

    private func fileSizeOnDisk(at url: URL) -> Int64? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    // MARK: - SwiftData persistence helpers

    @MainActor
    private func setModelStatus(repoId: String, status: String) {
        let context = ModelContext(modelContainer)
        guard let models = try? context.fetch(FetchDescriptor<DownloadedModel>()) else { return }
        guard let model = models.first(where: { $0.repoId == repoId }) else { return }
        if model.status != status {
            DLog(.info, "Status", "repo=\(repoId) \(model.status) → \(status)")
            model.status = status
            try? context.save()
        }
    }

    @MainActor
    private func setModelFolderBookmark(repoId: String, folder: URL) {
        let context = ModelContext(modelContainer)
        guard let models = try? context.fetch(FetchDescriptor<DownloadedModel>()) else { return }
        guard let model = models.first(where: { $0.repoId == repoId }) else { return }
        model.localFolderURL = try? folder.bookmarkData()
        try? context.save()
    }

    @MainActor
    private func setBytesOnDisk(repoId: String, bytes: Int64) {
        let context = ModelContext(modelContainer)
        guard let models = try? context.fetch(FetchDescriptor<DownloadedModel>()) else { return }
        guard let model = models.first(where: { $0.repoId == repoId }) else { return }
        let clamped = model.totalBytes > 0 ? min(bytes, model.totalBytes) : bytes
        if model.bytesOnDisk != clamped {
            model.bytesOnDisk = clamped
            try? context.save()
        }
    }

    @MainActor
    private func markFileDownloaded(repoId: String, path: String, totalBytes: Int64) {
        let context = ModelContext(modelContainer)
        guard let models = try? context.fetch(FetchDescriptor<DownloadedModel>()) else { return }
        guard let model = models.first(where: { $0.repoId == repoId }) else { return }
        if let file = model.files.first(where: { $0.relativePath == path }) {
            file.downloaded = true
            file.resumeData = nil
        }
        let clamped = model.totalBytes > 0 ? min(totalBytes, model.totalBytes) : totalBytes
        model.bytesOnDisk = clamped
        try? context.save()
    }

    @MainActor
    private func markFileDownloadedFlag(repoId: String, path: String, downloaded: Bool) {
        let context = ModelContext(modelContainer)
        guard let models = try? context.fetch(FetchDescriptor<DownloadedModel>()) else { return }
        guard let model = models.first(where: { $0.repoId == repoId }) else { return }
        if let file = model.files.first(where: { $0.relativePath == path }) {
            file.downloaded = downloaded
            if downloaded { file.resumeData = nil }
            try? context.save()
        }
    }

    @MainActor
    private func persistResumeData(repoId: String, path: String, resumeData: Data) {
        let context = ModelContext(modelContainer)
        guard let models = try? context.fetch(FetchDescriptor<DownloadedModel>()) else { return }
        guard let model = models.first(where: { $0.repoId == repoId }) else { return }
        if let file = model.files.first(where: { $0.relativePath == path }) {
            file.resumeData = resumeData
            file.downloaded = false
        }
        try? context.save()
    }

    @MainActor
    private func clearResumeData(repoId: String, path: String) {
        let context = ModelContext(modelContainer)
        guard let models = try? context.fetch(FetchDescriptor<DownloadedModel>()) else { return }
        guard let model = models.first(where: { $0.repoId == repoId }) else { return }
        if let file = model.files.first(where: { $0.relativePath == path }) {
            file.resumeData = nil
        }
        try? context.save()
    }

    @MainActor
    private func areAllFilesDownloaded(repoId: String) -> Bool {
        let context = ModelContext(modelContainer)
        guard let models = try? context.fetch(FetchDescriptor<DownloadedModel>()) else { return false }
        guard let model = models.first(where: { $0.repoId == repoId }) else { return false }
        guard !model.files.isEmpty else { return false }
        // Ground-truth check: if the file exists at its final URL on disk we
        // treat it as downloaded regardless of the SwiftData flag. This makes
        // completion detection race-free against the SwiftData save in
        // markFileDownloaded().
        guard let bookmark = model.localFolderURL else {
            return !model.files.contains(where: { !$0.downloaded })
        }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else {
            return !model.files.contains(where: { !$0.downloaded })
        }
        let fm = FileManager.default
        for f in model.files {
            let final = folder.appendingPathComponent(f.relativePath)
            if !fm.fileExists(atPath: final.path) && !f.downloaded {
                return false
            }
        }
        return true
    }

    @MainActor
    private func deleteLocalFolder(repoId: String) {
        let context = ModelContext(modelContainer)
        guard let models = try? context.fetch(FetchDescriptor<DownloadedModel>()) else { return }
        guard let model = models.first(where: { $0.repoId == repoId }) else { return }
        guard let bookmark = model.localFolderURL else { return }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return }
        if FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.removeItem(at: folder)
        }
        model.bytesOnDisk = 0
        for file in model.files {
            file.downloaded = false
            file.resumeData = nil
        }
        try? context.save()
    }

    @MainActor
    private func deleteTempFolder(repoId: String) {
        let context = ModelContext(modelContainer)
        guard let models = try? context.fetch(FetchDescriptor<DownloadedModel>()) else { return }
        guard let model = models.first(where: { $0.repoId == repoId }) else { return }
        guard let bookmark = model.localFolderURL else { return }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return }
        let temp = folder.appendingPathComponent(DownloadManager.tempFolderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: temp.path) {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    // MARK: - DB → in-actor data fetches

    private struct PersistedFileSpec: Sendable {
        let path: String
        let bytes: Int64
        let sha: String?
        let downloaded: Bool
        let resumeData: Data?
    }

    private struct PersistedDownloadState: Sendable {
        let repoId: String
        let revision: String
        let root: URL
        let totalBytes: Int64
        let status: String
        let files: [PersistedFileSpec]
    }

    @MainActor
    private func loadResumePlan(repoId: String) -> PersistedDownloadState? {
        let context = ModelContext(modelContainer)
        guard let models = try? context.fetch(FetchDescriptor<DownloadedModel>()) else { return nil }
        guard let model = models.first(where: { $0.repoId == repoId }) else { return nil }
        guard let bookmark = model.localFolderURL else { return nil }
        var stale = false
        guard let root = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return nil }
        let files = model.files.map {
            PersistedFileSpec(path: $0.relativePath, bytes: $0.bytes, sha: $0.sha, downloaded: $0.downloaded, resumeData: $0.resumeData)
        }
        return PersistedDownloadState(
            repoId: model.repoId,
            revision: "main",
            root: root,
            totalBytes: model.totalBytes,
            status: model.status,
            files: files
        )
    }

    @MainActor
    private func loadAllPersistedDownloadStates() -> [PersistedDownloadState] {
        let context = ModelContext(modelContainer)
        guard let models = try? context.fetch(FetchDescriptor<DownloadedModel>()) else { return [] }
        return models.compactMap { model -> PersistedDownloadState? in
            guard let bookmark = model.localFolderURL else { return nil }
            var stale = false
            guard let root = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return nil }
            let files = model.files.map {
                PersistedFileSpec(path: $0.relativePath, bytes: $0.bytes, sha: $0.sha, downloaded: $0.downloaded, resumeData: $0.resumeData)
            }
            return PersistedDownloadState(
                repoId: model.repoId,
                revision: "main",
                root: root,
                totalBytes: model.totalBytes,
                status: model.status,
                files: files
            )
        }
    }

    @MainActor
    private func fetchFileLocation(repoId: String, path: String) -> (URL, Int64)? {
        let context = ModelContext(modelContainer)
        guard let models = try? context.fetch(FetchDescriptor<DownloadedModel>()) else { return nil }
        guard let model = models.first(where: { $0.repoId == repoId }) else { return nil }
        guard let bookmark = model.localFolderURL else { return nil }
        var stale = false
        guard let root = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return nil }
        let bytes = model.files.first(where: { $0.relativePath == path })?.bytes ?? 0
        return (root, bytes)
    }
}
