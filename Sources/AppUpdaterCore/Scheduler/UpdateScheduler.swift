import Foundation
import os

/// Periodically runs update checks using `NSBackgroundActivityScheduler`,
/// which lets the system pick an energy-efficient moment within the tolerance window.
@MainActor
public final class UpdateScheduler {
    public static let defaultIdentifier = "com.macappupdater.check"
    public static let defaultInterval: TimeInterval = 6 * 60 * 60

    public typealias Work = @Sendable () async -> Void

    public let identifier: String
    public private(set) var interval: TimeInterval
    public private(set) var tolerance: TimeInterval
    public var isRunning: Bool { activity != nil }

    private let work: Work
    private var activity: NSBackgroundActivityScheduler?
    private static let logger = Logger(subsystem: "com.macappupdater", category: "Scheduler")

    /// - Parameters:
    ///   - interval: Seconds between checks (default 6h). Clamped to at least 60s.
    ///   - tolerance: Allowed deviation; defaults to 10% of the interval.
    public init(
        identifier: String = UpdateScheduler.defaultIdentifier,
        interval: TimeInterval = UpdateScheduler.defaultInterval,
        tolerance: TimeInterval? = nil,
        work: @escaping Work
    ) {
        let clamped = Self.clamp(interval)
        self.identifier = identifier
        self.interval = clamped
        self.tolerance = tolerance ?? clamped / 10
        self.work = work
    }

    public func start() {
        guard activity == nil else { return }
        let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.repeats = true
        scheduler.interval = interval
        scheduler.tolerance = tolerance
        scheduler.qualityOfService = .utility

        let work = self.work
        scheduler.schedule { completion in
            Task.detached(priority: .utility) {
                await work()
                completion(.finished)
            }
        }
        activity = scheduler
        Self.logger.info("Scheduled update checks every \(self.interval, privacy: .public)s")
    }

    public func stop() {
        guard let activity else { return }
        activity.invalidate()
        self.activity = nil
        Self.logger.info("Stopped scheduled update checks")
    }

    /// Changes the interval; restarts the activity if it was running.
    public func updateInterval(_ newInterval: TimeInterval, tolerance newTolerance: TimeInterval? = nil) {
        let clamped = Self.clamp(newInterval)
        let wasRunning = isRunning
        stop()
        interval = clamped
        tolerance = newTolerance ?? clamped / 10
        if wasRunning { start() }
    }

    private static func clamp(_ interval: TimeInterval) -> TimeInterval {
        max(interval, 60)
    }
}
