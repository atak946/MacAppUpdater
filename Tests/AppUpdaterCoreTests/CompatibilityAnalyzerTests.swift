import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("CompatibilityAnalyzer")
struct CompatibilityAnalyzerTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    let analyzer = CompatibilityAnalyzer(currentSystemVersion: "14.5.0")

    static func makeApp() -> InstalledApp {
        InstalledApp(
            bundleIdentifier: "com.example.demo", name: "Demo",
            url: URL(fileURLWithPath: "/Applications/Demo.app"),
            shortVersion: "1.0", buildVersion: nil, sparkleFeedURL: nil, isFromAppStore: false
        )
    }

    static func makeDetails(
        architectures: [String] = ["Apple Silicon", "Intel"],
        minimumSystem: String? = "12.0",
        signature: AppDetails.Signature = .signed(teamIdentifier: "TEAM1")
    ) -> AppDetails {
        AppDetails(
            sizeInBytes: 1_000, modifiedAt: nil, minimumSystemVersion: minimumSystem,
            copyright: nil, category: nil, executableArchitectures: architectures, signature: signature
        )
    }

    static func makeUpdate(minimumSystem: String?) -> AvailableUpdate {
        AvailableUpdate(
            app: makeApp(), newVersion: "2.0",
            downloadURL: URL(string: "https://example.com/demo.zip")!,
            source: .sparkle, minimumSystemVersion: minimumSystem
        )
    }

    static func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let input: AppAnalysisInput
        let expected: AppWarning.Kind?
        let severity: WarningSeverity?
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "clean app", input: input(), expected: nil, severity: nil),
        Case(name: "intel only", input: input(details: makeDetails(architectures: ["Intel"])),
             expected: .intelOnly, severity: .warning),
        Case(name: "universal is fine", input: input(details: makeDetails(architectures: ["arm64", "x86_64"])),
             expected: nil, severity: nil),
        Case(name: "update needs newer macOS", input: input(update: makeUpdate(minimumSystem: "15.0")),
             expected: .updateRequiresNewerMacOS(required: "15.0"), severity: .critical),
        Case(name: "update needs same macOS", input: input(update: makeUpdate(minimumSystem: "14.5")),
             expected: nil, severity: nil),
        Case(name: "app needs newer macOS", input: input(details: makeDetails(minimumSystem: "14.6")),
             expected: .appRequiresNewerMacOS(required: "14.6"), severity: .warning),
        Case(name: "unsigned",
             input: input(details: makeDetails(signature: .unsigned(reason: "Bundle has no team identifier (ad-hoc or unsigned)"))),
             expected: .unsigned, severity: .warning),
        Case(name: "invalid signature",
             input: input(details: makeDetails(signature: .unsigned(reason: "A sealed resource is missing or invalid"))),
             expected: .signatureInvalid(reason: "A sealed resource is missing or invalid"), severity: .critical),
        Case(name: "team changed", input: input(previousTeam: "OLDTEAM"),
             expected: .teamIdentifierChanged(old: "OLDTEAM", new: "TEAM1"), severity: .critical),
        Case(name: "team unchanged", input: input(previousTeam: "TEAM1"), expected: nil, severity: nil),
        Case(name: "unused 120 days", input: input(lastUsed: daysAgo(120)),
             expected: .notOpenedInLongTime(days: 120), severity: .info),
        Case(name: "used recently", input: input(lastUsed: daysAgo(10)), expected: nil, severity: nil),
    ]

    static func input(
        details: AppDetails = makeDetails(),
        update: AvailableUpdate? = nil,
        lastUsed: Date? = nil,
        previousTeam: String? = nil
    ) -> AppAnalysisInput {
        AppAnalysisInput(
            app: makeApp(), details: details, update: update,
            lastUsedDate: lastUsed, previousTeamIdentifier: previousTeam
        )
    }

    @Test("Produces the expected single warning", arguments: cases)
    func producesExpectedWarning(_ testCase: Case) {
        let warnings = analyzer.warnings(for: testCase.input, now: Self.now)
        if let expected = testCase.expected {
            #expect(warnings.map(\.kind) == [expected])
            #expect(warnings.first?.severity == testCase.severity)
            #expect(warnings.first.map { !$0.title.isEmpty && !$0.suggestedAction.isEmpty } == true)
        } else {
            #expect(warnings.isEmpty)
        }
    }

    @Test("Multiple warnings are sorted most severe first")
    func sortsBySeverity() {
        let input = Self.input(
            details: Self.makeDetails(architectures: ["Intel"]),
            update: Self.makeUpdate(minimumSystem: "26.0"),
            lastUsed: Self.daysAgo(400)
        )
        let severities = analyzer.warnings(for: input, now: Self.now).map(\.severity)
        #expect(severities == [.critical, .warning, .info])
    }

    @Test("Missing details produce no architecture or signature warnings")
    func missingDetails() {
        let input = AppAnalysisInput(app: Self.makeApp(), details: nil)
        #expect(analyzer.warnings(for: input, now: Self.now).isEmpty)
    }

    @Test("Update compatibility check for install gating", arguments: [
        ("15.0", true), ("14.5", false), ("13", false), ("14.10", true), ("", false),
    ])
    func updateGate(required: String, blocked: Bool) {
        let warning = analyzer.updateCompatibilityWarning(for: Self.makeUpdate(minimumSystem: required))
        #expect((warning != nil) == blocked)
    }

    @Test("Unknown architectures are not flagged as Intel-only")
    func emptyArchitectures() {
        #expect(CompatibilityAnalyzer.isIntelOnly([]) == false)
    }
}
