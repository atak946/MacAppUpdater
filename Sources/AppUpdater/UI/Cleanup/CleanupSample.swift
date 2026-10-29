#if DEBUG
import Foundation
import MaintenanceCore

/// Canned scan report for reviewing the Cleanup screen in DEBUG builds.
/// Launch with `-CleanupSample YES` to show it instead of the idle state.
enum CleanupSample {
    static let launchKey = "CleanupSample"

    static var isRequested: Bool { UserDefaults.standard.bool(forKey: launchKey) }

    static let report: CleanupScanReport = {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let day: TimeInterval = 86_400
        let now = Date()
        func item(_ path: String, _ category: CleanupCategory, _ name: String, _ megabytes: Double, daysAgo: Double) -> CleanupItem {
            CleanupItem(
                url: home.appendingPathComponent(path),
                category: category,
                displayName: name,
                sizeInBytes: Int64(megabytes * 1_000_000),
                lastAccessed: now.addingTimeInterval(-daysAgo * day)
            )
        }
        func leftover(_ path: String, _ owner: String, _ megabytes: Double, daysAgo: Double) -> CleanupItem {
            let url = home.appendingPathComponent(path)
            return CleanupItem(
                url: url,
                category: .removedAppLeftovers,
                displayName: url.lastPathComponent,
                sizeInBytes: Int64(megabytes * 1_000_000),
                ownerBundleIdentifier: owner,
                lastModified: now.addingTimeInterval(-daysAgo * day)
            )
        }
        let groups: [CleanupGroup] = [
            CleanupGroup(category: .xcodeDerivedData, items: [
                item("Library/Developer/Xcode/DerivedData/MacAppUpdater-abc", .xcodeDerivedData, "MacAppUpdater", 6_240, daysAgo: 1),
                item("Library/Developer/Xcode/DerivedData/NotchHub-def", .xcodeDerivedData, "NotchHub", 3_910, daysAgo: 4),
                item("Library/Developer/Xcode/DerivedData/Playground-ghi", .xcodeDerivedData, "Playground", 412, daysAgo: 60),
            ]),
            CleanupGroup(category: .userCaches, items: (1...9).map { index in
                item("Library/Caches/com.example.app\(index)", .userCaches, "Example App \(index)", Double(1_200 / index), daysAgo: Double(index))
            }),
            CleanupGroup(category: .deviceSupport, items: [
                item("Library/Developer/Xcode/iOS DeviceSupport/17.5 (21F79)", .deviceSupport, "iOS 17.5", 4_100, daysAgo: 120),
                item("Library/Developer/Xcode/iOS DeviceSupport/18.0 (22A3354)", .deviceSupport, "iOS 18.0", 3_800, daysAgo: 30),
            ]),
            CleanupGroup(category: .packageManagerCaches, items: [
                item("Library/Caches/Homebrew", .packageManagerCaches, "Homebrew", 2_300, daysAgo: 2),
                item(".npm/_cacache", .packageManagerCaches, "npm", 1_150, daysAgo: 6),
                item(".gradle/caches", .packageManagerCaches, "Gradle", 870, daysAgo: 45),
            ]),
            CleanupGroup(category: .oldInstallers, items: [
                item("Downloads/Xcode_16.dmg", .oldInstallers, "Xcode_16.dmg", 1_900, daysAgo: 200),
                item("Downloads/Docker.dmg", .oldInstallers, "Docker.dmg", 610, daysAgo: 95),
            ]),
            CleanupGroup(category: .logs, items: [
                item("Library/Logs/DiagnosticReports", .logs, "Diagnostic Reports", 180, daysAgo: 9),
                item("Library/Logs/JetBrains", .logs, "JetBrains", 96, daysAgo: 14),
            ]),
            CleanupGroup(category: .trash, items: [
                item(".Trash/Old Project", .trash, "Old Project", 240, daysAgo: 20),
            ]),
            CleanupGroup(category: .removedAppLeftovers, items: [
                leftover("Library/Application Support/com.example.Editor", "com.example.Editor", 320, daysAgo: 90),
                leftover("Library/Preferences/com.example.Editor.plist", "com.example.Editor", 0.02, daysAgo: 90),
                leftover("Library/Containers/org.sample.Notes", "org.sample.Notes", 140, daysAgo: 400),
            ]),
        ]
        return CleanupScanReport(groups: groups.sorted { $0.totalSize > $1.totalSize }, scannedAt: now)
    }()
}
#endif
