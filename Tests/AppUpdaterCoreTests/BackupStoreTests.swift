import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("BackupStore")
struct BackupStoreTests {
    private static let bundleID = "com.example.backup-test"
    private static let day: TimeInterval = 86_400

    private let root = makeInstallTempDirectory("BackupStoreTests")
    private var backupsDirectory: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    private var installedURL: URL { root.appendingPathComponent("Applications/Foo.app") }

    private func makeStore(
        retention: BackupRetentionPolicy = .default,
        clock: BackupTestClock = BackupTestClock(),
        verifier: PathTeamVerifier = PathTeamVerifier(team: "TEAM123"),
        terminator: RecordingTerminator = RecordingTerminator(),
        relauncher: RecordingRelauncher = RecordingRelauncher(),
        relaunch: Bool = true,
        gatekeeper: any GatekeeperAssessing = FixedGatekeeperAssessor(.notarized),
        policy: NotarizationPolicy = .require
    ) -> BackupStore {
        BackupStore(
            baseDirectory: backupsDirectory, retention: retention,
            signatureVerifier: verifier, terminator: terminator,
            relauncher: relauncher, relaunchAfterRestore: relaunch,
            gatekeeperAssessor: gatekeeper, notarizationPolicy: policy, now: { clock.now }
        )
    }

    private func installApp(version: String) throws -> InstalledApp {
        try? FileManager.default.removeItem(at: installedURL)
        try FakeAppBundle.make(at: installedURL, bundleID: Self.bundleID, version: version)
        return FakeAppBundle.installedApp(at: installedURL, bundleID: Self.bundleID, version: version)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    @Test("copies the bundle to <base>/<bundleID>/<version>/<Name>.app")
    func backUpCopiesBundle() async throws {
        defer { cleanUp() }
        let store = makeStore()
        let app = try installApp(version: "1.0")

        let backup = try await store.backUp(app)

        let expected = backupsDirectory.appendingPathComponent("\(Self.bundleID)/1.0/Foo.app")
        #expect(backup.bundleURL.path == expected.path)
        #expect(try FakeAppBundle.version(of: backup.bundleURL) == "1.0")
        let listed = try await store.backups(for: Self.bundleID)
        #expect(listed == [backup])
        #expect(FileManager.default.fileExists(atPath: installedURL.path))
    }

    @Test("keeps only the latest backup per app by default")
    func keepsLatestOnly() async throws {
        defer { cleanUp() }
        let clock = BackupTestClock()
        let store = makeStore(clock: clock)

        try await store.backUp(try installApp(version: "1.0"))
        clock.advance(by: 60)
        let newest = try await store.backUp(try installApp(version: "1.1"))

        #expect(try await store.backups(for: Self.bundleID) == [newest])
    }

    @Test("pruneAll deletes backups older than maxAge and removes empty app folders")
    func prunesExpired() async throws {
        defer { cleanUp() }
        let clock = BackupTestClock()
        let store = makeStore(retention: BackupRetentionPolicy(maxBackupsPerApp: 5, maxAge: 14 * Self.day), clock: clock)
        try await store.backUp(try installApp(version: "1.0"))
        clock.advance(by: 10 * Self.day)
        let recent = try await store.backUp(try installApp(version: "1.1"))

        clock.advance(by: 5 * Self.day)
        try await store.pruneAll()
        #expect(try await store.backups(for: Self.bundleID) == [recent])

        clock.advance(by: 20 * Self.day)
        try await store.pruneAll()
        #expect(try await store.backups(for: Self.bundleID).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: backupsDirectory.appendingPathComponent(Self.bundleID).path))
    }

    @Test("restore swaps the backup in, relaunches a running app and consumes the backup")
    func restoreReplacesApp() async throws {
        defer { cleanUp() }
        let terminator = RecordingTerminator(wasRunning: true)
        let relauncher = RecordingRelauncher()
        let store = makeStore(terminator: terminator, relauncher: relauncher)
        let backup = try await store.backUp(try installApp(version: "1.0"))
        let updated = try installApp(version: "2.0")

        try await store.restore(backup, over: updated)

        #expect(try FakeAppBundle.version(of: installedURL) == "1.0")
        #expect(terminator.terminatedBundleIDs == [Self.bundleID])
        #expect(relauncher.relaunchedURLs == [installedURL])
        #expect(try await store.backups(for: Self.bundleID).isEmpty)
    }

    @Test("restore does not relaunch when disabled or when the app was not running")
    func restoreWithoutRelaunch() async throws {
        defer { cleanUp() }
        let relauncher = RecordingRelauncher()
        let store = makeStore(terminator: RecordingTerminator(wasRunning: true), relauncher: relauncher, relaunch: false)
        let backup = try await store.backUp(try installApp(version: "1.0"))

        try await store.restore(backup, over: try installApp(version: "2.0"))

        #expect(relauncher.relaunchedURLs.isEmpty)
    }

    @Test("restore rejects a backup signed by a different team and keeps the installed app")
    func restoreTeamMismatch() async throws {
        defer { cleanUp() }
        let verifier = PathTeamVerifier(team: "TEAM123", untrustedPrefixes: [backupsDirectory.path])
        let terminator = RecordingTerminator()
        let store = makeStore(verifier: verifier, terminator: terminator)
        let backup = try await store.backUp(try installApp(version: "1.0"))
        let updated = try installApp(version: "2.0")

        await #expect(throws: UpdaterError.teamIdentifierMismatch(expected: "TEAM123", actual: "EVIL999")) {
            try await store.restore(backup, over: updated)
        }
        #expect(try FakeAppBundle.version(of: installedURL) == "2.0")
        #expect(terminator.terminatedBundleIDs.isEmpty)
    }

    @Test("restore rejects a backup of another app")
    func restoreWrongBundle() async throws {
        defer { cleanUp() }
        let store = makeStore()
        let backup = try await store.backUp(try installApp(version: "1.0"))
        let other = FakeAppBundle.installedApp(at: installedURL, bundleID: "com.example.other", version: "2.0")

        await #expect(throws: UpdaterError.self) {
            try await store.restore(backup, over: other)
        }
    }

    @Test("delete refuses paths outside the backup directory")
    func deleteOutsideBaseThrows() async throws {
        defer { cleanUp() }
        let store = makeStore()
        _ = try installApp(version: "1.0")
        let forged = AppBackup(
            bundleIdentifier: Self.bundleID, appName: "Foo", version: "1.0",
            createdAt: Date(), bundleURL: installedURL
        )

        await #expect(throws: UpdaterError.self) {
            try await store.delete(forged)
        }
        #expect(FileManager.default.fileExists(atPath: installedURL.path))
    }

    @Test("delete removes the backup")
    func deleteRemovesBackup() async throws {
        defer { cleanUp() }
        let store = makeStore()
        let backup = try await store.backUp(try installApp(version: "1.0"))

        try await store.delete(backup)

        #expect(try await store.backups(for: Self.bundleID).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: backup.bundleURL.path))
    }

    @Test("sanitises untrusted path components", arguments: [
        ("../evil", "_.._evil"), ("1.0/2", "1.0_2"), ("", "_"), ("a:b", "a_b"), ("2.1", "2.1"),
    ])
    func safeComponent(input: String, expected: String) {
        #expect(BackupStore.safeComponent(input) == expected)
    }
}
