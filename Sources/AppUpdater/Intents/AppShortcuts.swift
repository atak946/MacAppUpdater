import AppIntents

/// Phrases for Siri, Spotlight and the Shortcuts gallery. Each must mention the app name.
struct AppUpdaterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckForUpdatesIntent(),
            phrases: [
                "Check for updates with \(.applicationName)",
                "Check \(.applicationName) for app updates",
            ],
            shortTitle: "Check for Updates",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: UpdateAllAppsIntent(),
            phrases: [
                "Update all apps with \(.applicationName)",
                "Install app updates with \(.applicationName)",
            ],
            shortTitle: "Update All Apps",
            systemImageName: "arrow.down.app"
        )
        AppShortcut(
            intent: CleanCachesIntent(),
            phrases: [
                "Clean caches with \(.applicationName)",
                "Free up space with \(.applicationName)",
            ],
            shortTitle: "Clean Caches",
            systemImageName: "archivebox"
        )
    }
}
