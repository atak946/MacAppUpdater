import Foundation

/// Pure summaries of recorded usage minutes. An app missing from a minute (below the top N) counts as 0 CPU.
public enum UsageHistoryAggregator {
    /// 50% of one core.
    public static let defaultHogThreshold: Double = 50
    public static let defaultHogDuration: TimeInterval = 10 * 60
    /// Slack between one interval's end and the next one's start before the stretch counts as interrupted.
    static let contiguityTolerance: TimeInterval = 30

    /// Apps by time-weighted average CPU (desc), then peak memory (desc), over minutes ending in `(now - window, now]`.
    public static func topApps(_ minutes: [UsageMinute], window: TimeInterval, now: Date, limit: Int = 5) -> [AppUsageSummary] {
        let recent = inWindow(minutes, window: window, now: now)
        let totalSeconds = recent.reduce(0) { $0 + $1.seconds }
        guard totalSeconds > 0 else { return [] }

        var cpuSeconds: [String: Double] = [:]
        var peaks: [String: UInt64] = [:]
        var latest: [String: AppUsageSample] = [:]
        for minute in recent {
            for app in minute.apps {
                cpuSeconds[app.id, default: 0] += app.cpuPercent * minute.seconds
                peaks[app.id] = max(peaks[app.id] ?? 0, app.memoryBytes)
                latest[app.id] = app
            }
        }
        let summaries = latest.values.map { app in
            AppUsageSummary(id: app.id, name: app.name, bundlePath: app.bundlePath,
                            averageCPUPercent: (cpuSeconds[app.id] ?? 0) / totalSeconds,
                            peakMemoryBytes: peaks[app.id] ?? 0)
        }
        return Array(summaries.sorted(by: ordersBefore).prefix(max(0, limit)))
    }

    /// Apps whose average CPU exceeded `threshold` over an uninterrupted stretch of at least `minimumDuration`
    /// inside the window, highest average first. Each app is reported once, for its most recent stretch.
    public static func sustainedHogs(_ minutes: [UsageMinute], window: TimeInterval, now: Date,
                                     threshold: Double = defaultHogThreshold,
                                     minimumDuration: TimeInterval = defaultHogDuration) -> [SustainedHog] {
        let recent = inWindow(minutes, window: window, now: now)
        guard !recent.isEmpty, minimumDuration > 0 else { return [] }
        let contiguous = contiguityFlags(recent)
        let cpuByMinute = recent.map { Dictionary($0.apps.map { ($0.id, $0.cpuPercent) }, uniquingKeysWith: +) }

        var latest: [String: AppUsageSample] = [:]
        recent.forEach { minute in minute.apps.forEach { latest[$0.id] = $0 } }

        let hogs = latest.values.compactMap { app -> SustainedHog? in
            guard let stretch = latestStretch(of: app.id, in: recent, cpu: cpuByMinute, contiguous: contiguous,
                                              threshold: threshold, minimumDuration: minimumDuration) else { return nil }
            return SustainedHog(id: app.id, name: app.name, bundlePath: app.bundlePath,
                                averageCPUPercent: stretch.average, duration: stretch.duration, endedAt: stretch.end)
        }
        return hogs.sorted {
            $0.averageCPUPercent != $1.averageCPUPercent ? $0.averageCPUPercent > $1.averageCPUPercent : $0.id < $1.id
        }
    }

    // MARK: - Helpers

    /// Minutes ending in `(now - window, now]`, oldest first.
    static func inWindow(_ minutes: [UsageMinute], window: TimeInterval, now: Date) -> [UsageMinute] {
        let cutoff = now.addingTimeInterval(-window)
        return minutes.filter { $0.timestamp > cutoff && $0.timestamp <= now && $0.seconds > 0 }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// `flags[i]` is true when minute `i` starts where minute `i - 1` ended (no sleep or relaunch in between).
    static func contiguityFlags(_ minutes: [UsageMinute]) -> [Bool] {
        minutes.indices.map { index in
            guard index > 0 else { return false }
            return abs(minutes[index].start.timeIntervalSince(minutes[index - 1].timestamp)) <= contiguityTolerance
        }
    }

    /// The newest stretch, walking back from each end minute until `minimumDuration` is covered.
    private static func latestStretch(of id: String, in minutes: [UsageMinute], cpu: [[String: Double]], contiguous: [Bool],
                                      threshold: Double, minimumDuration: TimeInterval)
        -> (average: Double, duration: TimeInterval, end: Date)? {
        for end in minutes.indices.reversed() where (cpu[end][id] ?? 0) > 0 {
            var seconds = 0.0
            var cpuSeconds = 0.0
            var index = end
            while true {
                seconds += minutes[index].seconds
                cpuSeconds += (cpu[index][id] ?? 0) * minutes[index].seconds
                if seconds >= minimumDuration || index == 0 || !contiguous[index] { break }
                index -= 1
            }
            guard seconds >= minimumDuration else { continue }
            let average = cpuSeconds / seconds
            if average > threshold { return (average, seconds, minutes[end].timestamp) }
        }
        return nil
    }

    private static func ordersBefore(_ lhs: AppUsageSummary, _ rhs: AppUsageSummary) -> Bool {
        if lhs.averageCPUPercent != rhs.averageCPUPercent { return lhs.averageCPUPercent > rhs.averageCPUPercent }
        if lhs.peakMemoryBytes != rhs.peakMemoryBytes { return lhs.peakMemoryBytes > rhs.peakMemoryBytes }
        if lhs.name != rhs.name { return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
        return lhs.id < rhs.id
    }
}
