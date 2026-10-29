import AppKit
import Darwin
import Foundation
import os

/// Quits processes: apps via `NSRunningApplication`, everything else via SIGTERM / SIGKILL.
/// Critical processes, pid ≤ 1 and the current process are refused before anything is sent.
public struct SignalProcessTerminator: ProcessTerminating {
    /// Sends `signal` to `pid`; returns 0 on success or the `errno` value.
    typealias SignalSender = @Sendable (_ pid: Int32, _ signal: Int32) -> Int32
    /// Asks an app to quit; returns true when the request was delivered, false/nil to fall back to signals.
    typealias AppTerminator = @Sendable (_ pid: Int32, _ mode: TerminationMode) -> Bool

    private static let logger = Logger(subsystem: "com.macappupdater", category: "ProcessTerminator")
    private let sendSignal: SignalSender
    private let terminateApp: AppTerminator
    private let currentPID: Int32

    public init() {
        self.init(sendSignal: Self.systemKill, terminateApp: Self.runningApplicationTerminate, currentPID: getpid())
    }

    init(sendSignal: @escaping SignalSender, terminateApp: @escaping AppTerminator, currentPID: Int32) {
        self.sendSignal = sendSignal
        self.terminateApp = terminateApp
        self.currentPID = currentPID
    }

    public func terminate(_ process: ProcessSnapshot, mode: TerminationMode) async throws(TerminationError) {
        if let reason = refusalReason(for: process) {
            Self.logger.notice("Refusing to terminate \(process.name, privacy: .public) (\(process.pid)): \(reason, privacy: .public)")
            throw .protectedProcess(process.name)
        }
        if process.bundleURL != nil, terminateApp(process.pid, mode) { return }
        let result = sendSignal(process.pid, mode == .force ? SIGKILL : SIGTERM)
        if let error = Self.error(fromErrno: result) { throw error }
    }

    // MARK: - Rules

    /// Why a process may not be terminated, or nil when it may.
    func refusalReason(for process: ProcessSnapshot) -> String? {
        if process.kind == .critical { return "critical process" }
        if process.pid <= 1 { return "kernel or launchd" }
        if process.pid == currentPID { return "current process" }
        return nil
    }

    /// Maps `kill` errno to the contract's errors; nil for success.
    static func error(fromErrno code: Int32) -> TerminationError? {
        switch code {
        case 0: nil
        case EPERM: .notPermitted
        case ESRCH: .noSuchProcess
        default: .failed(code)
        }
    }

    // MARK: - Live implementations

    private static let systemKill: SignalSender = { pid, signal in
        kill(pid, signal) == 0 ? 0 : errno
    }

    private static let runningApplicationTerminate: AppTerminator = { pid, mode in
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return mode == .force ? app.forceTerminate() : app.terminate()
    }
}
