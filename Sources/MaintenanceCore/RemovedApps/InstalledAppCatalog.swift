import AppKit
import AppUpdaterCore
import Foundation
import os

/// What is installed or running right now; anything named after these is never a removed-app leftover.
public struct InstalledAppSnapshot: Sendable, Hashable {
    /// Bundle identifiers of the apps the app scanner finds.
    public let installedBundleIdentifiers: Set<String>
    /// Bundle identifiers of running processes (apps, agents and helpers known to LaunchServices).
    public let runningBundleIdentifiers: Set<String>
    /// Team identifiers the installed apps are signed by.
    public let teamIdentifiers: Set<String>

    public init(
        installedBundleIdentifiers: Set<String>,
        runningBundleIdentifiers: Set<String>,
        teamIdentifiers: Set<String>
    ) {
        self.installedBundleIdentifiers = installedBundleIdentifiers
        self.runningBundleIdentifiers = runningBundleIdentifiers
        self.teamIdentifiers = teamIdentifiers
    }
}

/// Answers "is this app still on the Mac?". Injected so tests never depend on the real system.
public protocol InstalledAppCataloging: Sendable {
    /// Installed and running apps. Throws when the installed apps cannot be listed.
    func snapshot() async throws -> InstalledAppSnapshot
    /// Second check: whether LaunchServices still knows an app with this bundle identifier.
    func isKnownToLaunchServices(_ bundleIdentifier: String) -> Bool
}

/// Production catalog: `AppScanner`, the signing team of each app, running apps and LaunchServices.
public struct LiveInstalledAppCatalog: InstalledAppCataloging {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "InstalledAppCatalog")

    private let scanner: AppScanner
    private let verifier: any SignatureVerifying

    public init(scanner: AppScanner = AppScanner(), verifier: any SignatureVerifying = CodeSignatureVerifier()) {
        self.scanner = scanner
        self.verifier = verifier
    }

    public func snapshot() async throws -> InstalledAppSnapshot {
        let apps = try await scanner.scan()
        var teams = Set<String>()
        for app in apps {
            try Task.checkCancellation()
            // Inspect only (no resource hashing): the team is used to keep data, never to trust code.
            if let team = try? await verifier.signingTeam(of: app.url) { teams.insert(team) }
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        Self.logger.info("Catalog: \(apps.count) installed, \(running.count) running, \(teams.count) teams")
        return InstalledAppSnapshot(
            installedBundleIdentifiers: Set(apps.map(\.bundleIdentifier)),
            runningBundleIdentifiers: running,
            teamIdentifiers: teams
        )
    }

    public func isKnownToLaunchServices(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
}
