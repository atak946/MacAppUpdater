import AppUpdaterCore
import Foundation

/// Insights, warnings and uninstalling.
extension UpdatesViewModel {
    // MARK: Insights

    /// Expensive (reads every bundle); run on demand, never on each scheduled check.
    func refreshInsights() async {
        // Before the first scan there's nothing to analyze; an empty report would stick.
        guard let collector = services.insights, !isLoadingInsights, !installedApps.isEmpty else { return }
        isLoadingInsights = true
        defer { isLoadingInsights = false }
        insights = await collector.collect(
            apps: installedApps, updates: updates, vendorManagement: vendorManagementCache
        )
    }

    /// Warnings for an app, most severe first. Before insights were collected, only the cheap
    /// checks run (update compatibility, download host change, vendor management).
    func warnings(for app: InstalledApp) -> [AppWarning] {
        if let insights { return insights.warnings(for: app.bundleIdentifier) }
        let update = update(for: app)
        let input = AppAnalysisInput(
            app: app, details: nil, update: update,
            downloadHostChange: update.flatMap { services.downloadHosts?.check($0) },
            vendorManagement: vendorManagement(for: app)
        )
        return services.compatibility.warnings(for: input)
    }

    // MARK: Uninstall

    /// False when the uninstaller is disabled by the organization (MDM) or refuses the app.
    func canUninstall(_ app: InstalledApp) -> Bool {
        managedGate.isUninstallerAllowed && services.uninstaller.refusal(for: app) == nil
    }

    /// Enforced here as well as in `canUninstall`, so a hidden button is not the only barrier (L-6).
    func uninstallPlan(for app: InstalledApp) async throws -> UninstallPlan {
        try requireUninstallerAllowed()
        return try await services.uninstaller.scan(app)
    }

    func uninstall(_ plan: UninstallPlan, selected: Set<URL>) async throws -> UninstallReport {
        try requireUninstallerAllowed()
        return try await services.uninstaller.uninstall(plan, selected: selected)
    }

    private func requireUninstallerAllowed() throws(UninstallError) {
        guard managedGate.isUninstallerAllowed else { throw .disabledByOrganization }
    }

    func quit(_ app: InstalledApp) async throws {
        try await RunningAppTerminator().terminateRunningInstances(of: app.bundleIdentifier)
    }

    /// Called after the uninstall sheet finished; rescans so the removed app disappears.
    func didUninstall(_ report: UninstallReport) {
        guard report.removedAppBundle else { return }
        Task { await refresh() }
    }
}
