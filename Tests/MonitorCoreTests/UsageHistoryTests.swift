import Darwin
import Foundation
import Testing
@testable import MonitorCore

private let base = Date(timeIntervalSince1970: 1_700_000_000)

private func app(_ id: String, cpu: Double, memory: UInt64 = 0) -> AppUsageSample {
    AppUsageSample(id: id, name: id.capitalized, bundlePath: "/Applications/\(id).app", cpuPercent: cpu, memoryBytes: memory)
}

/// Contiguous one-minute entries starting at `base`; `apps(i)` supplies minute `i`.
private func minutes(_ count: Int, startingAt offset: Int = 0, apps: (Int) -> [AppUsageSample]) -> [UsageMinute] {
    (0..<count).map { index in
        UsageMinute(timestamp: base.addingTimeInterval(TimeInterval((offset + index + 1) * 60)), seconds: 60, apps: apps(index))
    }
}

@Suite("Usage history buffer")
struct UsageHistoryBufferTests {
    @Test("keeps the newest entries in order once full")
    func ringBuffer() {
        var buffer = UsageHistoryBuffer(capacity: 3)
        minutes(5) { [app("a", cpu: Double($0))] }.forEach { buffer.append($0) }
        #expect(buffer.count == 3)
        #expect(buffer.entries.map { $0.apps[0].cpuPercent } == [2, 3, 4])
        #expect(buffer.latest?.apps[0].cpuPercent == 4)
    }

    @Test("init keeps only the newest entries")
    func initTrims() {
        let buffer = UsageHistoryBuffer(capacity: 2, entries: minutes(4) { [app("a", cpu: Double($0))] })
        #expect(buffer.entries.map { $0.apps[0].cpuPercent } == [2, 3])
    }
}

@Suite("Usage history aggregation")
struct UsageHistoryAggregatorTests {
    @Test("averages CPU over the whole window, counting absent minutes as zero")
    func topApps() {
        // 60 minutes: "a" at 30% throughout, "b" at 120% for 10 minutes only.
        let history = minutes(60) { index in
            [app("a", cpu: 30, memory: 100)] + (index < 10 ? [app("b", cpu: 120, memory: UInt64(index) * 10)] : [])
        }
        let now = base.addingTimeInterval(60 * 60)
        let top = UsageHistoryAggregator.topApps(history, window: 3600, now: now)
        #expect(top.map(\.id) == ["a", "b"])
        #expect(abs(top[0].averageCPUPercent - 30) < 0.001)
        #expect(abs(top[1].averageCPUPercent - 20) < 0.001)
        #expect(top[1].peakMemoryBytes == 90)
        #expect(top[0].peakMemoryBytes == 100)
    }

    @Test("window excludes older minutes and respects the limit")
    func window() {
        let history = minutes(120) { index in index < 60 ? [app("old", cpu: 90)] : [app("new", cpu: 10)] }
        let now = base.addingTimeInterval(120 * 60)
        #expect(UsageHistoryAggregator.topApps(history, window: 3600, now: now).map(\.id) == ["new"])
        #expect(UsageHistoryAggregator.topApps(history, window: 6 * 3600, now: now).map(\.id) == ["old", "new"])
        #expect(UsageHistoryAggregator.topApps(history, window: 6 * 3600, now: now, limit: 1).count == 1)
        #expect(UsageHistoryAggregator.topApps([], window: 3600, now: now).isEmpty)
    }

    @Test("an app above the threshold for ten minutes is a sustained hog")
    func hog() throws {
        let history = minutes(30) { index in [app("busy", cpu: (5..<17).contains(index) ? 80 : 5), app("calm", cpu: 20)] }
        let now = base.addingTimeInterval(30 * 60)
        let hogs = UsageHistoryAggregator.sustainedHogs(history, window: 3600, now: now)
        let hog = try #require(hogs.first)
        #expect(hogs.count == 1)
        #expect(hog.id == "busy")
        #expect(hog.duration == 600)
        #expect(hog.averageCPUPercent > 50)
        // The newest 10-minute stretch still above 50%: minutes 10...19 (seven busy, three calm).
        #expect(hog.endedAt == history[19].timestamp)
    }

    @Test("a nine-minute burst that doesn't lift the ten-minute average is not enough")
    func tooShort() {
        // 9 × 55% + 1 × 0% averages 49.5% over any ten minutes.
        let history = minutes(30) { index in [app("busy", cpu: (5..<14).contains(index) ? 55 : 0)] }
        let now = base.addingTimeInterval(30 * 60)
        #expect(UsageHistoryAggregator.sustainedHogs(history, window: 3600, now: now).isEmpty)
    }

    @Test("average just above the threshold counts, at or below does not")
    func threshold() {
        let now = base.addingTimeInterval(10 * 60)
        let above = minutes(10) { _ in [app("a", cpu: 50.5)] }
        let equal = minutes(10) { _ in [app("a", cpu: 50)] }
        #expect(UsageHistoryAggregator.sustainedHogs(above, window: 3600, now: now).map(\.id) == ["a"])
        #expect(UsageHistoryAggregator.sustainedHogs(equal, window: 3600, now: now).isEmpty)
    }

    @Test("a sleep gap breaks the stretch")
    func gap() {
        // Two five-minute busy runs separated by an hour asleep.
        let history = minutes(5) { _ in [app("a", cpu: 100)] } + minutes(5, startingAt: 65) { _ in [app("a", cpu: 100)] }
        let now = base.addingTimeInterval(80 * 60)
        #expect(UsageHistoryAggregator.sustainedHogs(history, window: 3600 * 6, now: now).isEmpty)
        #expect(UsageHistoryAggregator.sustainedHogs(history, window: 3600 * 6, now: now, minimumDuration: 300).map(\.id) == ["a"])
    }

    @Test("hogs outside the window are ignored")
    func hogWindow() {
        let history = minutes(20) { _ in [app("a", cpu: 100)] } + minutes(60, startingAt: 20) { _ in [] }
        let now = base.addingTimeInterval(80 * 60)
        #expect(UsageHistoryAggregator.sustainedHogs(history, window: 3600, now: now).isEmpty)
        #expect(UsageHistoryAggregator.sustainedHogs(history, window: 6 * 3600, now: now).map(\.id) == ["a"])
    }
}

@Suite("Usage history store")
struct UsageHistoryStoreTests {
    @Test("round-trips through the compact format")
    func roundTrip() throws {
        let history = minutes(3) { index in [app("a", cpu: 12.34, memory: 5 * 1024 * 1024), app("b", cpu: Double(index))] }
        let decoded = try UsageHistoryStore.decode(UsageHistoryStore.encode(history))
        #expect(decoded.count == 3)
        #expect(decoded[0].timestamp == history[0].timestamp)
        #expect(decoded[0].seconds == 60)
        #expect(decoded[2].apps.map(\.id) == ["a", "b"])
        #expect(decoded[0].apps[0].cpuPercent == 12.3)
        #expect(decoded[0].apps[0].memoryBytes == 5 * 1024 * 1024)
        #expect(decoded[0].apps[0].bundlePath == "/Applications/a.app")
    }

    @Test("saves, loads and moves a corrupt file aside")
    func fileIO() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UsageHistoryStore(fileURL: dir.appendingPathComponent("UsageHistory.json"))
        #expect(store.load().isEmpty)
        try store.save(minutes(2) { _ in [app("a", cpu: 1)] })
        #expect(store.load().count == 2)

        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.load().isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.appendingPathExtension("corrupt").path))
    }
}

@Suite("Process usage recorder")
struct ProcessUsageRecorderTests {
    private let fooMain = "/Applications/Foo.app/Contents/MacOS/Foo"
    private let fooHelper = "/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper"

    @Test("groups helpers under their app, merges repeated tools and keeps the busiest")
    func topApps() {
        let groups = ProcessGrouper.group([
            makeProcess(pid: 10, name: "Foo", path: fooMain, bundleID: "com.foo", cpu: 10, memory: 1),
            makeProcess(pid: 11, name: "Foo Helper", path: fooHelper, bundleID: "com.foo", cpu: 30, memory: 2),
            makeProcess(pid: 20, name: "node", path: "/usr/local/bin/node", cpu: 15, memory: 4),
            makeProcess(pid: 21, name: "node", path: "/usr/local/bin/node", cpu: 15, memory: 4),
            makeProcess(pid: 30, name: "idle", path: "/usr/bin/idle", cpu: 0),
            makeProcess(pid: 40, name: "small", path: "/usr/bin/small", cpu: 1),
        ])
        let top = LiveProcessUsageRecorder.topApps(groups, limit: 2) { pid in pid == 11 ? 100 : nil }
        #expect(top.map(\.id) == ["com.foo", "exe:/usr/local/bin/node"])
        #expect(top[0].cpuPercent == 40)
        #expect(top[0].memoryBytes == 101)
        #expect(top[0].bundlePath == "/Applications/Foo.app")
        #expect(top[1].cpuPercent == 30)
        #expect(top[1].memoryBytes == 8)
    }

    @Test("first call only sets the baseline; the next reports the top apps")
    func live() async throws {
        let recorder = LiveProcessUsageRecorder()
        #expect(await recorder.record(now: Date()) == nil)
        // Burn a little CPU so at least this process shows up.
        let deadline = Date().addingTimeInterval(0.2)
        var spin = 0.0
        while Date() < deadline { spin += sin(spin) }
        let minute = try #require(await recorder.record(now: Date()))
        #expect(spin.isFinite)
        #expect(!minute.apps.isEmpty)
        #expect(minute.apps.count <= 10)
        #expect(minute.seconds > 0)
        #expect(minute.apps.allSatisfy { $0.cpuPercent > 0 })
    }
}
