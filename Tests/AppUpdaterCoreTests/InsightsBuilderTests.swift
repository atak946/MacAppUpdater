import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("InsightsBuilder")
struct InsightsBuilderTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func insight(
        _ name: String,
        size: Int64? = 100,
        daysUnused: Double? = nil,
        intel: Bool = false,
        warnings: [AppWarning.Kind] = []
    ) -> AppInsight {
        let app = InstalledApp(
            bundleIdentifier: "com.example.\(name.lowercased())", name: name,
            url: URL(fileURLWithPath: "/Applications/\(name).app"),
            shortVersion: "1.0", buildVersion: nil, sparkleFeedURL: nil, isFromAppStore: false
        )
        return AppInsight(
            app: app, sizeInBytes: size,
            lastUsedDate: daysUnused.map { Self.now.addingTimeInterval(-$0 * 86_400) },
            isIntelOnly: intel, warnings: warnings.map(AppWarning.init)
        )
    }

    @Test("Totals count every app and sum known sizes")
    func totals() {
        let report = InsightsBuilder().build(from: [insight("A", size: 10), insight("B", size: nil), insight("C", size: 5)], now: Self.now)
        #expect(report.totalApps == 3)
        #expect(report.totalSizeInBytes == 15)
    }

    @Test("Largest apps are capped at 10 and sorted descending")
    func largest() {
        let apps = (1...15).map { insight("App\($0)", size: Int64($0) * 100) }
        let report = InsightsBuilder().build(from: apps, now: Self.now)
        #expect(report.largestApps.count == 10)
        #expect(report.largestApps.first?.app.name == "App15")
        #expect(report.largestApps.last?.app.name == "App6")
    }

    @Test("Unused apps exceed 90 days, oldest first; unknown dates excluded")
    func unused() {
        let apps = [insight("Recent", daysUnused: 5), insight("Old", daysUnused: 100),
                    insight("Ancient", daysUnused: 500), insight("Unknown")]
        let report = InsightsBuilder().build(from: apps, now: Self.now)
        #expect(report.unusedApps.map(\.app.name) == ["Ancient", "Old"])
    }

    @Test("Intel-only apps are listed by name")
    func intelOnly() {
        let report = InsightsBuilder().build(
            from: [insight("Zed", intel: true), insight("Arm"), insight("Alpha", intel: true)], now: Self.now)
        #expect(report.intelOnlyApps.map(\.app.name) == ["Alpha", "Zed"])
    }

    @Test("Warnings are grouped by severity, critical first, empty groups dropped")
    func groups() {
        let apps = [
            insight("B", warnings: [.intelOnly, .signatureInvalid(reason: "x")]),
            insight("A", warnings: [.unsigned]),
        ]
        let report = InsightsBuilder().build(from: apps, now: Self.now)
        #expect(report.warningGroups.map(\.severity) == [.critical, .warning])
        #expect(report.warningGroups.last?.entries.map(\.app.name) == ["A", "B"])
        #expect(report.totalWarnings == 3)
        #expect(report.warnings(for: "com.example.b").count == 2)
    }

    @Test("Empty input yields an empty report")
    func empty() {
        let report = InsightsBuilder().build(from: [], now: Self.now)
        #expect(report.totalApps == 0 && report.warningGroups.isEmpty && report.largestApps.isEmpty)
    }
}
