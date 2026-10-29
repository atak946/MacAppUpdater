import AppUpdaterCore
import Foundation
import MaintenanceCore

/// Made-up library for the README screenshots: well-known public apps with plausible versions and
/// sizes. Nothing here is read from the machine; bundle URLs point into the throwaway demo folder.
enum DemoFixtures {
    struct App {
        let name: String
        let bundleID: String
        let version: String
        /// Icon art: SF Symbol and two gradient colors (hex RGB). Generic, never the vendor's logo.
        let symbol: String
        let colors: (UInt32, UInt32)
        let megabytes: Double
        let lastUsedDaysAgo: Double
        var isIntelOnly = false
        var isFromAppStore = false
    }

    struct Update {
        let bundleID: String
        let newVersion: String
        let source: UpdateSourceKind
        let downloadMegabytes: Double
        let publishedDaysAgo: Double
        var notes: ReleaseNotes?
        var minimumSystemVersion: String?
    }

    /// The fictional CVE the security-flagged update fixes.
    static let securityCVE = "CVE-2026-41207"
    /// macOS version the compatibility checks compare against, fixed so the host never shows.
    static let systemVersion = "15.1"

    static let apps: [App] = [
        App(name: "Firefox", bundleID: "org.mozilla.firefox", version: "131.0.3", symbol: "flame.fill",
            colors: (0xFF9500, 0xB4237A), megabytes: 412, lastUsedDaysAgo: 0.1),
        App(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", version: "4.40.126", symbol: "number",
            colors: (0x7B3FA0, 0x3E1150), megabytes: 498, lastUsedDaysAgo: 0.05),
        App(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode", version: "1.94.2",
            symbol: "chevron.left.forwardslash.chevron.right", colors: (0x2AA4F4, 0x0A5BB5),
            megabytes: 611, lastUsedDaysAgo: 0.02),
        App(name: "Figma", bundleID: "com.figma.Desktop", version: "124.4.7", symbol: "pencil.and.outline",
            colors: (0xF24E1E, 0xA259FF), megabytes: 336, lastUsedDaysAgo: 1.5),
        App(name: "Zoom", bundleID: "us.zoom.xos", version: "6.2.5", symbol: "video.fill",
            colors: (0x4A8CFF, 0x1F4FD8), megabytes: 287, lastUsedDaysAgo: 2),
        App(name: "Spotify", bundleID: "com.spotify.client", version: "1.2.47", symbol: "waveform",
            colors: (0x3BE477, 0x128A3E), megabytes: 352, lastUsedDaysAgo: 0.3),
        App(name: "Docker", bundleID: "com.docker.docker", version: "4.34.3", symbol: "shippingbox.fill",
            colors: (0x3AA0F0, 0x1360B8), megabytes: 2_140, lastUsedDaysAgo: 0.4),
        App(name: "iTerm2", bundleID: "com.googlecode.iterm2", version: "3.5.6", symbol: "terminal.fill",
            colors: (0x4A4F57, 0x16181C), megabytes: 94, lastUsedDaysAgo: 0.01),
        App(name: "Rectangle", bundleID: "com.knollsoft.Rectangle", version: "0.83", symbol: "rectangle.split.2x1.fill",
            colors: (0x6E7BFF, 0x3A2FB8), megabytes: 21, lastUsedDaysAgo: 0.01),
        App(name: "Google Chrome", bundleID: "com.google.Chrome", version: "130.0.6723.92", symbol: "globe",
            colors: (0x34A853, 0x1A73E8), megabytes: 1_310, lastUsedDaysAgo: 3),
        App(name: "Obsidian", bundleID: "md.obsidian", version: "1.7.4", symbol: "diamond.fill",
            colors: (0x9C6CFF, 0x4B2A9E), megabytes: 263, lastUsedDaysAgo: 0.8),
        App(name: "VLC", bundleID: "org.videolan.vlc", version: "3.0.21", symbol: "play.fill",
            colors: (0xFF9A1F, 0xE0560B), megabytes: 182, lastUsedDaysAgo: 41),
        App(name: "Blender", bundleID: "org.blenderfoundation.blender", version: "4.2.3", symbol: "cube.transparent.fill",
            colors: (0xF5792A, 0x265787), megabytes: 1_020, lastUsedDaysAgo: 214),
        App(name: "Steam", bundleID: "com.valvesoftware.steam", version: "4.0", symbol: "gamecontroller.fill",
            colors: (0x2A6FA8, 0x101C2E), megabytes: 760, lastUsedDaysAgo: 128, isIntelOnly: true),
        App(name: "Microsoft Word", bundleID: "com.microsoft.Word", version: "16.90", symbol: "doc.richtext.fill",
            colors: (0x41A5EE, 0x185ABD), megabytes: 2_480, lastUsedDaysAgo: 9),
        App(name: "Keynote", bundleID: "com.apple.iWork.Keynote", version: "14.2", symbol: "rectangle.on.rectangle.angled.fill",
            colors: (0x3D9BFF, 0x1D5FD1), megabytes: 690, lastUsedDaysAgo: 18, isFromAppStore: true),
    ]

    static let updates: [Update] = [
        Update(bundleID: "org.mozilla.firefox", newVersion: "132.0.1", source: .homebrew,
               downloadMegabytes: 138, publishedDaysAgo: 1,
               notes: .markdown("""
               ## Security fixes
               Fixes a use-after-free in the JavaScript engine that could be exploited by a crafted page \
               (\(securityCVE)).
               """)),
        Update(bundleID: "com.tinyspeck.slackmacgap", newVersion: "4.41.97", source: .electron,
               downloadMegabytes: 182, publishedDaysAgo: 2),
        Update(bundleID: "com.microsoft.VSCode", newVersion: "1.95.1", source: .homebrew,
               downloadMegabytes: 151, publishedDaysAgo: 3),
        Update(bundleID: "com.figma.Desktop", newVersion: "124.5.4", source: .electron,
               downloadMegabytes: 117, publishedDaysAgo: 4),
        Update(bundleID: "com.docker.docker", newVersion: "4.35.1", source: .sparkle,
               downloadMegabytes: 534, publishedDaysAgo: 5, minimumSystemVersion: "15.2"),
        Update(bundleID: "com.googlecode.iterm2", newVersion: "3.5.10", source: .sparkle,
               downloadMegabytes: 31, publishedDaysAgo: 6),
        Update(bundleID: "com.knollsoft.Rectangle", newVersion: "0.84", source: .github,
               downloadMegabytes: 5.2, publishedDaysAgo: 9),
    ]

    /// The short list in the menu bar panel shot.
    static let menuBarUpdateIDs: Set<String> = ["org.mozilla.firefox", "com.tinyspeck.slackmacgap", "com.knollsoft.Rectangle"]

    /// Recently installed updates for the Overview "Recent" card.
    static func history(now: Date) -> [UpdateHistoryEntry] {
        let hour: TimeInterval = 3600
        return [
            entry("com.spotify.client", "Spotify", "1.2.46", "1.2.47", .homebrew, now - 3 * hour),
            entry("us.zoom.xos", "Zoom", "6.2.3", "6.2.5", .vendor, now - 26 * hour),
            entry("md.obsidian", "Obsidian", "1.7.2", "1.7.4", .github, now - 50 * hour),
            entry("com.google.Chrome", "Google Chrome", "130.0.6723.70", "130.0.6723.92", .homebrew, now - 74 * hour),
            entry("org.videolan.vlc", "VLC", "3.0.20", "3.0.21", .sparkle, now - 120 * hour),
        ]
    }

    private static func entry(
        _ bundleID: String, _ name: String, _ from: String, _ to: String, _ source: UpdateSourceKind, _ date: Date
    ) -> UpdateHistoryEntry {
        UpdateHistoryEntry(
            bundleID: bundleID, appName: name, fromVersion: from, toVersion: to,
            source: source, date: date, outcome: .succeeded
        )
    }

    static let formulae: [OutdatedFormula] = [
        OutdatedFormula(name: "node", installedVersions: ["22.9.0"], currentVersion: "23.1.0", pinned: false),
        OutdatedFormula(name: "git", installedVersions: ["2.46.2"], currentVersion: "2.47.0", pinned: false),
        OutdatedFormula(name: "python@3.13", installedVersions: ["3.13.0"], currentVersion: "3.13.0_1", pinned: false),
        OutdatedFormula(name: "ffmpeg", installedVersions: ["7.0.2"], currentVersion: "7.1", pinned: false),
    ]

    // MARK: Insights

    /// Warnings per bundle id for the Insights page.
    static let warnings: [String: [AppWarning]] = [
        "com.valvesoftware.steam": [AppWarning(.intelOnly), AppWarning(.notOpenedInLongTime(days: 128))],
        "com.docker.docker": [AppWarning(.updateRequiresNewerMacOS(required: "15.2"))],
        "org.blenderfoundation.blender": [AppWarning(.notOpenedInLongTime(days: 214))],
        "com.microsoft.Word": [AppWarning(.managedByVendor(updaterName: "Microsoft AutoUpdate"))],
        "org.videolan.vlc": [AppWarning(.downloadHostChanged(previous: "get.videolan.org", current: "download.videolan.org"))],
    ]

    static func insightsReport(apps: [InstalledApp], now: Date) -> InsightsReport {
        let insights = apps.compactMap { app -> AppInsight? in
            guard let fixture = self.apps.first(where: { $0.bundleID == app.bundleIdentifier }) else { return nil }
            return AppInsight(
                app: app,
                sizeInBytes: Int64(fixture.megabytes * 1_000_000),
                lastUsedDate: now.addingTimeInterval(-fixture.lastUsedDaysAgo * 86_400),
                isIntelOnly: fixture.isIntelOnly,
                warnings: warnings[app.bundleIdentifier] ?? []
            )
        }
        return InsightsBuilder().build(from: insights, now: now)
    }

    // MARK: Cleanup

    /// Junk under the current home folder; the page shows parents as `~/…`, so no user name appears.
    static func cleanupReport(home: URL, now: Date) -> CleanupScanReport {
        let day: TimeInterval = 86_400
        func item(_ path: String, _ category: CleanupCategory, _ name: String, _ megabytes: Double, _ daysAgo: Double) -> CleanupItem {
            CleanupItem(
                url: home.appendingPathComponent(path), category: category, displayName: name,
                sizeInBytes: Int64(megabytes * 1_000_000), lastAccessed: now.addingTimeInterval(-daysAgo * day)
            )
        }
        func leftover(_ path: String, _ owner: String, _ megabytes: Double, _ daysAgo: Double) -> CleanupItem {
            let url = home.appendingPathComponent(path)
            return CleanupItem(
                url: url, category: .removedAppLeftovers, displayName: url.lastPathComponent,
                sizeInBytes: Int64(megabytes * 1_000_000), ownerBundleIdentifier: owner,
                lastModified: now.addingTimeInterval(-daysAgo * day)
            )
        }
        let groups = [
            CleanupGroup(category: .xcodeDerivedData, items: [
                item("Library/Developer/Xcode/DerivedData/WeatherKitDemo-bxqz", .xcodeDerivedData, "WeatherKitDemo", 4_820, 2),
                item("Library/Developer/Xcode/DerivedData/TodoApp-fkdl", .xcodeDerivedData, "TodoApp", 2_960, 6),
                item("Library/Developer/Xcode/DerivedData/Playground-hzpe", .xcodeDerivedData, "Playground", 412, 60),
            ]),
            CleanupGroup(category: .userCaches, items: [
                item("Library/Caches/com.spotify.client", .userCaches, "Spotify", 1_840, 0.2),
                item("Library/Caches/Google", .userCaches, "Google", 960, 1),
                item("Library/Caches/com.tinyspeck.slackmacgap", .userCaches, "Slack", 610, 0.5),
                item("Library/Caches/Firefox", .userCaches, "Firefox", 540, 0.1),
                item("Library/Caches/com.microsoft.VSCode.ShipIt", .userCaches, "Visual Studio Code", 290, 3),
            ]),
            CleanupGroup(category: .deviceSupport, items: [
                item("Library/Developer/Xcode/iOS DeviceSupport/17.5 (21F79)", .deviceSupport, "iOS 17.5", 4_100, 120),
                item("Library/Developer/Xcode/iOS DeviceSupport/18.0 (22A3354)", .deviceSupport, "iOS 18.0", 3_800, 30),
            ]),
            CleanupGroup(category: .packageManagerCaches, items: [
                item("Library/Caches/Homebrew", .packageManagerCaches, "Homebrew", 2_300, 2),
                item(".npm/_cacache", .packageManagerCaches, "npm", 1_150, 6),
                item(".gradle/caches", .packageManagerCaches, "Gradle", 870, 45),
            ]),
            CleanupGroup(category: .oldInstallers, items: [
                item("Downloads/Firefox 131.0.dmg", .oldInstallers, "Firefox 131.0.dmg", 138, 32),
                item("Downloads/Docker.dmg", .oldInstallers, "Docker.dmg", 610, 95),
            ]),
            CleanupGroup(category: .logs, items: [
                item("Library/Logs/DiagnosticReports", .logs, "Diagnostic Reports", 180, 9),
                item("Library/Logs/Zoom", .logs, "Zoom", 64, 14),
            ]),
            CleanupGroup(category: .trash, items: [
                item(".Trash/Old Screenshots", .trash, "Old Screenshots", 240, 20),
            ]),
            CleanupGroup(category: .removedAppLeftovers, items: [
                leftover("Library/Application Support/com.sublimetext.4", "com.sublimetext.4", 320, 90),
                leftover("Library/Preferences/com.sublimetext.4.plist", "com.sublimetext.4", 0.02, 90),
                leftover("Library/Containers/com.evernote.Evernote", "com.evernote.Evernote", 1_140, 400),
                leftover("Library/Caches/com.evernote.Evernote", "com.evernote.Evernote", 86, 400),
            ]),
        ]
        return CleanupScanReport(groups: groups.sorted { $0.totalSize > $1.totalSize }, scannedAt: now)
    }
}

extension DemoFixtures.App {
    var bundleFolderName: String { "\(name).app" }
}
