import AppKit
import MonitorCore
import Observation
import os

/// Records the heaviest apps once a minute, independently of the monitor pages, and keeps 24 hours
/// of them for the System page's "Last 24 hours" card. Persists to disk at most every few minutes.
@MainActor
@Observable
final class UsageHistoryModel {
    /// UserDefaults key; recording is on unless this is set to false.
    static let enabledDefaultsKey = "monitorUsageHistoryEnabled"
    private static let notifiedDefaultsKey = "monitorUsageHistoryNotified"

    private(set) var history: UsageHistoryBuffer
    /// Bumped on every change; summaries are cached per revision.
    private(set) var revision = 0

    private let recorder: any ProcessUsageRecording
    private let store: UsageHistoryStore?
    private let notifier: (any SustainedUsageNotifying)?
    private let defaults: UserDefaults
    private let interval: Duration
    private let saveInterval: TimeInterval
    private let logger = Logger(subsystem: "com.macappupdater", category: "UsageHistory")
    /// Serial, so a periodic save still in flight can't land after the final one at quit.
    private let saveQueue = DispatchQueue(label: "com.macappupdater.usage-history.save", qos: .utility)

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastSave: Date = .distantPast
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var topCache: [UsageWindow: (revision: Int, apps: [AppUsageSummary])] = [:]
    @ObservationIgnored private var hogCache: [UsageWindow: (revision: Int, hogs: [SustainedHog])] = [:]
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]

    init(
        recorder: any ProcessUsageRecording,
        store: UsageHistoryStore?,
        notifier: (any SustainedUsageNotifying)? = nil,
        defaults: UserDefaults = .standard,
        interval: Duration = .seconds(60),
        saveInterval: TimeInterval = 5 * 60,
        capacity: Int = UsageHistoryBuffer.defaultCapacity
    ) {
        self.recorder = recorder
        self.store = store
        self.notifier = notifier
        self.defaults = defaults
        self.interval = interval
        self.saveInterval = saveInterval
        self.history = UsageHistoryBuffer(capacity: capacity)
    }

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    // MARK: Lifecycle

    var isRecording: Bool { loop != nil }

    /// Loads the stored history, then records once per `interval` at utility priority.
    func start() {
        guard loop == nil else { return }
        let store = store
        loop = Task(priority: .utility) { [weak self, interval] in
            let stored = await Task.detached(priority: .utility) { store?.load() ?? [] }.value
            self?.restore(stored)
            while !Task.isCancelled {
                guard let self else { return }
                await self.recordOnce()
                // Generous tolerance lets macOS coalesce the wake-up with other timers.
                try? await Task.sleep(for: interval, tolerance: interval / 6)
            }
        }
    }

    /// Stops recording and writes unsaved history synchronously (called at quit).
    func stop() {
        loop?.cancel()
        loop = nil
        guard isDirty, let store else { return }
        isDirty = false
        let entries = history.entries
        let logger = logger
        saveQueue.sync { Self.save(entries, to: store, logger: logger) }
    }

    private func restore(_ stored: [UsageMinute]) {
        guard !stored.isEmpty else { return }
        let merged = (stored + history.entries).sorted { $0.timestamp < $1.timestamp }
        history = UsageHistoryBuffer(capacity: history.capacity, entries: merged)
        revision += 1
    }

    // MARK: Recording

    /// One tick: records a minute, warns about new sustained hogs and saves when due.
    func recordOnce(now: Date = Date()) async {
        guard let minute = await recorder.record(now: now) else { return }
        history.append(minute)
        revision += 1
        isDirty = true
        await notifyNewHogs(now: now)
        saveIfDue(now: now)
    }

    private func saveIfDue(now: Date) {
        guard let store, isDirty, now.timeIntervalSince(lastSave) >= saveInterval else { return }
        lastSave = now
        isDirty = false
        let entries = history.entries
        let logger = logger
        saveQueue.async { Self.save(entries, to: store, logger: logger) }
    }

    private nonisolated static func save(_ entries: [UsageMinute], to store: UsageHistoryStore, logger: Logger) {
        do {
            try store.save(entries)
        } catch {
            logger.error("Saving usage history failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Derived

    func topApps(_ window: UsageWindow, limit: Int = 5) -> [AppUsageSummary] {
        if let cached = topCache[window], cached.revision == revision { return cached.apps }
        let apps = UsageHistoryAggregator.topApps(history.entries, window: window.duration, now: Date(), limit: limit)
        topCache[window] = (revision, apps)
        return apps
    }

    func sustainedHogs(_ window: UsageWindow) -> [SustainedHog] {
        if let cached = hogCache[window], cached.revision == revision { return cached.hogs }
        let hogs = UsageHistoryAggregator.sustainedHogs(history.entries, window: window.duration, now: Date())
        hogCache[window] = (revision, hogs)
        return hogs
    }

    /// App icon for a bundle path, cached.
    func icon(forBundlePath path: String?) -> NSImage? {
        guard let path else { return nil }
        if let cached = iconCache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = image
        return image
    }

    // MARK: Notifications

    /// Posts once per app per day for a hog whose stretch ends with the minute just recorded.
    private func notifyNewHogs(now: Date) async {
        guard let notifier, let latest = history.latest else { return }
        // Only the trailing stretch matters here; a short suffix keeps this cheap.
        let window = UsageHistoryAggregator.defaultHogDuration + 5 * 60
        let suffix = history.entries.suffix(Int(window / 30))
        let fresh = UsageHistoryAggregator.sustainedHogs(Array(suffix), window: window, now: now)
            .filter { $0.endedAt == latest.timestamp }
        guard !fresh.isEmpty else { return }

        var notified = (defaults.dictionary(forKey: Self.notifiedDefaultsKey) as? [String: Double] ?? [:])
            .filter { now.timeIntervalSince1970 - $0.value < 86_400 }
        for hog in fresh where notified[hog.id] == nil {
            notified[hog.id] = now.timeIntervalSince1970
            await notifier.notifySustainedUsage(hog)
        }
        defaults.set(notified, forKey: Self.notifiedDefaultsKey)
    }
}
