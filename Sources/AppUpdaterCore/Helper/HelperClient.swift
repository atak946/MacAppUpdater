import Foundation
import os
import ServiceManagement

/// Registration state of the privileged helper daemon.
public enum HelperStatus: Sendable, Equatable {
    case notRegistered
    case enabled
    /// Registered, but the user must allow it in System Settings → General → Login Items.
    case requiresApproval
    /// The launchd plist is missing from the app bundle (e.g. running via `swift run`).
    case notFound
}

public enum HelperClientError: Error, Sendable, Equatable, LocalizedError {
    case helperNotEnabled(HelperStatus)
    case registrationFailed(String)
    case unregistrationFailed(String)
    case connectionInterrupted
    case connectionInvalidated
    case remote(String)
    case timedOut
    case installFailed(String)
    /// Release build without a readable Team ID: no safe requirement for the helper exists.
    case untrustedBuild

    public var errorDescription: String? {
        switch self {
        case .helperNotEnabled(let status): String(coreLocalized: "Privileged helper is not enabled (\(String(describing: status)))")
        case .registrationFailed(let message): String(coreLocalized: "Could not register privileged helper: \(message)")
        case .unregistrationFailed(let message): String(coreLocalized: "Could not unregister privileged helper: \(message)")
        case .connectionInterrupted: String(coreLocalized: "Connection to privileged helper was interrupted")
        case .connectionInvalidated: String(coreLocalized: "Connection to privileged helper was invalidated")
        case .remote(let message): String(coreLocalized: "Privileged helper error: \(message)")
        case .timedOut: String(coreLocalized: "Privileged helper did not respond in time")
        case .installFailed(let message): String(coreLocalized: "Package installation failed: \(message)")
        case .untrustedBuild: String(coreLocalized: "This build is not signed with a Developer ID; the privileged helper cannot be used")
        }
    }
}

/// Seam used by `PackageInstaller` so tests can replace the XPC helper.
public protocol PackageInstallService: Sendable {
    /// Installs, as root, the flat `.pkg` readable through `fileHandle` (opened read-only by
    /// the caller after its own verification). The helper re-verifies that its private copy is
    /// a notarized Developer ID Installer package signed by `expectedTeamID`.
    func installPackage(from fileHandle: FileHandle, expectedTeamID: String) async throws
}

/// App-side client of the privileged helper: registration via `SMAppService`
/// and XPC calls over a privileged Mach service connection.
public actor HelperClient: PackageInstallService {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "HelperClient")

    private let installTimeout: Duration
    private let queryTimeout: Duration

    public init(installTimeout: Duration = .seconds(15 * 60), queryTimeout: Duration = .seconds(10)) {
        self.installTimeout = installTimeout
        self.queryTimeout = queryTimeout
    }

    // MARK: - Registration

    public var status: HelperStatus {
        Self.map(Self.service.status)
    }

    /// Registers the daemon. Returns `.requiresApproval` when the user still has to allow it.
    @discardableResult
    public func register() throws -> HelperStatus {
        do {
            try Self.service.register()
        } catch let error as NSError where error.code == kSMErrorLaunchDeniedByUser {
            Self.logger.info("Helper registration awaits user approval")
            return .requiresApproval
        } catch let error as NSError where error.code == kSMErrorAlreadyRegistered {
            Self.logger.debug("Helper already registered")
        } catch {
            throw HelperClientError.registrationFailed(error.localizedDescription)
        }
        let result = status
        Self.logger.info("Helper status after register: \(String(describing: result), privacy: .public)")
        return result
    }

    public func unregister() async throws {
        do {
            try await Self.service.unregister()
        } catch {
            throw HelperClientError.unregistrationFailed(error.localizedDescription)
        }
    }

    /// Opens System Settings → General → Login Items so the user can approve the helper.
    public nonisolated func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - XPC calls

    /// Version reported by the running helper.
    public func helperVersion() async throws -> String {
        try requireEnabled()
        return try await Self.perform(timeout: queryTimeout) { helper, complete in
            helper.version { complete(.success($0)) }
        }
    }

    /// True when the helper runs the version this app was built with.
    public func isHelperUpToDate() async -> Bool {
        (try? await helperVersion()) == HelperConstants.helperVersion
    }

    public func installPackage(from fileHandle: FileHandle, expectedTeamID: String) async throws {
        try requireEnabled()
        Self.logger.info("Requesting package install for team \(expectedTeamID, privacy: .public)")
        let message: String? = try await Self.perform(timeout: installTimeout) { helper, complete in
            helper.installPackage(at: fileHandle, expectedTeamID: expectedTeamID) { success, message in
                complete(.success(success ? nil : (message ?? "Unknown error")))
            }
        }
        if let message {
            throw HelperClientError.installFailed(message)
        }
    }

    private func requireEnabled() throws {
        let current = status
        guard current == .enabled else { throw HelperClientError.helperNotEnabled(current) }
    }

    // MARK: - Internals

    private static var service: SMAppService {
        SMAppService.daemon(plistName: HelperConstants.launchdPlistName)
    }

    static func map(_ status: SMAppService.Status) -> HelperStatus {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    /// Requirement the helper must satisfy; nil (fail closed) in release builds without a team.
    static func helperRequirement(
        teamIdentifier: String? = HelperCodeSigning.currentTeamIdentifier(),
        mode: HelperCodeSigning.RequirementMode = HelperCodeSigning.currentMode
    ) -> String? {
        HelperCodeSigning.peerRequirement(
            identifier: HelperConstants.helperCodeSigningIdentifier,
            teamIdentifier: teamIdentifier,
            mode: mode
        )
    }

    private static func makeConnection() throws(HelperClientError) -> NSXPCConnection {
        guard let requirement = helperRequirement() else {
            logger.fault("App has no Team ID; refusing to talk to the privileged helper")
            throw .untrustedBuild
        }
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        return connection
    }

    /// Opens a one-shot connection, invokes `body`, and resumes exactly once with the
    /// reply, an XPC error, interruption/invalidation, or a timeout.
    private static func perform<T: Sendable>(
        timeout: Duration,
        _ body: (any PrivilegedHelperProtocol, @escaping @Sendable (Result<T, HelperClientError>) -> Void) -> Void
    ) async throws -> T {
        let connection = try makeConnection()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let reply = OneShotReply(continuation: continuation)
            connection.interruptionHandler = { reply.resume(.failure(.connectionInterrupted)) }
            connection.invalidationHandler = { reply.resume(.failure(.connectionInvalidated)) }
            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                reply.resume(.failure(.remote(error.localizedDescription)))
            }
            guard let helper = proxy as? any PrivilegedHelperProtocol else {
                reply.resume(.failure(.remote("Unexpected proxy type")))
                return
            }
            reply.startTimeout(timeout)
            body(helper) { reply.resume($0) }
        }
    }
}

/// Resumes a continuation exactly once and cancels the pending timeout.
private final class OneShotReply<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var timeoutTask: Task<Void, Never>?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(continuation: CheckedContinuation<T, any Error>) {
        state = OSAllocatedUnfairLock(uncheckedState: State(continuation: continuation))
    }

    func startTimeout(_ timeout: Duration) {
        let task = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            self?.resume(.failure(.timedOut))
        }
        state.withLockUnchecked { $0.timeoutTask = task }
    }

    func resume(_ result: Result<T, HelperClientError>) {
        let taken = state.withLockUnchecked { state -> (CheckedContinuation<T, any Error>, Task<Void, Never>?)? in
            guard let continuation = state.continuation else { return nil }
            state.continuation = nil
            return (continuation, state.timeoutTask)
        }
        guard let (continuation, timeoutTask) = taken else { return }
        timeoutTask?.cancel()
        continuation.resume(with: result.mapError { $0 as any Error })
    }
}
