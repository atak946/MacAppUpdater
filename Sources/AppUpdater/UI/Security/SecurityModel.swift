import AppKit
import Foundation
import MaintenanceCore
import Observation
import os

/// Drives the Security screen: system health checks and the privacy permissions audit.
@MainActor
@Observable
final class SecurityModel {
    /// Permissions of one privacy service, for one section of the page.
    struct PermissionGroup: Identifiable {
        let service: PrivacyService
        let entries: [PermissionEntry]
        var id: PrivacyService { service }
    }

    private(set) var report: SecurityReport?
    private(set) var permissions: PermissionAudit?
    private(set) var isChecking = false

    private let checker: any SecurityChecking
    private let auditor: any PermissionAuditing
    private let logger = Logger(subsystem: "com.macappupdater", category: "SecurityModel")
    @ObservationIgnored private var icons: [URL: NSImage] = [:]
    @ObservationIgnored private var checkTask: Task<Void, Never>?

    init(checker: any SecurityChecking, auditor: any PermissionAuditing) {
        self.checker = checker
        self.auditor = auditor
    }

    // MARK: Derived

    var score: Int? { report?.score }
    var needsFullDiskAccess: Bool { permissions == .needsFullDiskAccess }

    var allPermissions: [PermissionEntry] {
        if case .entries(let entries) = permissions { return entries }
        return []
    }

    /// Granted permissions flagged as unused or held by a removed app.
    var flaggedCount: Int { allPermissions.filter { !$0.flags.isEmpty }.count }

    /// Groups in `PrivacyService` order, filtered by app name or identifier.
    func permissionGroups(matching search: String) -> [PermissionGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = query.isEmpty
            ? allPermissions
            : allPermissions.filter { $0.appName.localizedStandardContains(query) || $0.client.localizedStandardContains(query) }
        let grouped = Dictionary(grouping: entries, by: \.service)
        return PrivacyService.allCases.compactMap { service in
            guard let items = grouped[service], !items.isEmpty else { return nil }
            return PermissionGroup(service: service, entries: items)
        }
    }

    /// App icon, cached; a generic icon for removed apps.
    func icon(for entry: PermissionEntry) -> NSImage {
        guard let url = entry.appURL else {
            return NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        if let cached = icons[url] { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[url] = image
        return image
    }

    // MARK: Actions

    /// Runs the first check when the page opens.
    func runIfNeeded() {
        guard report == nil, !isChecking else { return }
        runCheck()
    }

    func runCheck() {
        guard !isChecking else { return }
        isChecking = true
        let checker = self.checker
        let auditor = self.auditor
        checkTask = Task { [weak self] in
            // Tools and SQLite block, so both run off the main actor.
            async let report = Task.detached(priority: .userInitiated) { await checker.runChecks() }.value
            async let audit = Task.detached(priority: .userInitiated) { await auditor.audit() }.value
            let (newReport, newAudit) = await (report, audit)
            guard let self else { return }
            self.report = newReport
            self.permissions = newAudit
            self.isChecking = false
            self.logger.info("Security check done, score \(newReport.score ?? -1, privacy: .public)")
        }
    }

    /// Re-reads permissions only, e.g. after the user granted Full Disk Access.
    func refreshPermissions() {
        guard !isChecking else { return }
        let auditor = self.auditor
        Task { [weak self] in
            let audit = await Task.detached(priority: .userInitiated) { await auditor.audit() }.value
            self?.permissions = audit
        }
    }

    static func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
