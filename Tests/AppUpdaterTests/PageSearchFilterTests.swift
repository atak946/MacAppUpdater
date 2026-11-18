import AppUpdaterCore
import Foundation
import MaintenanceCore
import Testing
@testable import AppUpdater

@Suite("Page search filters")
struct PageSearchFilterTests {
    private static func insight(_ id: String, warnings: [AppWarning] = []) -> AppInsight {
        AppInsight(app: Fixtures.app(id), sizeInBytes: 1, lastUsedDate: nil, isIntelOnly: true, warnings: warnings)
    }

    @Test("insights keep library totals but narrow every list to matching apps")
    func insightsFiltered() {
        let apps = [Self.insight("slack"), Self.insight("zoom")]
        let report = InsightsReport(
            generatedAt: .now, apps: apps, totalApps: 2, totalSizeInBytes: 2,
            largestApps: apps, unusedApps: apps, intelOnlyApps: apps, warningGroups: []
        )

        let filtered = report.filtered(by: SearchQuery("zoo"))

        #expect(filtered.apps.map(\.app.bundleIdentifier) == ["zoom"])
        #expect(filtered.largestApps.count == 1 && filtered.unusedApps.count == 1 && filtered.intelOnlyApps.count == 1)
        #expect(filtered.totalApps == 2)
        #expect(report.filtered(by: SearchQuery("")) == report)
    }

    @Test("formula filters split pinned and upgradable formulae")
    func formulaFilters() {
        let pinned = OutdatedFormula(name: "node", installedVersions: ["20"], currentVersion: "22", pinned: true)
        let free = OutdatedFormula(name: "git", installedVersions: ["2.40"], currentVersion: "2.41", pinned: false)
        #expect([pinned, free].filter(FormulaFilter.pinned.includes) == [pinned])
        #expect([pinned, free].filter(FormulaFilter.upgradable.includes) == [free])
        #expect([pinned, free].filter(FormulaFilter.all.includes).count == 2)
    }

    @Test("cleanup search keeps matching items, or the whole group when its category matches")
    func cleanupGroups() {
        let item = { (name: String, owner: String?) in
            CleanupItem(
                url: URL(fileURLWithPath: "/Users/me/Library/Caches/\(name)"), category: .userCaches,
                displayName: name, sizeInBytes: 10, ownerBundleIdentifier: owner
            )
        }
        let caches = CleanupGroup(category: .userCaches, items: [item("Slack", "com.tinyspeck.slack"), item("Zoom", nil)])
        let logs = CleanupGroup(category: .logs, items: [item("system.log", nil)])
        let report = CleanupScanReport(groups: [caches, logs], scannedAt: .now)

        let bySlack = CleanupView.groups(of: report, matching: SearchQuery("tinyspeck"))
        #expect(bySlack.map(\.category) == [.userCaches])
        #expect(bySlack.first?.items.map(\.displayName) == ["Slack"])

        let byCategory = CleanupView.groups(of: report, matching: SearchQuery(CleanupCategory.logs.title))
        #expect(byCategory.first { $0.category == .logs }?.items.count == 1)

        #expect(CleanupView.groups(of: report, matching: SearchQuery("nothing-here")).isEmpty)
        #expect(CleanupView.groups(of: report, matching: SearchQuery("")) == report.groups)
    }
}

@Suite("History filters")
struct HistoryFilterTests {
    private static func entry(_ outcome: UpdateHistoryEntry.Outcome, daysAgo: Int = 0) -> UpdateHistoryEntry {
        UpdateHistoryEntry(
            bundleID: "a", appName: "A", fromVersion: "1", toVersion: "2", source: .sparkle,
            date: Date(timeIntervalSince1970: 1_000_000_000).addingTimeInterval(-Double(daysAgo) * 86_400),
            outcome: outcome
        )
    }

    @Test("outcome filters match their outcome only")
    func outcomes() {
        let entries = [Self.entry(.succeeded), Self.entry(.failed(message: "x")), Self.entry(.rolledBack)]
        #expect(entries.filter(HistoryOutcomeFilter.all.includes).count == 3)
        #expect(entries.filter(HistoryOutcomeFilter.failed.includes).map(\.outcome) == [.failed(message: "x")])
        #expect(entries.filter(HistoryOutcomeFilter.rolledBack.includes).map(\.outcome) == [.rolledBack])
    }

    @Test("periods cut off older events")
    func periods() throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        #expect(HistoryPeriod.allTime.cutoff(from: now) == nil)
        let week = try #require(HistoryPeriod.lastWeek.cutoff(from: now))
        #expect(Self.entry(.succeeded, daysAgo: 3).date >= week)
        #expect(Self.entry(.succeeded, daysAgo: 10).date < week)
    }
}
