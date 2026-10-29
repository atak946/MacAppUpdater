import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("CompatibilityAnalyzer security & vendor warnings")
struct SecurityWarningsAnalyzerTests {
    let analyzer = CompatibilityAnalyzer(currentSystemVersion: "14.5.0")
    static let app = CompatibilityAnalyzerTests.makeApp()

    func kinds(_ input: AppAnalysisInput) -> [AppWarning] {
        analyzer.warnings(for: input)
    }

    @Test("rejected update bundle is critical, installed app is info")
    func notarization() throws {
        let input = AppAnalysisInput(
            app: Self.app, details: nil,
            installedGatekeeperVerdict: .rejected(reason: "no usable signature"),
            updateGatekeeperVerdict: .developerIDNotNotarized
        )
        let warnings = kinds(input)
        #expect(warnings.count == 2)
        let first = try #require(warnings.first)
        #expect(first.severity == .critical)
        guard case .notNotarized(_, .update) = first.kind else { Issue.record("expected update scope"); return }
        #expect(warnings.last?.severity == .info)
        #expect(warnings.last?.explanation.contains("no usable signature") == true)
    }

    @Test("notarized and unknown verdicts raise nothing")
    func quietVerdicts() {
        #expect(analyzer.notarizationWarning(for: .notarized, scope: .update) == nil)
        #expect(analyzer.notarizationWarning(for: .unknown(reason: "spctl missing"), scope: .update) == nil)
        #expect(analyzer.notarizationWarning(for: .rejected(reason: "x"), scope: .update)?.severity == .critical)
    }

    @Test("download host change is informational")
    func hostChange() throws {
        let change = HostChange(bundleIdentifier: Self.app.bundleIdentifier, previous: "github.com", current: "evil.xyz")
        let warning = try #require(kinds(AppAnalysisInput(app: Self.app, details: nil, downloadHostChange: change)).first)
        #expect(warning.kind == .downloadHostChanged(previous: "github.com", current: "evil.xyz"))
        #expect(warning.severity == .info)
        #expect(warning.explanation.contains("evil.xyz"))
        #expect(analyzer.downloadHostWarning(for: change) == warning)
    }

    @Test("vendor-managed apps get an info warning naming the updater")
    func vendor() throws {
        let management = VendorManagement(vendor: .microsoftAutoUpdate, updaterName: "Microsoft AutoUpdate",
                                           openTarget: .application(URL(fileURLWithPath: "/tmp/MAU.app")))
        let warning = try #require(kinds(AppAnalysisInput(app: Self.app, details: nil, vendorManagement: management)).first)
        #expect(warning.kind == .managedByVendor(updaterName: "Microsoft AutoUpdate"))
        #expect(warning.severity == .info)
        #expect(warning.title == "Managed by Microsoft AutoUpdate")
        #expect(!warning.symbolName.isEmpty)
    }
}
