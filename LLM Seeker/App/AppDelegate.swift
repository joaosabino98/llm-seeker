//
//  AppDelegate.swift
//  LLM Seeker
//
//  Bridges UIKit-level lifecycle hooks the SwiftUI App scaffolding doesn't
//  expose. Critical for background URLSession event delivery — without this,
//  iOS never gets its completion handler called when bg downloads emit
//  events, which breaks long-running downloads.
//

import UIKit
import os.log

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let log = Logger(subsystem: "com.joaosabino.LLM-Seeker", category: "AppDelegate")

    /// Background-session completion handler held until DownloadManager finishes
    /// processing the current batch of events.
    static var backgroundSessionCompletionHandler: (() -> Void)?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        DLog(.info, "AppLifecycle", "didFinishLaunchingWithOptions — starting bg-session reattach + watchdog")
        // Force-instantiate the DownloadManager so the background URLSession is
        // re-attached as early as possible. Without this, the system can drop
        // events that arrive before SwiftUI's first .task fires.
        Task.detached(priority: .userInitiated) {
            await DownloadManager.shared.rehydrateActiveTasks()
            await DownloadManager.shared.startWatchdog()
        }

        // Lifecycle observers help diagnose suspend/resume related restarts.
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            DLog(.info, "AppLifecycle", "didEnterBackground")
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            DLog(.info, "AppLifecycle", "willEnterForeground")
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            DLog(.info, "AppLifecycle", "didBecomeActive")
            Task.detached(priority: .userInitiated) {
                await DownloadManager.shared.rehydrateActiveTasks()
            }
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            DLog(.info, "AppLifecycle", "willResignActive")
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            DLog(.warn, "AppLifecycle", "willTerminate")
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            DLog(.warn, "AppLifecycle", "thermalState=\(ProcessInfo.processInfo.thermalState.rawValue)")
        }
        nc.addObserver(forName: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            DLog(.warn, "AppLifecycle", "lowPowerMode=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        }

        return true
    }

    /// Called by iOS when there are pending events for a background URLSession.
    /// We MUST stash the completion handler and call it after the session
    /// reports `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Self.log.info("handleEventsForBackgroundURLSession: \(identifier, privacy: .public)")
        DLog(.info, "AppLifecycle", "handleEventsForBackgroundURLSession id=\(identifier)")
        Self.backgroundSessionCompletionHandler = completionHandler
        // Touch the manager so the URLSession (with the same identifier) is alive.
        Task.detached(priority: .userInitiated) {
            _ = DownloadManager.shared
        }
    }
}
