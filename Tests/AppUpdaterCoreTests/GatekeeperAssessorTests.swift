import Foundation
import os
import Testing
@testable import AppUpdaterCore

/// Fixtures captured from `spctl --assess --type execute -vv` on macOS 26.
private enum SpctlFixture {
    static let notarized = """
    /Applications/AltTab.app: accepted
    source=Notarized Developer ID
    origin=Developer ID Application: Louis Pontoise (QXD7GW8FHY)
    """
    static let developerIDOnly = """
    /Applications/Old Tool.app: accepted
    source=Developer ID
    origin=Developer ID Application: Small Dev (ABCDE12345)
    """
    static let unnotarized = """
    /Applications/Old Tool.app: accepted
    source=Unnotarized Developer ID
    origin=Developer ID Application: Small Dev (ABCDE12345)
    """
    static let rejectedUnsigned = """
    /tmp/U.app: rejected
    source=no usable signature
    """
    static let rejectedAdHoc = "/tmp/U.app: rejected\n"
    static let appleSystem = """
    /System/Applications/Calculator.app: accepted
    source=Apple System
    origin=macOS Software Signing
    """
    static let appStore = """
    /Applications/Developer.app: accepted
    source=Mac App Store
    origin=Apple Mac OS Application Signing
    """
    /// A path containing the word "rejected" must not confuse the parser.
    static let trickyPath = """
    /Applications/rejected: accepted.app: accepted
    source=Notarized Developer ID
    """
}

/// Returns canned output per executable; throws `commandFailed` for non-zero statuses.
private final class ScriptedRunner: CommandRunner {
    struct Reply: Sendable {
        let status: Int32
        let output: String
    }

    private let replies: [String: Reply]
    private let calls = OSAllocatedUnfairLock(initialState: [String]())

    init(_ replies: [String: Reply]) {
        self.replies = replies
    }

    var executables: [String] { calls.withLock { $0 } }

    func run(_ executable: String, arguments: [String]) async throws -> String {
        calls.withLock { $0.append(executable) }
        guard let reply = replies[executable] else {
            throw UpdaterError.commandFailed(command: executable, status: -1, output: "not found")
        }
        guard reply.status == 0 else {
            throw UpdaterError.commandFailed(command: executable, status: reply.status, output: reply.output)
        }
        return reply.output
    }
}

@Suite("GatekeeperOutputParser")
struct GatekeeperOutputParserTests {
    @Test("parses spctl fixtures", arguments: [
        (SpctlFixture.notarized, GatekeeperVerdict.notarized),
        (SpctlFixture.developerIDOnly, .developerIDNotNotarized),
        (SpctlFixture.unnotarized, .developerIDNotNotarized),
        (SpctlFixture.rejectedUnsigned, .rejected(reason: "no usable signature")),
        (SpctlFixture.rejectedAdHoc, .rejected(reason: "rejected")),
        (SpctlFixture.appleSystem, .notarized),
        (SpctlFixture.appStore, .notarized),
        (SpctlFixture.trickyPath, .notarized),
    ])
    func parses(output: String, expected: GatekeeperVerdict) {
        #expect(GatekeeperOutputParser.parseAssessment(output) == expected)
    }

    @Test("garbage and empty output are unknown")
    func unknownOutput() {
        #expect(GatekeeperOutputParser.parseAssessment("") == .unknown(reason: "no output"))
        #expect(GatekeeperOutputParser.parseAssessment("spctl: bad option") == .unknown(reason: "spctl: bad option"))
        let odd = "/x.app: accepted\nsource=Something New\n"
        #expect(GatekeeperOutputParser.parseAssessment(odd) == .unknown(reason: "unrecognized source: Something New"))
    }

    @Test("stapler success marker")
    func stapler() {
        #expect(GatekeeperOutputParser.staplerConfirmsTicket("Processing: /a.app\nThe validate action worked!\n"))
        #expect(!GatekeeperOutputParser.staplerConfirmsTicket("U.app does not have a ticket stapled to it."))
    }
}

@Suite("SpctlGatekeeperAssessor")
struct SpctlGatekeeperAssessorTests {
    private static let bundle = URL(fileURLWithPath: "/tmp/Foo.app")
    private static let stapler = "/fake/stapler"

    @Test("rejection exit status 3 is parsed from the error output")
    func rejectionFromFailure() async {
        let runner = ScriptedRunner([SpctlGatekeeperAssessor.spctlPath: .init(status: 3, output: SpctlFixture.rejectedUnsigned)])
        let assessor = SpctlGatekeeperAssessor(commandRunner: runner, staplerPath: Self.stapler)
        #expect(await assessor.assess(Self.bundle) == .rejected(reason: "no usable signature"))
        #expect(runner.executables == [SpctlGatekeeperAssessor.spctlPath])
    }

    @Test("notarized result skips stapler")
    func notarizedSkipsStapler() async {
        let runner = ScriptedRunner([SpctlGatekeeperAssessor.spctlPath: .init(status: 0, output: SpctlFixture.notarized)])
        let assessor = SpctlGatekeeperAssessor(commandRunner: runner, staplerPath: Self.stapler)
        #expect(await assessor.assess(Self.bundle) == .notarized)
        #expect(runner.executables == [SpctlGatekeeperAssessor.spctlPath])
    }

    @Test("a stapled ticket upgrades developer-ID-only to notarized")
    func staplerUpgrades() async {
        let runner = ScriptedRunner([
            SpctlGatekeeperAssessor.spctlPath: .init(status: 0, output: SpctlFixture.developerIDOnly),
            Self.stapler: .init(status: 0, output: "The validate action worked!"),
        ])
        let assessor = SpctlGatekeeperAssessor(commandRunner: runner, staplerPath: Self.stapler)
        #expect(await assessor.assess(Self.bundle) == .notarized)
    }

    @Test("missing ticket or missing stapler keeps the spctl verdict")
    func noTicket() async {
        let replies: [String: ScriptedRunner.Reply] = [
            SpctlGatekeeperAssessor.spctlPath: .init(status: 0, output: SpctlFixture.developerIDOnly),
            Self.stapler: .init(status: 65, output: "does not have a ticket stapled to it."),
        ]
        let withStapler = SpctlGatekeeperAssessor(commandRunner: ScriptedRunner(replies), staplerPath: Self.stapler)
        let withoutStapler = SpctlGatekeeperAssessor(commandRunner: ScriptedRunner(replies), staplerPath: nil)
        #expect(await withStapler.assess(Self.bundle) == .developerIDNotNotarized)
        #expect(await withoutStapler.assess(Self.bundle) == .developerIDNotNotarized)
    }

    @Test("spctl launch failure is unknown")
    func launchFailure() async {
        let assessor = SpctlGatekeeperAssessor(commandRunner: ScriptedRunner([:]), staplerPath: nil)
        #expect(await assessor.assess(Self.bundle) == .unknown(reason: "spctl exited with -1"))
    }

    @Test("real spctl rejects an unsigned bundle")
    func realSpctlRejectsUnsigned() async throws {
        let root = makeInstallTempDirectory("GatekeeperAssessorTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Foo.app")
        try FakeAppBundle.make(at: app, bundleID: "com.example.gk", version: "1.0")

        let verdict = await SpctlGatekeeperAssessor(staplerPath: nil).assess(app)
        guard case .rejected = verdict else {
            Issue.record("Expected rejected, got \(verdict)")
            return
        }
    }
}

@Suite("NotarizationGate")
struct NotarizationGateTests {
    @Test("enforce decision table", arguments: [
        (GatekeeperVerdict.notarized, NotarizationPolicy.require, false),
        (.developerIDNotNotarized, .require, true),
        (.unknown(reason: "u"), .require, true),
        (.developerIDNotNotarized, .warnOnly, false),
        (.unknown(reason: "u"), .warnOnly, false),
    ])
    func enforce(verdict: GatekeeperVerdict, policy: NotarizationPolicy, blocks: Bool) {
        let result = Result { try NotarizationGate.enforce(verdict, policy: policy, bundleIdentifier: "com.x") }
        if blocks {
            #expect(throws: UpdaterError.signatureInvalid(
                "Not notarized: \(NotarizationGate.blockMessage(for: verdict))"
            )) { try result.get() }
        } else {
            #expect(throws: Never.self) { try result.get() }
        }
    }

    @Test("a Gatekeeper rejection (e.g. revoked) blocks under every policy that assesses", arguments: [
        NotarizationPolicy.require, .warnOnly, .off,
    ])
    func rejectedAlwaysBlocks(policy: NotarizationPolicy) {
        let verdict = GatekeeperVerdict.rejected(reason: "CSSMERR_TP_CERT_REVOKED")
        #expect(throws: UpdaterError.signatureInvalid("Rejected by Gatekeeper: \(verdict.summary)")) {
            try NotarizationGate.enforce(verdict, policy: policy, bundleIdentifier: "com.x")
        }
        #expect(!UpdaterError.signatureInvalid("Rejected by Gatekeeper: \(verdict.summary)").isNotarizationBlock)
    }

    @Test("an unknown verdict under require explains how to proceed")
    func unknownMessage() {
        let message = NotarizationGate.blockMessage(for: .unknown(reason: "offline"))
        #expect(message.contains("offline"))
        #expect(message.contains("Settings"))
    }

    @Test("policy closure is re-read on every check")
    func dynamicPolicy() async throws {
        let current = OSAllocatedUnfairLock(initialState: NotarizationPolicy.require)
        let gate = NotarizationGate(assessor: FixedGatekeeperAssessor(.developerIDNotNotarized)) {
            current.withLock { $0 }
        }
        await #expect(throws: UpdaterError.self) { try await gate.check(URL(fileURLWithPath: "/a.app"), bundleIdentifier: "a") }
        current.withLock { $0 = .warnOnly }
        #expect(try await gate.check(URL(fileURLWithPath: "/a.app"), bundleIdentifier: "a") == .developerIDNotNotarized)
        current.withLock { $0 = .off }
        #expect(try await gate.check(URL(fileURLWithPath: "/a.app"), bundleIdentifier: "a") == nil)
    }

    @Test("settings toggle mapping")
    func toggleMapping() {
        #expect(NotarizationPolicy.fromSetting(allowUnnotarized: false) == .require)
        #expect(NotarizationPolicy.fromSetting(allowUnnotarized: true) == .warnOnly)
    }
}

@Suite("UpdaterError+Notarization")
struct NotarizationErrorTests {
    @Test("isNotarizationBlock recognizes only the gate's error")
    func recognizes() {
        #expect(UpdaterError.signatureInvalid("Not notarized: x").isNotarizationBlock)
        #expect(!UpdaterError.signatureInvalid("errSecCSUnsigned").isNotarizationBlock)
        #expect(!UpdaterError.checksumMismatch.isNotarizationBlock)
    }
}
