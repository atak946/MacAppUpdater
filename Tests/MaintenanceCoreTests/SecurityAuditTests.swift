import Foundation
import SQLite3
import Testing
@testable import MaintenanceCore

/// Replies with canned output per executable + first argument.
private struct FakeRunner: SecurityCommandRunning {
    let replies: [String: SecurityCommandOutput]

    func run(_ executable: String, arguments: [String]) async -> SecurityCommandOutput? {
        replies[executable + " " + (arguments.first ?? "")]
    }
}

private struct FakeLocator: AppLocating {
    var installed: [String: URL] = [:]
    var lastUsed: [URL: Date] = [:]

    func applicationURL(forBundleIdentifier identifier: String) -> URL? { installed[identifier] }
    func lastUsedDate(of url: URL) -> Date? { lastUsed[url] }
}

@Suite("Security checker and permission audit")
struct SecurityAuditTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "SecurityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("checker combines tool output and preference files")
    func checker() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefs = dir.appending(path: "su.plist")
        try PropertyListSerialization.data(fromPropertyList: ["AutomaticCheckEnabled": false], format: .xml, options: 0)
            .write(to: prefs)
        let ok = { (text: String) in SecurityCommandOutput(status: 0, text: text) }
        let runner = FakeRunner(replies: [
            "/usr/bin/fdesetup status": ok("FileVault is On."),
            "/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate": ok("Firewall is disabled. (State = 0)"),
            "/usr/bin/csrutil status": ok("System Integrity Protection status: enabled."),
            "/usr/sbin/spctl --status": ok("assessments enabled"),
            "/bin/launchctl print": SecurityCommandOutput(status: 113, text: "Could not find service"),
        ])
        let checker = SystemSecurityChecker(
            runner: runner,
            paths: .init(softwareUpdatePreferences: prefs, xprotectBundles: [dir.appending(path: "missing.bundle")]),
            now: { [now] in now }
        )

        let report = await checker.runChecks()
        let status = Dictionary(uniqueKeysWithValues: report.results.map { ($0.kind, $0.status) })

        #expect(report.results.map(\.kind) == SecurityCheckKind.allCases)
        #expect(status[.fileVault] == .on)
        #expect(status[.firewall] == .off)
        #expect(status[.firewallStealth] == .unknown)
        #expect(status[.remoteLogin] == .off)
        #expect(status[.automaticUpdates] == .off)
        #expect(status[.xprotect] == .unknown)
        #expect(report.checkedAt == now)
    }

    @Test("unreadable user database asks for Full Disk Access")
    func needsAccess() async {
        let auditor = TCCPermissionAuditor(
            userDatabase: URL(fileURLWithPath: "/nonexistent/TCC.db"),
            systemDatabase: URL(fileURLWithPath: "/nonexistent/TCC2.db"),
            locator: FakeLocator()
        )
        #expect(await auditor.audit() == .needsFullDiskAccess)
    }

    @Test("reads a TCC database, merges Automation rows and flags stale apps")
    func readsDatabase() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appending(path: "TCC.db")
        try makeDatabase(at: db, rows: [
            ("kTCCServiceCamera", "com.example.Zoom", 0, 2, 1_900_000_000),
            ("kTCCServiceMicrophone", "com.example.Gone", 0, 2, 1_800_000_000),
            ("kTCCServiceAppleEvents", "com.example.Script", 0, 0, 1_700_000_000),
            ("kTCCServiceAppleEvents", "com.example.Script", 0, 2, 1_750_000_000),
            ("kTCCServiceCamera", "com.example.Denied", 0, 0, 1_700_000_000),
            ("kTCCServiceUbiquity", "com.example.Zoom", 0, 2, 1_700_000_000),
        ])
        let zoom = URL(fileURLWithPath: "/Applications/Zoom.app")
        let script = URL(fileURLWithPath: "/Applications/Script.app")
        let denied = URL(fileURLWithPath: "/Applications/Denied.app")
        let locator = FakeLocator(
            installed: ["com.example.Zoom": zoom, "com.example.Script": script, "com.example.Denied": denied],
            lastUsed: [zoom: now.addingTimeInterval(-86_400), script: now.addingTimeInterval(-200 * 86_400)]
        )
        let auditor = TCCPermissionAuditor(
            userDatabase: db, systemDatabase: dir.appending(path: "none.db"), locator: locator, now: { [now] in now }
        )

        guard case .entries(let entries) = await auditor.audit() else {
            Issue.record("expected entries")
            return
        }
        let byClient = Dictionary(grouping: entries, by: \.client)

        #expect(entries.count == 4) // Ubiquity is not audited; Automation rows merged.
        #expect(byClient["com.example.Zoom"]?.first?.flags == [])
        #expect(byClient["com.example.Gone"]?.first?.flags == [.notInstalled])
        #expect(byClient["com.example.Gone"]?.first?.appName == "com.example.Gone")
        let automation = try #require(byClient["com.example.Script"]?.first)
        #expect(automation.isAllowed)
        #expect(automation.flags == [.unused])
        #expect(automation.lastModified == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(byClient["com.example.Denied"]?.first?.flags == [])
    }

    @Test("flag rules")
    func flagRules() {
        let old = now.addingTimeInterval(-91 * 86_400)
        #expect(PermissionFlagger.flags(isAllowed: false, isInstalled: false, lastUsed: nil, now: now) == [])
        #expect(PermissionFlagger.flags(isAllowed: true, isInstalled: false, lastUsed: nil, now: now) == [.notInstalled])
        #expect(PermissionFlagger.flags(isAllowed: true, isInstalled: true, lastUsed: old, now: now) == [.unused])
        #expect(PermissionFlagger.flags(isAllowed: true, isInstalled: true, lastUsed: nil, now: now) == [])
    }

    // MARK: Fixture

    private func makeDatabase(at url: URL, rows: [(String, String, Int, Int, Int)]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        var sql = """
        CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL, \
        auth_value INTEGER NOT NULL, auth_reason INTEGER, last_modified INTEGER);
        """
        for row in rows {
            sql += "INSERT INTO access VALUES ('\(row.0)', '\(row.1)', \(row.2), \(row.3), 2, \(row.4));"
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
}
