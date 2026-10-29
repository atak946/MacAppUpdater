import AppKit
import os

/// Quits running instances of an app before its bundle is replaced.
public protocol RunningAppTerminating: Sendable {
    /// Asks every running instance to quit and waits for them to exit.
    /// Throws if instances are still running after the timeout.
    func terminateRunningInstances(of bundleIdentifier: String) async throws

    /// Same as `terminateRunningInstances(of:)` but reports whether any instance was running,
    /// so the caller can relaunch the app afterwards.
    func quitRunningInstances(of bundleIdentifier: String) async throws -> Bool
}

extension RunningAppTerminating {
    /// Default for conformers that predate relaunch support: never triggers a relaunch.
    public func quitRunningInstances(of bundleIdentifier: String) async throws -> Bool {
        try await terminateRunningInstances(of: bundleIdentifier)
        return false
    }
}

public struct RunningAppTerminator: RunningAppTerminating {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "Terminator")
    private static let pollInterval: Duration = .milliseconds(250)

    private let timeout: Duration

    public init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    public func terminateRunningInstances(of bundleIdentifier: String) async throws {
        _ = try await quitRunningInstances(of: bundleIdentifier)
    }

    public func quitRunningInstances(of bundleIdentifier: String) async throws -> Bool {
        let requested = await Self.requestTermination(of: bundleIdentifier)
        guard requested > 0 else { return false }
        Self.logger.info("Asked \(requested) instance(s) of \(bundleIdentifier, privacy: .public) to quit")

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await Self.runningCount(of: bundleIdentifier) == 0 { return true }
            try await Task.sleep(for: Self.pollInterval)
        }
        guard await Self.runningCount(of: bundleIdentifier) == 0 else {
            throw UpdaterError.installFailed("\(bundleIdentifier) did not quit within \(timeout)")
        }
        return true
    }

    @MainActor
    private static func requestTermination(of bundleIdentifier: String) -> Int {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        apps.forEach { _ = $0.terminate() }
        return apps.count
    }

    @MainActor
    private static func runningCount(of bundleIdentifier: String) -> Int {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
            .count
    }
}
