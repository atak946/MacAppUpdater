import AppKit
import os

/// Launches an app bundle again after it was quit for an update or rollback.
public protocol AppRelaunching: Sendable {
    func relaunch(_ appURL: URL) async throws
}

public struct WorkspaceAppRelauncher: AppRelaunching {
    public init() {}

    public func relaunch(_ appURL: URL) async throws {
        try await Self.open(appURL)
    }

    @MainActor
    private static func open(_ appURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}

extension AppRelaunching {
    /// Relaunch failures never fail an install that already succeeded; they are only logged.
    func relaunchLoggingFailure(_ appURL: URL, logger: Logger) async {
        do {
            try await relaunch(appURL)
            logger.info("Relaunched \(appURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Relaunch of \(appURL.lastPathComponent, privacy: .public) failed (\(appURL.path, privacy: .private)): \(error.localizedDescription, privacy: .private)")
        }
    }
}
