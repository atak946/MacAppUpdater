import AppKit
import Foundation
import IOKit.ps
import Network
import os

/// Network characteristics relevant to unattended downloads.
public struct NetworkStatus: Sendable, Equatable, Hashable {
    public let isSatisfied: Bool
    /// Cellular / personal hotspot (`NWPath.isExpensive`).
    public let isExpensive: Bool
    /// Low Data Mode (`NWPath.isConstrained`).
    public let isConstrained: Bool

    public init(isSatisfied: Bool = true, isExpensive: Bool = false, isConstrained: Bool = false) {
        self.isSatisfied = isSatisfied
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

/// A point-in-time view of the system used by `AutoInstallPlanner`.
public struct SystemConditionsSnapshot: Sendable, Equatable {
    public let isOnACPower: Bool
    /// `nil` when the network state could not be determined in time.
    public let network: NetworkStatus?
    public let runningBundleIdentifiers: Set<String>
    public let now: Date
    public let calendar: Calendar

    public init(
        isOnACPower: Bool = true,
        network: NetworkStatus? = NetworkStatus(),
        runningBundleIdentifiers: Set<String> = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        self.isOnACPower = isOnACPower
        self.network = network
        self.runningBundleIdentifiers = runningBundleIdentifiers
        self.now = now
        self.calendar = calendar
    }
}

public protocol SystemConditionsProvider: Sendable {
    func snapshot() async -> SystemConditionsSnapshot
}

/// Reads power (IOKit), network (NWPathMonitor) and running apps (NSWorkspace).
public struct LiveSystemConditionsProvider: SystemConditionsProvider {
    private let networkTimeout: Duration
    private let now: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar
    private static let logger = Logger(subsystem: "com.macappupdater", category: "SystemConditions")

    public init(
        networkTimeout: Duration = .seconds(2),
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: @escaping @Sendable () -> Calendar = { .current }
    ) {
        self.networkTimeout = networkTimeout
        self.now = now
        self.calendar = calendar
    }

    public func snapshot() async -> SystemConditionsSnapshot {
        async let network = Self.currentNetwork(timeout: networkTimeout)
        let running = await Self.runningBundleIdentifiers()
        return SystemConditionsSnapshot(
            isOnACPower: Self.isOnACPower(),
            network: await network,
            runningBundleIdentifiers: running,
            now: now(),
            calendar: calendar()
        )
    }

    /// Desktop Macs without a battery report "AC Power" (or no sources at all) and count as AC.
    static func isOnACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return true }
        let source = type as String
        return source != kIOPMBatteryPowerKey && source != kIOPMUPSPowerKey
    }

    @MainActor
    static func runningBundleIdentifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.compactMap(\.bundleIdentifier))
    }

    /// One-shot read of the current path; `nil` if the monitor does not answer within `timeout`.
    static func currentNetwork(timeout: Duration) async -> NetworkStatus? {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.macappupdater.conditions.network")
        let finished = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<NetworkStatus?, Never>) in
            let finish: @Sendable (NetworkStatus?) -> Void = { status in
                let isFirst = finished.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                guard isFirst else { return }
                if status == nil { logger.warning("Network status timed out") }
                monitor.cancel()
                continuation.resume(returning: status)
            }
            monitor.pathUpdateHandler = { path in
                finish(NetworkStatus(
                    isSatisfied: path.status == .satisfied,
                    isExpensive: path.isExpensive,
                    isConstrained: path.isConstrained
                ))
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout.timeInterval) { finish(nil) }
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
