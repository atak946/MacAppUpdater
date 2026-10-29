import Foundation
import Testing
@testable import MaintenanceCore

@Suite("Security output parsing")
struct SecurityParserTests {
    @Test("FileVault states", arguments: [
        ("FileVault is On.\n", SecurityCheckStatus.on),
        ("FileVault is Off.\n", .off),
        ("Encryption in progress: Percent completed = 42\n", .on),
        ("Decryption in progress: Percent completed = 10\n", .off),
        ("", .unknown),
    ])
    func fileVault(output: String, expected: SecurityCheckStatus) {
        #expect(SecurityOutputParser.fileVault(output) == expected)
    }

    @Test("firewall global state", arguments: [
        ("Firewall is enabled. (State = 1)", SecurityCheckStatus.on),
        ("Firewall is blocking all non-essential incoming connections. (State = 2)", .on),
        ("Firewall is disabled. (State = 0)", .off),
        ("Firewall is enabled.", .on),
        ("garbage", .unknown),
    ])
    func firewall(output: String, expected: SecurityCheckStatus) {
        #expect(SecurityOutputParser.firewall(output) == expected)
    }

    @Test("stealth mode, current and legacy wording")
    func stealth() {
        #expect(SecurityOutputParser.stealthMode("Firewall stealth mode is on") == .on)
        #expect(SecurityOutputParser.stealthMode("Firewall stealth mode is off") == .off)
        #expect(SecurityOutputParser.stealthMode("Stealth mode enabled") == .on)
        #expect(SecurityOutputParser.stealthMode("") == .unknown)
    }

    @Test("SIP, Gatekeeper")
    func sipAndGatekeeper() {
        #expect(SecurityOutputParser.systemIntegrityProtection("System Integrity Protection status: enabled.") == .on)
        #expect(SecurityOutputParser.systemIntegrityProtection("System Integrity Protection status: disabled.") == .off)
        #expect(SecurityOutputParser.systemIntegrityProtection(
            "System Integrity Protection status: unknown (Custom Configuration)."
        ) == .off)
        #expect(SecurityOutputParser.systemIntegrityProtection("csrutil: error") == .unknown)
        #expect(SecurityOutputParser.gatekeeper("assessments enabled\n") == .on)
        #expect(SecurityOutputParser.gatekeeper("assessments disabled\n") == .off)
        #expect(SecurityOutputParser.gatekeeper("") == .unknown)
    }

    @Test("screen lock delay")
    func screenLock() {
        let log = "2026-10-29 15:33:21.403 sysadminctl[39939:17343487] "
        #expect(SecurityOutputParser.screenLock(log + "screenLock delay is immediate") == (.on, 0))
        #expect(SecurityOutputParser.screenLock(log + "screenLock delay is 300 seconds") == (.on, 300))
        #expect(SecurityOutputParser.screenLock(log + "screenLock is off") == (.off, nil))
        #expect(SecurityOutputParser.screenLock("") == (.unknown, nil))
    }

    @Test("remote login via launchctl")
    func remoteLogin() {
        let missing = "Bad request.\nCould not find service \"com.openssh.sshd\" in domain for system"
        #expect(SecurityOutputParser.remoteLogin(exitStatus: 113, output: missing) == .off)
        #expect(SecurityOutputParser.remoteLogin(exitStatus: 0, output: "system/com.openssh.sshd = {\n state = waiting") == .on)
        #expect(SecurityOutputParser.remoteLogin(exitStatus: 1, output: "Operation not permitted") == .unknown)
    }

    @Test("automatic updates use macOS defaults for missing keys")
    func automaticUpdates() {
        #expect(SecurityOutputParser.automaticUpdates(nil) == .unknown)
        #expect(SecurityOutputParser.automaticUpdates([:]) == .on)
        #expect(SecurityOutputParser.automaticUpdates(["AutomaticDownload": 1]) == .on)
        #expect(SecurityOutputParser.automaticUpdates(["AutomaticCheckEnabled": false]) == .off)
        #expect(SecurityOutputParser.automaticUpdates(["CriticalUpdateInstall": 0]) == .off)
        #expect(SecurityOutputParser.installsMacOSUpdates(["AutomaticallyInstallMacOSUpdates": true]) == true)
        #expect(SecurityOutputParser.installsMacOSUpdates([:]) == nil)
    }

    @Test("XProtect freshness")
    func xprotect() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        #expect(SecurityOutputParser.xprotect(updatedAt: now.addingTimeInterval(-86_400), now: now) == .on)
        #expect(SecurityOutputParser.xprotect(updatedAt: now.addingTimeInterval(-90 * 86_400), now: now) == .off)
        #expect(SecurityOutputParser.xprotect(updatedAt: nil, now: now) == .unknown)
    }
}

@Suite("Security score")
struct SecurityScoreTests {
    @Test("weights add up to 100")
    func weights() {
        #expect(SecurityCheckKind.allCases.reduce(0) { $0 + $1.weight } == 100)
    }

    @Test("all secure scores 100; remote login is secure when off")
    func allSecure() {
        let results = SecurityCheckKind.allCases.map {
            SecurityCheckResult(kind: $0, status: $0.isSafeWhenOff ? .off : .on)
        }
        #expect(SecurityScore.score(for: results) == 100)
        #expect(SecurityReport(results: results, checkedAt: .now).issues.isEmpty)
    }

    @Test("unknown checks are left out of the denominator")
    func unknownIgnored() {
        let results = [
            SecurityCheckResult(kind: .fileVault, status: .on),
            SecurityCheckResult(kind: .gatekeeper, status: .off),
            SecurityCheckResult(kind: .screenLock, status: .unknown),
        ]
        #expect(SecurityScore.score(for: results) == 57) // 20 / 35
        #expect(SecurityScore.score(for: [SecurityCheckResult(kind: .xprotect, status: .unknown)]) == nil)
    }

    @Test("issues are sorted by severity")
    func issues() {
        let report = SecurityReport(results: [
            SecurityCheckResult(kind: .firewallStealth, status: .off),
            SecurityCheckResult(kind: .remoteLogin, status: .on),
            SecurityCheckResult(kind: .fileVault, status: .off),
        ], checkedAt: .now)
        #expect(report.issues.map(\.kind) == [.fileVault, .remoteLogin, .firewallStealth])
    }
}
