import AppUpdaterCore
import Foundation
import os

/// Accepts connections from the signed app only and exports a `HelperService` per connection.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    private static let logger = Logger(subsystem: HelperConstants.machServiceName, category: "Listener")

    private let callerValidator = CallerValidator()
    private let coordinator = HelperPackageInstallCoordinator()
    let idleMonitor = HelperIdleMonitor {
        Logger(subsystem: HelperConstants.machServiceName, category: "Listener")
            .info("Idle for \(HelperConstants.idleExitSeconds, privacy: .public)s; exiting")
        exit(EXIT_SUCCESS)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard callerValidator.apply(to: connection) else {
            Self.logger.error("Refused connection from pid \(connection.processIdentifier): no caller requirement")
            return false
        }
        let callerUID = connection.effectiveUserIdentifier
        Self.logger.info("Connection from pid \(connection.processIdentifier) uid \(callerUID)")

        idleMonitor.begin()
        let idleMonitor = idleMonitor
        connection.exportedInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        connection.exportedObject = HelperService(callerUID: callerUID, coordinator: coordinator, idleMonitor: idleMonitor)
        connection.invalidationHandler = {
            Self.logger.debug("Connection invalidated")
            idleMonitor.end()
        }
        connection.resume()
        return true
    }
}

let logger = Logger(subsystem: HelperConstants.machServiceName, category: "Main")
let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
delegate.idleMonitor.start()
logger.info("Privileged helper \(HelperConstants.helperVersion, privacy: .public) listening")
dispatchMain()
