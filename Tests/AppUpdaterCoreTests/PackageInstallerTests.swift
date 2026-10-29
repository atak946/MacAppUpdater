import Foundation
import os
import Testing
@testable import AppUpdaterCore

/// Records install requests (expected team + bytes readable through the handle); optionally fails.
private final class RecordingInstallService: PackageInstallService, Sendable {
    struct Call: Equatable {
        let expectedTeamID: String
        let bytes: Data
    }

    private let calls = OSAllocatedUnfairLock<[Call]>(initialState: [])
    private let error: HelperClientError?

    init(error: HelperClientError? = nil) {
        self.error = error
    }

    var recorded: [Call] { calls.withLock { $0 } }

    func installPackage(from fileHandle: FileHandle, expectedTeamID: String) async throws {
        try fileHandle.seek(toOffset: 0)
        let bytes = try fileHandle.readToEnd() ?? Data()
        calls.withLock { $0.append(Call(expectedTeamID: expectedTeamID, bytes: bytes)) }
        if let error { throw error }
    }
}

private struct FixedTeamVerifier: SignatureVerifying {
    let team: String?

    func teamIdentifier(of bundleURL: URL) async throws -> String {
        guard let team else { throw UpdaterError.signatureInvalid("ad-hoc") }
        return team
    }
}

private struct NoopTerminator: RunningAppTerminating {
    func terminateRunningInstances(of bundleIdentifier: String) async throws {}
}

@Suite("PackageInstaller")
struct PackageInstallerTests {
    private static let packageBytes = Data("xar!package-payload".utf8)

    private func withPackage(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PackageInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Example-2.0.pkg")
        try Self.packageBytes.write(to: url)
        try await body(url)
    }

    private func makeUpdate(source: UpdateSourceKind = .sparkle, expectedTeamID: String? = nil) -> AvailableUpdate {
        let app = InstalledApp(
            bundleIdentifier: "com.example.app", name: "Example",
            url: URL(fileURLWithPath: "/Applications/Example.app"),
            shortVersion: "1.0", buildVersion: nil, sparkleFeedURL: nil, isFromAppStore: false
        )
        return AvailableUpdate(
            app: app, newVersion: "2.0",
            downloadURL: URL(string: "https://example.com/Example-2.0.pkg")!, source: source,
            expectedTeamID: expectedTeamID
        )
    }

    private func makeInstaller(
        pkgutil: String, exitStatus: Int32 = 0, appTeam: String?, service: RecordingInstallService
    ) -> PackageInstaller {
        PackageInstaller(
            installService: service,
            commandRunner: PkgutilStubRunner(output: pkgutil, exitStatus: exitStatus),
            appSignatureVerifier: FixedTeamVerifier(team: appTeam),
            terminator: NoopTerminator()
        )
    }

    @Test("installs when package team matches the installed app, passing team and an open handle")
    func installsMatchingTeam() async throws {
        let service = RecordingInstallService()
        let installer = makeInstaller(pkgutil: PkgutilFixtures.developerID, appTeam: "ABCDE12345", service: service)
        try await withPackage { url in
            try await installer.install(makeUpdate(), from: url)
        }
        #expect(service.recorded == [.init(expectedTeamID: "ABCDE12345", bytes: Self.packageBytes)])
    }

    @Test("rejects team mismatch without calling the helper")
    func rejectsTeamMismatch() async throws {
        let service = RecordingInstallService()
        let installer = makeInstaller(pkgutil: PkgutilFixtures.developerID, appTeam: "ZZZZZ99999", service: service)
        try await withPackage { url in
            await #expect(throws: UpdaterError.teamIdentifierMismatch(expected: "ZZZZZ99999", actual: "ABCDE12345")) {
                try await installer.install(makeUpdate(), from: url)
            }
        }
        #expect(service.recorded.isEmpty)
    }

    @Test("unsigned installed app without a curated team is refused (H-4)")
    func unsignedAppWithoutTeamIsRefused() async throws {
        let service = RecordingInstallService()
        let installer = makeInstaller(pkgutil: PkgutilFixtures.developerID, appTeam: nil, service: service)
        try await withPackage { url in
            await #expect(throws: UpdaterError.self) {
                try await installer.install(makeUpdate(), from: url)
            }
        }
        #expect(service.recorded.isEmpty)
    }

    @Test("unsigned installed app falls back to the update's curated team")
    func unsignedAppUsesCuratedTeam() async throws {
        let service = RecordingInstallService()
        let installer = makeInstaller(pkgutil: PkgutilFixtures.developerID, appTeam: nil, service: service)
        try await withPackage { url in
            try await installer.install(makeUpdate(expectedTeamID: "ABCDE12345"), from: url)
        }
        #expect(service.recorded.map(\.expectedTeamID) == ["ABCDE12345"])
    }

    @Test("rejects non-notarized packages")
    func rejectsNotNotarized() async throws {
        let service = RecordingInstallService()
        let installer = makeInstaller(pkgutil: PkgutilFixtures.developerIDNotNotarized, appTeam: "ABCDE12345", service: service)
        try await withPackage { url in
            await #expect(throws: UpdaterError.signatureInvalid("Package is not notarized by Apple")) {
                try await installer.install(makeUpdate(), from: url)
            }
        }
        #expect(service.recorded.isEmpty)
    }

    @Test("rejects unsigned packages")
    func rejectsUnsignedPackage() async throws {
        let service = RecordingInstallService()
        let installer = makeInstaller(pkgutil: PkgutilFixtures.unsigned, exitStatus: 1, appTeam: "ABCDE12345", service: service)
        try await withPackage { url in
            await #expect(throws: UpdaterError.signatureInvalid("Package not accepted (no signature)")) {
                try await installer.install(makeUpdate(), from: url)
            }
        }
        #expect(service.recorded.isEmpty)
    }

    @Test("rejects Apple-signed packages for third-party apps")
    func rejectsApplePackage() async throws {
        let service = RecordingInstallService()
        let installer = makeInstaller(pkgutil: PkgutilFixtures.apple, appTeam: "ABCDE12345", service: service)
        try await withPackage { url in
            await #expect(throws: UpdaterError.signatureInvalid("Apple-signed packages are not accepted for third-party updates")) {
                try await installer.install(makeUpdate(), from: url)
            }
        }
        #expect(service.recorded.isEmpty)
    }

    @Test("refuses symlinked package paths")
    func rejectsSymlink() async throws {
        let service = RecordingInstallService()
        let installer = makeInstaller(pkgutil: PkgutilFixtures.developerID, appTeam: "ABCDE12345", service: service)
        try await withPackage { url in
            let link = url.deletingLastPathComponent().appendingPathComponent("Link.pkg")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            await #expect(throws: UpdaterError.self) {
                try await installer.install(makeUpdate(), from: link)
            }
        }
        #expect(service.recorded.isEmpty)
    }

    @Test("maps helper failures to installFailed")
    func mapsHelperError() async throws {
        let error = HelperClientError.helperNotEnabled(.requiresApproval)
        let service = RecordingInstallService(error: error)
        let installer = makeInstaller(pkgutil: PkgutilFixtures.developerID, appTeam: "ABCDE12345", service: service)
        try await withPackage { url in
            await #expect(throws: UpdaterError.installFailed(error.localizedDescription)) {
                try await installer.install(makeUpdate(), from: url)
            }
        }
    }

    @Test("rejects non-pkg files and App Store updates")
    func rejectsUnsupported() async throws {
        let service = RecordingInstallService()
        let installer = makeInstaller(pkgutil: PkgutilFixtures.developerID, appTeam: "ABCDE12345", service: service)
        await #expect(throws: UpdaterError.unsupportedFormat("dmg")) {
            try await installer.install(makeUpdate(), from: URL(fileURLWithPath: "/tmp/x.dmg"))
        }
        try await withPackage { url in
            await #expect(throws: UpdaterError.unsupportedFormat("appStore")) {
                try await installer.install(makeUpdate(source: .appStore), from: url)
            }
        }
    }

    @Test("expected team resolution fails closed")
    func resolveExpectedTeam() throws {
        #expect(try PackageInstaller.resolveExpectedTeam(installedTeam: "ABCDE12345", updateTeam: nil) == "ABCDE12345")
        #expect(try PackageInstaller.resolveExpectedTeam(installedTeam: "ABCDE12345", updateTeam: "ABCDE12345") == "ABCDE12345")
        #expect(try PackageInstaller.resolveExpectedTeam(installedTeam: nil, updateTeam: "ABCDE12345") == "ABCDE12345")
        #expect(throws: UpdaterError.teamIdentifierMismatch(expected: "ZZZZZ99999", actual: "ABCDE12345")) {
            try PackageInstaller.resolveExpectedTeam(installedTeam: "ABCDE12345", updateTeam: "ZZZZZ99999")
        }
        #expect(throws: UpdaterError.self) { try PackageInstaller.resolveExpectedTeam(installedTeam: nil, updateTeam: nil) }
        #expect(throws: UpdaterError.self) { try PackageInstaller.resolveExpectedTeam(installedTeam: nil, updateTeam: "bad") }
    }

    @Test("maps SMAppService statuses")
    func mapsStatuses() {
        #expect(HelperClient.map(.enabled) == .enabled)
        #expect(HelperClient.map(.requiresApproval) == .requiresApproval)
        #expect(HelperClient.map(.notRegistered) == .notRegistered)
        #expect(HelperClient.map(.notFound) == .notFound)
    }
}
