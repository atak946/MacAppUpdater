import Foundation

// Low-frequency history of the heaviest apps, for the System page's "Last 24 hours" card.

/// One app's usage over one recording interval.
public struct AppUsageSample: Sendable, Hashable {
    /// Stable across relaunches: the `ProcessGroup` id for apps, the executable path for standalone tools.
    public let id: String
    public let name: String
    /// Enclosing `.app` bundle path, for the icon; nil for standalone tools.
    public let bundlePath: String?
    /// Average percent of one core over the interval (can exceed 100).
    public let cpuPercent: Double
    /// Physical footprint of all members at the end of the interval.
    public let memoryBytes: UInt64

    public init(id: String, name: String, bundlePath: String?, cpuPercent: Double, memoryBytes: UInt64) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// The top apps of one recording interval, which ends at `timestamp` and lasted `seconds` of awake time.
public struct UsageMinute: Sendable, Hashable {
    public let timestamp: Date
    public let seconds: Double
    /// Sorted by CPU, highest first.
    public let apps: [AppUsageSample]

    public init(timestamp: Date, seconds: Double, apps: [AppUsageSample]) {
        self.timestamp = timestamp
        self.seconds = seconds
        self.apps = apps
    }

    /// Wall-clock start of the interval.
    public var start: Date { timestamp.addingTimeInterval(-seconds) }
}

/// Fixed-capacity ring buffer of usage minutes; the oldest entry is overwritten once full.
public struct UsageHistoryBuffer: Sendable, Hashable {
    /// 24 hours of one-minute entries.
    public static let defaultCapacity = 1440

    public let capacity: Int
    private var storage: [UsageMinute] = []
    /// Index of the oldest entry once `storage` is full.
    private var head = 0

    public init(capacity: Int = UsageHistoryBuffer.defaultCapacity, entries: [UsageMinute] = []) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(min(self.capacity, max(entries.count, 64)))
        entries.suffix(self.capacity).forEach { append($0) }
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var latest: UsageMinute? {
        guard !storage.isEmpty else { return nil }
        return storage[(head + storage.count - 1) % storage.count]
    }

    /// Oldest first.
    public var entries: [UsageMinute] {
        Array(storage[head...] + storage[..<head])
    }

    public mutating func append(_ entry: UsageMinute) {
        if storage.count < capacity {
            storage.append(entry)
        } else {
            storage[head] = entry
            head = (head + 1) % capacity
        }
    }
}

/// Time span of the history card.
public enum UsageWindow: Int, CaseIterable, Sendable, Hashable, Identifiable {
    case hour = 1
    case sixHours = 6
    case day = 24

    public var id: Int { rawValue }
    public var duration: TimeInterval { TimeInterval(rawValue) * 3600 }
}

/// One app's usage across a window.
public struct AppUsageSummary: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let bundlePath: String?
    /// Time-weighted average percent of one core over the recorded part of the window.
    public let averageCPUPercent: Double
    public let peakMemoryBytes: UInt64

    public init(id: String, name: String, bundlePath: String?, averageCPUPercent: Double, peakMemoryBytes: UInt64) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.averageCPUPercent = averageCPUPercent
        self.peakMemoryBytes = peakMemoryBytes
    }
}

/// An app that averaged above the threshold for an uninterrupted stretch of at least the minimum duration.
public struct SustainedHog: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let bundlePath: String?
    /// Average percent of one core over the qualifying stretch.
    public let averageCPUPercent: Double
    /// Length of the qualifying stretch.
    public let duration: TimeInterval
    /// End of the most recent qualifying stretch.
    public let endedAt: Date

    public init(id: String, name: String, bundlePath: String?, averageCPUPercent: Double, duration: TimeInterval, endedAt: Date) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.averageCPUPercent = averageCPUPercent
        self.duration = duration
        self.endedAt = endedAt
    }
}

public protocol ProcessUsageRecording: Sendable {
    /// Top apps by CPU since the previous call. Nil on the first call (no baseline yet) and after a
    /// gap much longer than the recording interval, which only re-baselines.
    func record(now: Date) async -> UsageMinute?
}
