import AppKit
import Foundation
import MaintenanceCore
import Observation
import os

/// Drives the Startup Items screen: scanning launchd jobs and toggling user LaunchAgents.
@MainActor
@Observable
final class StartupModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    static let loginItemsSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    private(set) var state: State = .idle
    private(set) var items: [StartupItem] = []
    /// Legacy "Open at Login" apps; nil when macOS doesn't let the app read them.
    private(set) var loginItems: [BackgroundLoginItem]?
    /// Items with a launchctl change in flight.
    private(set) var pendingIDs: Set<StartupItem.ID> = []
    /// Last failed change, shown as a banner until dismissed.
    var actionError: String?
    /// Apple's own jobs are hidden unless the user asks for them.
    var showsAppleItems = false

    private let scanner: any StartupScanning
    private let controller: any StartupControlling
    private let logger = Logger(subsystem: "com.macappupdater", category: "StartupModel")
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]

    init(scanner: any StartupScanning, controller: any StartupControlling) {
        self.scanner = scanner
        self.controller = controller
    }

    // MARK: Derived

    /// Items after the Apple toggle; the page filters and sorts these further.
    var visibleItems: [StartupItem] {
        showsAppleItems ? items : items.filter { !$0.isAppleItem }
    }

    var isLoading: Bool { state == .loading }

    // MARK: Loading

    /// Scans once; later calls are ignored until `refresh()`.
    func loadIfNeeded() async {
        guard state == .idle else { return }
        await refresh()
    }

    func refresh() async {
        guard state != .loading else { return }
        state = .loading
        let scanner = self.scanner
        // The scanner runs Process and SecStaticCode work off the main actor.
        let result = await Task.detached(priority: .userInitiated) { await scanner.scan() }.value
        items = result.items
        loginItems = result.loginItems
        state = .loaded
        logger.info("Found \(result.items.count, privacy: .public) startup items")
    }

    // MARK: Actions

    func setEnabled(_ enabled: Bool, for item: StartupItem) async {
        guard item.isControllable, !pendingIDs.contains(item.id) else { return }
        pendingIDs.insert(item.id)
        defer { pendingIDs.remove(item.id) }
        do {
            let updated = try await controller.setEnabled(enabled, for: item)
            items = items.map { $0.id == updated.id ? updated : $0 }
        } catch StartupControlError.cancelled {
            // Dismissing the password prompt is a choice, not an error.
            logger.info("Changing \(item.label, privacy: .public) was cancelled")
        } catch {
            logger.error("Changing \(item.label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            actionError = error.localizedDescription
        }
    }

    func isPending(_ item: StartupItem) -> Bool { pendingIDs.contains(item.id) }

    func revealInFinder(_ item: StartupItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.plistURL])
    }

    func revealExecutable(_ item: StartupItem) {
        guard let url = item.executableURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyLabel(_ item: StartupItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.label, forType: .string)
    }

    func openLoginItemsSettings() {
        guard let url = Self.loginItemsSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Owning app's icon; nil when no app was found (the row shows an `IconTile`).
    func icon(for item: StartupItem) -> NSImage? {
        guard let url = item.appBundleURL else { return nil }
        if let cached = iconCache[url.path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[url.path] = image
        return image
    }
}
