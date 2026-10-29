import Foundation
import os
import Testing
@testable import AppUpdaterCore

/// Returns a team id per bundle: `newTeam` for staged bundles, `oldTeam` for the installed one.
private struct StubSignatureVerifier: SignatureVerifying {
    let installedURL: URL
    let oldTeam: String
    let newTeam: String

    func teamIdentifier(of bundleURL: URL) async throws -> String {
        bundleURL.standardizedFileURL == installedURL.standardizedFileURL ? oldTeam : newTeam
    }
}

private struct NoopTerminator: RunningAppTerminating {
    func terminateRunningInstances(of bundleIdentifier: String) async throws {}
}

/// Records which bundles were assessed.
private final class RecordingGatekeeperAssessor: GatekeeperAssessing {
    private let verdict: GatekeeperVerdict
    private let calls = OSAllocatedUnfairLock(initialState: [URL]())

    init(verdict: GatekeeperVerdict) {
        self.verdict = verdict
    }

    var assessedURLs: [URL] { calls.withLock { $0 } }

    func assess(_ bundleURL: URL) async -> GatekeeperVerdict {
        calls.withLock { $0.append(bundleURL) }
        return verdict
    }
}

@Suite("AppInstaller")
struct AppInstallerTests {
    private static let bundleID = "com.example.installer-test"

    private let root: URL
    private let installedURL: URL
    private let packageURL: URL

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppInstallerTests-\(UUID().uuidString)", isDirectory: true)
        installedURL = root.appendingPathComponent("Applications/Foo.app")
        packageURL = root.appendingPathComponent("download/Foo-2.0.zip")

        try Self.makeFakeApp(at: installedURL, version: "1.0")
        let newApp = root.appendingPathComponent("build/Foo.app")
        try Self.makeFakeApp(at: newApp, version: "2.0")
        try FileManager.default.createDirectory(
            at: packageURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try await ProcessCommandRunner().run(
            "/usr/bin/ditto", arguments: ["-c", "-k", "--keepParent", newApp.path, packageURL.path]
        )
    }

    @Test("installs a zip update end-to-end and replaces the bundle")
    func zipInstallReplacesApp() async throws {
        defer { cleanUp() }
        let installer = makeInstaller(oldTeam: "TEAM123", newTeam: "TEAM123")

        try await installer.install(makeUpdate(), from: packageURL)

        #expect(try Self.version(of: installedURL) == "2.0")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: installedURL.deletingLastPathComponent().path)
        #expect(siblings == ["Foo.app"])
    }

    @Test("throws teamIdentifierMismatch and keeps the old bundle")
    func teamMismatchThrows() async throws {
        defer { cleanUp() }
        let installer = makeInstaller(oldTeam: "TEAM123", newTeam: "EVIL999")

        await #expect(throws: UpdaterError.teamIdentifierMismatch(expected: "TEAM123", actual: "EVIL999")) {
            try await installer.install(makeUpdate(), from: packageURL)
        }
        #expect(try Self.version(of: installedURL) == "1.0")
    }

    @Test("rejects App Store updates")
    func appStoreUnsupported() async throws {
        defer { cleanUp() }
        let installer = makeInstaller(oldTeam: "T", newTeam: "T")

        await #expect(throws: UpdaterError.unsupportedFormat("appStore")) {
            try await installer.install(makeUpdate(source: .appStore), from: packageURL)
        }
    }

    @Test("rejects pkg packages")
    func pkgUnsupported() async throws {
        defer { cleanUp() }
        let installer = makeInstaller(oldTeam: "T", newTeam: "T")

        await #expect(throws: UpdaterError.unsupportedFormat("pkg requires privileged helper")) {
            try await installer.install(makeUpdate(), from: root.appendingPathComponent("Foo.pkg"))
        }
    }

    @Test("backs up the old bundle before replacing it")
    func backsUpOldBundle() async throws {
        defer { cleanUp() }
        let store = makeBackupStore()
        let installer = makeInstaller(oldTeam: "TEAM123", newTeam: "TEAM123", backupStore: store)

        try await installer.install(makeUpdate(), from: packageURL)

        let backups = try await store.backups(for: Self.bundleID)
        #expect(backups.map(\.version) == ["1.0"])
        #expect(try backups.first.map { try Self.version(of: $0.bundleURL) } == "1.0")
        #expect(try Self.version(of: installedURL) == "2.0")
    }

    @Test("a failing backup aborts the install before quitting the app")
    func backupFailureAborts() async throws {
        defer { cleanUp() }
        let terminator = RecordingTerminator(wasRunning: true)
        let installer = makeInstaller(
            oldTeam: "T", newTeam: "T", backupStore: FailingBackupStore(), terminator: terminator
        )

        await #expect {
            try await installer.install(makeUpdate(), from: packageURL)
        } throws: { error in
            guard case UpdaterError.installFailed = error else { return false }
            return true
        }
        #expect(try Self.version(of: installedURL) == "1.0")
        #expect(terminator.terminatedBundleIDs.isEmpty)
    }

    @Test("relaunches the app when it was running", arguments: [(true, true), (false, true), (true, false)])
    func relaunchesWhenRunning(wasRunning: Bool, relaunchEnabled: Bool) async throws {
        defer { cleanUp() }
        let relauncher = RecordingRelauncher()
        let installer = makeInstaller(
            oldTeam: "T", newTeam: "T", terminator: RecordingTerminator(wasRunning: wasRunning),
            relauncher: relauncher, relaunch: relaunchEnabled
        )

        try await installer.install(makeUpdate(), from: packageURL)

        let expected = wasRunning && relaunchEnabled ? [installedURL] : []
        #expect(relauncher.relaunchedURLs == expected)
    }

    @Test("a failed swap reopens the quit app (old version still in place)")
    func relaunchesOldAppWhenSwapFails() async throws {
        let applications = installedURL.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: applications.path)
            cleanUp()
        }
        let relauncher = RecordingRelauncher()
        let installer = makeInstaller(
            oldTeam: "T", newTeam: "T", terminator: RecordingTerminator(wasRunning: true), relauncher: relauncher
        )
        // Root-owned /Applications entry stand-in: the folder denies the swap; no authorizer.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: applications.path)

        await #expect(throws: UpdaterError.self) { try await installer.install(makeUpdate(), from: packageURL) }

        #expect(relauncher.relaunchedURLs == [installedURL])
        #expect(try Self.version(of: installedURL) == "1.0")
    }

    // MARK: - Notarization

    @Test("require policy blocks non-notarized, rejected and unknown bundles and keeps the old one", arguments: [
        GatekeeperVerdict.developerIDNotNotarized,
        GatekeeperVerdict.rejected(reason: "no usable signature"),
        GatekeeperVerdict.unknown(reason: "offline"),
    ])
    func requireBlocks(verdict: GatekeeperVerdict) async throws {
        defer { cleanUp() }
        let terminator = RecordingTerminator(wasRunning: true)
        let installer = makeInstaller(
            oldTeam: "T", newTeam: "T", terminator: terminator,
            gatekeeper: FixedGatekeeperAssessor(verdict), policy: .require
        )
        let expected: String
        if case .rejected = verdict {
            expected = "Rejected by Gatekeeper: \(verdict.summary)"
        } else {
            expected = "Not notarized: \(NotarizationGate.blockMessage(for: verdict))"
        }

        await #expect(throws: UpdaterError.signatureInvalid(expected)) {
            try await installer.install(makeUpdate(), from: packageURL)
        }
        #expect(try Self.version(of: installedURL) == "1.0")
        #expect(terminator.terminatedBundleIDs.isEmpty)
    }

    @Test("warnOnly policy installs non-notarized and unassessable bundles, keeping quarantine", arguments: [
        GatekeeperVerdict.developerIDNotNotarized,
        GatekeeperVerdict.unknown(reason: "offline"),
    ])
    func warnOnlyInstalls(verdict: GatekeeperVerdict) async throws {
        defer { cleanUp() }
        let installer = makeInstaller(
            oldTeam: "T", newTeam: "T", gatekeeper: FixedGatekeeperAssessor(verdict), policy: .warnOnly
        )

        try await installer.install(makeUpdate(), from: packageURL)
        #expect(try Self.version(of: installedURL) == "2.0")
        #expect(Quarantine.attribute(of: installedURL)?.contains(";MacAppUpdater;") == true)
    }

    @Test("warnOnly never installs a Gatekeeper-rejected (e.g. revoked) bundle")
    func warnOnlyRejects() async throws {
        defer { cleanUp() }
        let installer = makeInstaller(
            oldTeam: "T", newTeam: "T", gatekeeper: FixedGatekeeperAssessor(.rejected(reason: "revoked")),
            policy: .warnOnly
        )

        await #expect(throws: UpdaterError.self) { try await installer.install(makeUpdate(), from: packageURL) }
        #expect(try Self.version(of: installedURL) == "1.0")
    }

    @Test("a notarized update has its quarantine cleared after assessment")
    func notarizedClearsQuarantine() async throws {
        defer { cleanUp() }
        try await makeInstaller(oldTeam: "T", newTeam: "T").install(makeUpdate(), from: packageURL)
        #expect(Quarantine.attribute(of: installedURL)?.contains(";MacAppUpdater;") != true)
    }

    @Test("off policy skips the Gatekeeper assessment")
    func offSkipsAssessment() async throws {
        defer { cleanUp() }
        let assessor = RecordingGatekeeperAssessor(verdict: .rejected(reason: "x"))
        let installer = makeInstaller(oldTeam: "T", newTeam: "T", gatekeeper: assessor, policy: .off)

        try await installer.install(makeUpdate(), from: packageURL)
        #expect(try Self.version(of: installedURL) == "2.0")
        #expect(assessor.assessedURLs.isEmpty)
    }

    @Test("assesses the staged bundle, not the installed one")
    func assessesStagedBundle() async throws {
        defer { cleanUp() }
        let assessor = RecordingGatekeeperAssessor(verdict: .notarized)
        let installer = makeInstaller(oldTeam: "T", newTeam: "T", gatekeeper: assessor)

        try await installer.install(makeUpdate(), from: packageURL)
        let assessed = assessor.assessedURLs
        #expect(assessed.count == 1)
        #expect(assessed.first?.lastPathComponent == "Foo.app")
        #expect(assessed.first?.standardizedFileURL != installedURL.standardizedFileURL)
    }

    @Test("records the download host only after a successful install")
    func recordsDownloadHost() async throws {
        defer { cleanUp() }
        let suite = "AppInstallerTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsDownloadHostStore(defaults: defaults)

        let blocked = makeInstaller(
            oldTeam: "T", newTeam: "T", gatekeeper: FixedGatekeeperAssessor(.developerIDNotNotarized),
            hostStore: store
        )
        await #expect(throws: UpdaterError.self) { try await blocked.install(makeUpdate(), from: packageURL) }
        #expect(store.lastKnownHost(for: Self.bundleID) == nil)

        try await makeInstaller(oldTeam: "T", newTeam: "T", hostStore: store).install(makeUpdate(), from: packageURL)
        #expect(store.lastKnownHost(for: Self.bundleID) == "example.com")
    }

    // MARK: - Helpers

    private func makeBackupStore() -> BackupStore {
        BackupStore(
            baseDirectory: root.appendingPathComponent("Backups", isDirectory: true),
            terminator: RecordingTerminator(), relauncher: RecordingRelauncher()
        )
    }

    private func makeInstaller(
        oldTeam: String,
        newTeam: String,
        backupStore: (any AppBackupStoring)? = nil,
        terminator: any RunningAppTerminating = NoopTerminator(),
        relauncher: RecordingRelauncher = RecordingRelauncher(),
        relaunch: Bool = true,
        gatekeeper: any GatekeeperAssessing = FixedGatekeeperAssessor(.notarized),
        policy: NotarizationPolicy = .require,
        hostStore: (any DownloadHostStoring)? = nil
    ) -> AppInstaller {
        AppInstaller(
            commandRunner: ProcessCommandRunner(),
            signatureVerifier: StubSignatureVerifier(installedURL: installedURL, oldTeam: oldTeam, newTeam: newTeam),
            terminator: terminator,
            backupStore: backupStore ?? makeBackupStore(),
            relauncher: relauncher,
            relaunchAfterInstall: relaunch,
            gatekeeperAssessor: gatekeeper,
            notarizationPolicy: policy,
            downloadHostStore: hostStore
        )
    }

    private func makeUpdate(source: UpdateSourceKind = .github) -> AvailableUpdate {
        let app = InstalledApp(
            bundleIdentifier: Self.bundleID, name: "Foo", url: installedURL,
            shortVersion: "1.0", buildVersion: "1", sparkleFeedURL: nil, isFromAppStore: false
        )
        return AvailableUpdate(
            app: app, newVersion: "2.0",
            downloadURL: URL(string: "https://example.com/Foo-2.0.zip")!, source: source
        )
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func makeFakeApp(at url: URL, version: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "Foo",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: contents.appendingPathComponent("MacOS/Foo"))
    }

    private static func version(of appURL: URL) throws -> String? {
        let data = try Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return plist?["CFBundleShortVersionString"] as? String
    }
}

@Suite("AppInstaller team pin with a broken resource seal")
struct AppInstallerBrokenSealTests {
    /// The installed app's resources fail full validation; its signature still names the team.
    private struct BrokenSealVerifier: SignatureVerifying {
        func teamIdentifier(of bundleURL: URL) async throws -> String {
            throw UpdaterError.signatureInvalid("a sealed resource is missing or invalid")
        }
        func signingTeam(of bundleURL: URL) async throws -> String { "ABCDE12345" }
    }

    @Test("an app that wrote into its own bundle still pins its update to its team")
    func pinsToSigningTeam() async throws {
        let installer = AppInstaller(
            commandRunner: ProcessCommandRunner(),
            signatureVerifier: BrokenSealVerifier(),
            terminator: NoopTerminator(),
            backupStore: BackupStore(
                baseDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                terminator: RecordingTerminator(), relauncher: RecordingRelauncher()
            ),
            relauncher: RecordingRelauncher(),
            relaunchAfterInstall: false,
            gatekeeperAssessor: FixedGatekeeperAssessor(.notarized),
            notarizationPolicy: .require,
            downloadHostStore: nil
        )
        let app = InstalledApp(
            bundleIdentifier: "com.example.foo", name: "Foo", url: URL(fileURLWithPath: "/nonexistent/Foo.app"),
            shortVersion: "1.0", buildVersion: "1", sparkleFeedURL: nil, isFromAppStore: false
        )
        let update = AvailableUpdate(
            app: app, newVersion: "2.0", downloadURL: URL(string: "https://example.com/Foo-2.0.zip")!, source: .github
        )
        #expect(try await installer.pinnedTeam(for: update) == "ABCDE12345")
    }
}
