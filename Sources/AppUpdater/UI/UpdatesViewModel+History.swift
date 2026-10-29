import AppUpdaterCore
import Foundation

/// History and backups / revert.
extension UpdatesViewModel {
    // MARK: History

    func loadHistory() async {
        history = await services.history?.entries() ?? []
    }

    func clearHistory() async {
        do {
            try await services.history?.clear()
        } catch {
            logger.error("Clearing history failed: \(error.localizedDescription, privacy: .public)")
        }
        await loadHistory()
    }

    func recordHistory(_ entry: UpdateHistoryEntry) async {
        guard let store = services.history else { return }
        do {
            try await store.record(entry)
        } catch {
            logger.error("Recording history failed: \(error.localizedDescription, privacy: .public)")
        }
        history = await store.entries()
    }

    // MARK: Backups

    func backup(for app: InstalledApp) -> AppBackup? {
        backups[app.bundleIdentifier]
    }

    /// Newest backup per installed app; called after every refresh.
    func refreshBackups() async {
        guard let store = services.backupStore else { return }
        var found: [String: AppBackup] = [:]
        for app in installedApps {
            if let newest = try? await store.backups(for: app.bundleIdentifier).first {
                found[app.bundleIdentifier] = newest
            }
        }
        backups = found
    }

    func refreshBackup(for app: InstalledApp) async {
        guard let store = services.backupStore else { return }
        let newest = try? await store.backups(for: app.bundleIdentifier).first
        let others = backups.filter { $0.key != app.bundleIdentifier }
        backups = others.merging(newest.map { [app.bundleIdentifier: $0] } ?? [:]) { _, new in new }
    }

    /// Restores the bundle backed up before the last update. Quits (and relaunches) the app.
    func revertToPreviousVersion(_ app: InstalledApp) async {
        guard let store = services.backupStore, let backup = backups[app.bundleIdentifier] else { return }
        do {
            try await store.restore(backup, over: app)
            backups = backups.filter { $0.key != app.bundleIdentifier }
            await recordHistory(UpdateHistoryEntry(rollbackOf: app, to: backup))
            await refresh()
        } catch {
            logger.error("Rollback of \(app.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            actionError = String(localized: "Could not revert \(app.name): \(error.localizedDescription)")
        }
    }
}
