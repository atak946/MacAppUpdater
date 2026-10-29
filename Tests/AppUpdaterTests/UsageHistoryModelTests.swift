import Foundation
import MonitorCore
import Testing
@testable import AppUpdater

/// Reports one minute per call with `app` at a fixed CPU; nil on the first call, like the live recorder.
private actor ScriptedRecorder: ProcessUsageRecording {
    let cpu: Double
    private var calls = 0

    init(cpu: Double) { self.cpu = cpu }

    func record(now: Date) async -> UsageMinute? {
        calls += 1
        guard calls > 1 else { return nil }
        let app = AppUsageSample(id: "com.busy", name: "Busy", bundlePath: nil, cpuPercent: cpu, memoryBytes: 1024)
        return UsageMinute(timestamp: now, seconds: 60, apps: [app])
    }
}

private actor CollectingNotifier: SustainedUsageNotifying {
    private(set) var posted: [String] = []
    func notifySustainedUsage(_ hog: SustainedHog) async { posted.append(hog.id) }
}

@MainActor
@Suite("Usage history model")
struct UsageHistoryModelTests {
    private let defaults: UserDefaults = {
        let suite = "UsageHistoryModelTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }()

    private func makeStore() -> UsageHistoryStore {
        UsageHistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("UsageHistory.json"))
    }

    @Test("records minutes and summarizes them")
    func records() async {
        let model = UsageHistoryModel(recorder: ScriptedRecorder(cpu: 20), store: nil, defaults: defaults)
        let start = Date().addingTimeInterval(-30 * 60)
        for minute in 0..<4 { await model.recordOnce(now: start.addingTimeInterval(TimeInterval(minute * 60))) }
        #expect(model.history.count == 3)
        #expect(model.topApps(.hour).map(\.id) == ["com.busy"])
        #expect(model.sustainedHogs(.hour).isEmpty)
    }

    @Test("notifies once per app per day for a sustained hog")
    func notifiesOnce() async {
        let notifier = CollectingNotifier()
        let model = UsageHistoryModel(recorder: ScriptedRecorder(cpu: 90), store: nil, notifier: notifier, defaults: defaults)
        let start = Date().addingTimeInterval(-30 * 60)
        for minute in 0..<15 { await model.recordOnce(now: start.addingTimeInterval(TimeInterval(minute * 60))) }
        #expect(await notifier.posted == ["com.busy"])
        #expect(model.sustainedHogs(.hour).map(\.id) == ["com.busy"])
    }

    @Test("stop writes the minutes not saved yet")
    func persists() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let model = UsageHistoryModel(recorder: ScriptedRecorder(cpu: 5), store: store, defaults: defaults, saveInterval: 3600)
        let start = Date().addingTimeInterval(-30 * 60)
        for minute in 0..<3 { await model.recordOnce(now: start.addingTimeInterval(TimeInterval(minute * 60))) }
        model.stop()
        #expect(store.load().count == 2)
    }

    @Test("recording defaults on and can be turned off")
    func enabledFlag() {
        #expect(UsageHistoryModel.isEnabled(in: defaults))
        defaults.set(false, forKey: UsageHistoryModel.enabledDefaultsKey)
        #expect(!UsageHistoryModel.isEnabled(in: defaults))
    }
}
