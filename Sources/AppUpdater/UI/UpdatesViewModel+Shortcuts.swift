import AppUpdaterCore
import Foundation

/// Outcome of an "Update All" run started outside the window (Shortcuts, Spotlight).
struct InstallAllSummary: Equatable, Sendable {
    /// App names, in install order.
    var installed: [String] = []
    /// Started but left for the user to finish (Installer.app, disk image, website).
    var needsAction: [String] = []
    var failed: [String] = []
    /// Pending updates "Update All" leaves alone: App Store, manual downloads, vendor updaters,
    /// newer macOS required or a disabled helper.
    var skipped: [String] = []
}

extension UpdatesViewModel {
    /// Same batch as the "Update All" button (`installableUpdates`), reported per app.
    func installAllSummarized() async -> InstallAllSummary {
        let batch = installableUpdates
        let batchIDs = Set(batch.map(\.id))
        var summary = InstallAllSummary(
            skipped: pendingUpdates.filter { !batchIDs.contains($0.id) }.map(\.app.name)
        )
        await installAll()
        for update in batch {
            switch installState(for: update) {
            case .installed: summary.installed.append(update.app.name)
            case .needsManualAction: summary.needsAction.append(update.app.name)
            case .failed: summary.failed.append(update.app.name)
            case .pending, .downloading, .installing: summary.skipped.append(update.app.name)
            }
        }
        return summary
    }
}
