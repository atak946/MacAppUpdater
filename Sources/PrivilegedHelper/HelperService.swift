import AppUpdaterCore
import Foundation
import os

/// Exported XPC object; one instance per accepted connection, bound to the caller's uid.
/// All instances share one `HelperPackageInstallCoordinator`, so installs are serialized.
final class HelperService: NSObject, PrivilegedHelperProtocol, Sendable {
    private static let logger = Logger(subsystem: HelperConstants.machServiceName, category: "HelperService")

    private let callerUID: uid_t
    private let coordinator: HelperPackageInstallCoordinator
    private let idleMonitor: HelperIdleMonitor

    init(callerUID: uid_t, coordinator: HelperPackageInstallCoordinator, idleMonitor: HelperIdleMonitor) {
        self.callerUID = callerUID
        self.coordinator = coordinator
        self.idleMonitor = idleMonitor
    }

    func version(withReply reply: @escaping @Sendable (String) -> Void) {
        reply(HelperConstants.helperVersion)
    }

    func installPackage(
        at fileHandle: FileHandle,
        expectedTeamID: String,
        withReply reply: @escaping @Sendable (Bool, String?) -> Void
    ) {
        idleMonitor.begin()
        let callerUID = callerUID
        let coordinator = coordinator
        let idleMonitor = idleMonitor
        Task {
            defer { idleMonitor.end() }
            do {
                try await coordinator.install(from: fileHandle, expectedTeamID: expectedTeamID, callerUID: callerUID)
                reply(true, nil)
            } catch {
                Self.logger.error("Install failed: \(error.localizedDescription, privacy: .private)")
                reply(false, error.localizedDescription)
            }
        }
    }
}
