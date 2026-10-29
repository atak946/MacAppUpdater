import Foundation
import Testing
@testable import AppUpdaterCore

@MainActor
@Suite("UpdateScheduler")
struct UpdateSchedulerTests {
    @Test func defaultsToSixHoursWithTenPercentTolerance() {
        let scheduler = UpdateScheduler {}
        #expect(scheduler.identifier == "com.macappupdater.check")
        #expect(scheduler.interval == 6 * 60 * 60)
        #expect(scheduler.tolerance == 6 * 60 * 6)
        #expect(!scheduler.isRunning)
    }

    @Test func honoursCustomIntervalAndTolerance() {
        let scheduler = UpdateScheduler(identifier: "test.custom", interval: 3600, tolerance: 120) {}
        #expect(scheduler.interval == 3600)
        #expect(scheduler.tolerance == 120)
    }

    @Test func clampsTinyIntervals() {
        let scheduler = UpdateScheduler(interval: 1) {}
        #expect(scheduler.interval == 60)
    }

    @Test func startAndStopToggleRunningState() {
        let scheduler = UpdateScheduler(identifier: "test.startstop", interval: 3600) {}
        scheduler.start()
        #expect(scheduler.isRunning)
        scheduler.start() // idempotent
        #expect(scheduler.isRunning)
        scheduler.stop()
        #expect(!scheduler.isRunning)
        scheduler.stop() // idempotent
        #expect(!scheduler.isRunning)
    }

    @Test func updatingIntervalPreservesRunningState() {
        let scheduler = UpdateScheduler(identifier: "test.update", interval: 3600) {}
        scheduler.start()
        scheduler.updateInterval(7200)
        #expect(scheduler.isRunning)
        #expect(scheduler.interval == 7200)
        #expect(scheduler.tolerance == 720)
        scheduler.stop()

        scheduler.updateInterval(1800)
        #expect(!scheduler.isRunning)
        #expect(scheduler.interval == 1800)
    }
}

@Suite("UpdateNotifier")
struct UpdateNotifierTests {
    private func update(_ name: String) -> AvailableUpdate {
        let app = InstalledApp(
            bundleIdentifier: "com.example.\(name)",
            name: name,
            url: URL(fileURLWithPath: "/Applications/\(name).app"),
            shortVersion: "1.0",
            buildVersion: nil,
            sparkleFeedURL: nil,
            isFromAppStore: false
        )
        return AvailableUpdate(
            app: app,
            newVersion: "2.0",
            downloadURL: URL(string: "https://example.com/\(name).zip")!,
            source: .sparkle
        )
    }

    @Test func titlePluralises() {
        #expect(UpdateNotifier.title(forCount: 1) == "1 update available")
        #expect(UpdateNotifier.title(forCount: 4) == "4 updates available")
    }

    @Test func bodyTruncatesLongLists() {
        let updates = ["A", "B", "C", "D", "E"].map(update)
        #expect(UpdateNotifier.body(for: updates) == "A, B, C and 2 more")
        #expect(UpdateNotifier.body(for: Array(updates.prefix(2))) == "A, B")
    }
}
