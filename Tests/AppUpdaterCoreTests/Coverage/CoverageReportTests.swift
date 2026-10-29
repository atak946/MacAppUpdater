import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("CoverageReport")
struct CoverageReportTests {
    typealias F = CoverageFixtures

    static let results: [UpdateCheckResult] = [
        F.result(F.app("com.a.sparkle", name: "Zeta"), source: .sparkle),
        F.result(F.app("com.a.sparkle2", name: "Alpha"), source: .sparkle),
        F.result(F.app("com.a.brew", name: "Brew"), source: .homebrew),
        F.result(F.app("com.a.mas", name: "Store", appStore: true), source: .appStore),
        F.result(F.app("com.a.none", name: "Nobody"), source: nil),
        F.result(F.app("com.a.ignored", name: "Ignored"), source: nil),
        F.result(F.app("com.a.failed", name: "Broken"), source: nil, errors: ["github: timeout"]),
        F.result(F.app("com.a.partial", name: "Partial"), source: .homebrew, errors: ["sparkle: 404"]),
    ]

    @Test("groups tracked apps by source in a stable order, sorted by name")
    func groupsBySource() {
        let report = CoverageReport(results: Self.results)
        #expect(report.bySource.map(\.source) == [.sparkle, .homebrew, .appStore])
        #expect(report.bySource[0].apps.map(\.name) == ["Alpha", "Zeta"])
        #expect(report.trackedCount == 5)
        #expect(report.totalApps == 8)
    }

    @Test("untracked excludes failed checks and ignored apps")
    func untracked() {
        let report = CoverageReport(results: Self.results, ignoredBundleIdentifiers: ["com.a.ignored"])
        #expect(report.untracked.map(\.bundleIdentifier) == ["com.a.none"])
        #expect(report.ignoredCount == 1)
    }

    @Test("failed checks carry errors and any fallback source")
    func failed() {
        let report = CoverageReport(results: Self.results)
        #expect(report.failed.map(\.app.name) == ["Broken", "Partial"])
        #expect(report.failed[0].fallbackSource == nil)
        #expect(report.failed[1].fallbackSource == .homebrew)
        #expect(report.failed[1].errors == ["sparkle: 404"])
    }

    @Test("App Store apps and percentage")
    func percentage() {
        let report = CoverageReport(results: Self.results)
        #expect(report.appStoreApps.map(\.bundleIdentifier) == ["com.a.mas"])
        #expect(report.trackedPercentage == 63)
        #expect(abs(report.trackedFraction - 0.625) < 0.0001)
    }

    @Test("empty input is 0%")
    func empty() {
        let report = CoverageReport(results: [])
        #expect(report.trackedPercentage == 0)
        #expect(report.untracked.isEmpty && report.bySource.isEmpty)
    }

    @Test("Homebrew search URL encodes the query")
    func homebrewSearch() {
        let url = CoverageConstants.homebrewSearchURL(for: "Foo & Bar+")
        #expect(url?.absoluteString == "https://formulae.brew.sh/?search=Foo%20%26%20Bar%2B")
    }
}
