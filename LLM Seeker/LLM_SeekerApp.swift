//
//  LLM_SeekerApp.swift
//  LLM Seeker
//

import SwiftUI
import SwiftData

@main
struct LLM_SeekerApp: App {
    static private(set) var sharedContainer: ModelContainer!
    let sharedModelContainer: ModelContainer

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        let schema = Schema([
            DownloadedModel.self,
            FileItem.self,
            MacProfile.self,
            SavedSearch.self,
            FavoriteModel.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            Self.seedDefaultMacProfileIfNeeded(container)
            self.sharedModelContainer = container
            Self.sharedContainer = container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }

        // Eagerly reattach the background URLSession as part of app init,
        // BEFORE the first SwiftUI render. Critical so iOS can deliver
        // pending background download events without dropping them.
        _ = DownloadManager.shared
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .task {
                    await DownloadManager.shared.rehydrateActiveTasks()
                    await DownloadManager.shared.startWatchdog()
                }
        }
        .modelContainer(sharedModelContainer)
    }

    private static func seedDefaultMacProfileIfNeeded(_ container: ModelContainer) {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<MacProfile>()
        guard let profiles = try? context.fetch(descriptor), profiles.isEmpty else { return }
        let defaultProfile = MacProfile(name: "My Mac", chipFamily: "M3 Pro", unifiedRAMGB: 18, isDefault: true)
        context.insert(defaultProfile)
        try? context.save()
    }
}
