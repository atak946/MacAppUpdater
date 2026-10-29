import Foundation
import os

/// Throwaway `UserDefaults` suites for tests. Every suite is a plist in ~/Library/Preferences,
/// so the domains are removed when the test process exits. Writes that land after that (a view
/// model still saving in the background) are swept on the next run, by the shared name prefix.
enum TestDefaults {
    static let prefix = "MacAppUpdaterTests."
    /// Older leftovers only, so a test run going on in parallel keeps its files.
    private static let sweepAge: TimeInterval = 600
    private static let names = OSAllocatedUnfairLock(initialState: [String]())
    private static let preferences = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences", isDirectory: true)

    private static let registerCleanup: Void = {
        sweepLeftovers()
        atexit {
            for name in TestDefaults.names.withLock({ $0 }) {
                // Flush pending writes first, or cfprefsd recreates the plist after it was removed.
                CFPreferencesAppSynchronize(name as CFString)
                UserDefaults.standard.removePersistentDomain(forName: name)
                try? FileManager.default.removeItem(at: TestDefaults.preferences.appendingPathComponent("\(name).plist"))
            }
        }
    }()

    static func suite(named name: String) -> UserDefaults? {
        _ = registerCleanup
        let fullName = prefix + name
        names.withLock { $0.append(fullName) }
        return UserDefaults(suiteName: fullName)
    }

    private static func sweepLeftovers() {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(
            at: preferences, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let cutoff = Date(timeIntervalSinceNow: -sweepAge)
        for file in files where file.lastPathComponent.hasPrefix(prefix) && file.pathExtension == "plist" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
