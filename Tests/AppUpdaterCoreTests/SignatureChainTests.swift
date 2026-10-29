import CryptoKit
import Foundation
import os
import Testing
@testable import AppUpdaterCore

// MARK: - Requirement builder (H-2)

@Suite("CodeSigningRequirement")
struct CodeSigningRequirementTests {
    @Test("the pinned requirement is anchored to Apple and binds the leaf OU to the team")
    func pinnedRequirement() throws {
        let requirement = try CodeSigningRequirement.pinned(team: "ABCDE12345")
        #expect(requirement.hasPrefix("anchor apple generic and certificate leaf[subject.OU] = \"ABCDE12345\""))
        #expect(requirement.contains("certificate 1[field.1.2.840.113635.100.6.2.6]"))
        #expect(requirement.contains("certificate leaf[field.1.2.840.113635.100.6.1.13]"))
        #expect(requirement.contains("certificate leaf[field.1.2.840.113635.100.6.1.9]"))
    }

    @Test("the trusted-origin requirement allows Apple, Mac App Store and Developer ID only")
    func trustedOrigin() {
        let requirement = CodeSigningRequirement.trustedOrigin
        #expect(requirement.hasPrefix("anchor apple or (anchor apple generic and ("))
        #expect(requirement.contains("100.6.2.6"))
        #expect(requirement.contains("100.6.1.13"))
        #expect(requirement.contains("100.6.1.9"))
    }

    @Test("both requirements compile with the Security framework")
    func requirementsCompile() throws {
        for text in [CodeSigningRequirement.trustedOrigin, try CodeSigningRequirement.pinned(team: "ABCDE12345")] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
        }
    }

    @Test("malformed team IDs are refused, so they cannot inject requirement syntax", arguments: [
        "", "abcde12345", "ABCDE1234", "ABCDE123456", "ABC\" or anchor apple generic or \"", "ABCDE1234É",
    ])
    func malformedTeam(team: String) {
        #expect(!CodeSigningRequirement.isValidTeamIdentifier(team))
        #expect(throws: UpdaterError.self) { try CodeSigningRequirement.pinned(team: team) }
    }
}

// MARK: - Real Security framework checks

@Suite("CodeSignatureVerifier", .serialized)
struct CodeSignatureVerifierTests {
    private let root = makeInstallTempDirectory("CodeSignatureVerifierTests")

    private func makeBundle(adHocSigned: Bool) async throws -> URL {
        let app = root.appendingPathComponent("Foo.app")
        try FakeAppBundle.make(at: app, bundleID: "com.example.sig", version: "1.0")
        if adHocSigned {
            try await ProcessCommandRunner().run("/usr/bin/codesign", arguments: ["-s", "-", "--force", app.path])
        }
        return app
    }

    @Test("an unsigned bundle has no trusted team", arguments: [false, true])
    func untrustedBundlesFail(adHocSigned: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try await makeBundle(adHocSigned: adHocSigned)
        let verifier = CodeSignatureVerifier()

        await #expect(throws: UpdaterError.self) { try await verifier.teamIdentifier(of: app) }
        await #expect(throws: UpdaterError.self) { try await verifier.verify(bundleURL: app, expectedTeam: "ABCDE12345") }
        await #expect(throws: UpdaterError.self) { try await verifier.verifyTeam(of: app, expected: "ABCDE12345") }
    }

    @Test("an ad-hoc signature fails the Apple-anchored requirement, not just the team lookup")
    func adHocFailsRequirement() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try await makeBundle(adHocSigned: true)

        await #expect {
            try await CodeSignatureVerifier().verify(bundleURL: app, expectedTeam: "ABCDE12345")
        } throws: { error in
            guard case UpdaterError.signatureInvalid(let message) = error else { return false }
            return message.contains("Apple-issued")
        }
    }

    @Test("an unsigned disk image is reported as unsigned; a missing one throws")
    func unsignedDiskImage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src", isDirectory: true)
        try FakeAppBundle.make(at: source.appendingPathComponent("Foo.app"), bundleID: "com.example.sig", version: "1.0")
        let image = root.appendingPathComponent("Foo.dmg")
        try await ProcessCommandRunner().run(
            "/usr/bin/hdiutil", arguments: ["create", "-quiet", "-srcfolder", source.path, "-format", "UDZO", image.path]
        )
        let verifier = CodeSignatureVerifier()

        #expect(try await verifier.verifyDiskImage(at: image, expectedTeam: "ABCDE12345") == .unsigned)
        await #expect(throws: UpdaterError.self) {
            try await verifier.verifyDiskImage(at: root.appendingPathComponent("missing.dmg"), expectedTeam: nil)
        }
    }
}

// MARK: - Quarantine (M-4)

@Suite("Quarantine")
struct QuarantineTests {
    @Test("value carries the download flag and the MacAppUpdater agent, never 'user approved'")
    func valueFormat() throws {
        let value = Quarantine.value(date: Date(timeIntervalSince1970: 0x6500_0000))
        #expect(value == "0081;65000000;MacAppUpdater;")
        let flags = try #require(UInt16(value.prefix(4), radix: 16))
        #expect(flags & 0x0040 == 0)
    }

    @Test("apply, read and recursive removal round-trip")
    func roundTrip() throws {
        let root = makeInstallTempDirectory("Quarantine")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Foo.app")
        try FakeAppBundle.make(at: app, bundleID: "com.example.q", version: "1")
        let executable = app.appendingPathComponent("Contents/MacOS/Foo")
        try Quarantine.apply(to: app)
        try Quarantine.apply(to: executable)

        #expect(Quarantine.attribute(of: app)?.contains(";MacAppUpdater;") == true)
        Quarantine.removeRecursively(from: app)
        #expect(Quarantine.attribute(of: app)?.contains(";MacAppUpdater;") != true)
        #expect(Quarantine.attribute(of: executable)?.contains(";MacAppUpdater;") != true)
    }
}

// MARK: - Download verification (M-1, M-4)

private struct PayloadHTTPClient: DownloadTransport {
    let payload: Data

    func download(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("payload-\(UUID().uuidString)")
        try payload.write(to: fileURL)
        return fileURL
    }
}

@Suite("Download verification hardening")
struct DownloadHardeningTests {
    private static let payload = Data("archive".utf8)
    private static let key = Curve25519.Signing.PrivateKey()
    private static var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    private static func update(source: UpdateSourceKind, edSignature: String? = nil) -> AvailableUpdate {
        AvailableUpdate(
            app: InstalledApp(
                bundleIdentifier: "com.example.dl", name: "Foo", url: URL(fileURLWithPath: "/Applications/Foo.app"),
                shortVersion: "1.0", buildVersion: nil, sparkleFeedURL: nil, isFromAppStore: false
            ),
            newVersion: "2.0", downloadURL: URL(string: "https://example.com/Foo-2.0.zip")!,
            source: source, edSignature: edSignature
        )
    }

    private func downloader(key: String?) -> ProgressDownloader {
        ProgressDownloader(transport: PayloadHTTPClient(payload: Self.payload), publicEDKey: { _ in key })
    }

    @Test("a Sparkle update without edSignature is rejected when the app ships SUPublicEDKey")
    func missingSignatureRejected() async {
        await #expect(throws: UpdaterError.signatureInvalid("Missing EdDSA signature (the app ships SUPublicEDKey)")) {
            try await downloader(key: Self.publicKey).download(Self.update(source: .sparkle))
        }
    }

    @Test("a Sparkle update with an empty edSignature is rejected too")
    func emptySignatureRejected() async {
        await #expect(throws: UpdaterError.self) {
            try await downloader(key: Self.publicKey).download(Self.update(source: .sparkle, edSignature: " "))
        }
    }

    @Test("without SUPublicEDKey, or from a non-Sparkle source, a missing signature is fine")
    func notRequired() async throws {
        let unsignedApp = try await downloader(key: nil).download(Self.update(source: .sparkle))
        let homebrew = try await downloader(key: Self.publicKey).download(Self.update(source: .homebrew))
        for file in [unsignedApp, homebrew] {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }

    @Test("a valid signature passes and the download is quarantined in a 0700 directory")
    func validSignatureQuarantined() async throws {
        let signature = try Self.key.signature(for: Self.payload).base64EncodedString()
        let file = try await downloader(key: Self.publicKey).download(Self.update(source: .sparkle, edSignature: signature))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let quarantine = try #require(Quarantine.attribute(of: file))
        #expect(quarantine.hasPrefix("0081;"))
        #expect(quarantine.contains(";MacAppUpdater;"))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
    }
}

// MARK: - Staged version check (M-2)

@Suite("StagedVersionCheck")
struct StagedVersionCheckTests {
    private let check = StagedVersionCheck()

    @Test("accepts a newer bundle that matches the advertised version", arguments: [
        ("2.0", nil, "1.0", nil, "2.0"),
        ("2.0", "200", "1.0", "100", "v2.0"),
        ("2.0", "201", "2.0", "200", "201"),
        ("2.0.0", nil, "1.9", nil, "2.0"),
        ("2024.1", nil, "2023.3", nil, "release-2024-01"),
        // Android Studio: Homebrew says 2026.2.2.8, the bundle says 2026.2 with a newer build.
        ("2026.2", "AI-262.10968.63", "2026.2", "AI-262.9437.185", "2026.2.2.8"),
    ] as [(String, String?, String, String?, String)])
    func accepts(stagedShort: String, stagedBuild: String?, installedShort: String, installedBuild: String?, advertised: String) throws {
        try check.validate(
            staged: (stagedShort, stagedBuild), installed: (installedShort, installedBuild), advertised: advertised
        )
    }

    @Test("rejects downgrades and same-version reinstalls", arguments: [
        ("1.0", nil, "2.0", nil),
        ("2.0", nil, "2.0", nil),
        ("2.0", "199", "2.0", "200"),
    ] as [(String, String?, String, String?)])
    func rejectsDowngrade(stagedShort: String, stagedBuild: String?, installedShort: String, installedBuild: String?) {
        #expect(throws: UpdaterError.self) {
            try check.validate(staged: (stagedShort, stagedBuild), installed: (installedShort, installedBuild), advertised: nil)
        }
    }

    @Test("rejects a bundle that does not match a comparable advertised version")
    func rejectsSpoofedVersion() {
        #expect(throws: UpdaterError.self) {
            try check.validate(staged: ("1.5", "150"), installed: ("1.0", "100"), advertised: "99.0")
        }
        #expect(throws: UpdaterError.self) {
            try check.validate(staged: ("2026.2", "B2"), installed: ("2026.1", "B1"), advertised: "2026.3.1")
        }
        // A single-component short version is too vague to be refined.
        #expect(!StagedVersionCheck.isRefinement("5.1.2", of: "5"))
    }

    @Test("comparable versions are plain dotted numbers", arguments: [
        ("1", true), ("v2.0.1", true), ("10.4.3.2", true), ("1.2-beta", false), ("1.2,345", false), ("", false), ("1..2", false),
    ])
    func comparable(version: String, expected: Bool) {
        #expect(StagedVersionCheck.isComparable(version) == expected)
    }
}

// MARK: - Zip capacity (L-3)

@Suite("ArchiveCapacityCheck")
struct ArchiveCapacityCheckTests {
    private let directory = URL(fileURLWithPath: "/tmp")

    @Test("parses unzip -Zt summaries", arguments: [
        ("17 files, 3795 bytes uncompressed, 1428 bytes compressed:  62.4%", 17, Int64(3795)),
        ("1 file, 12 bytes uncompressed, 12 bytes compressed:  0.0%", 1, Int64(12)),
    ])
    func parses(output: String, files: Int, bytes: Int64) {
        #expect(ArchiveCapacityCheck.parse("warning\n" + output) == .init(fileCount: files, uncompressedBytes: bytes))
    }

    @Test("garbage output is not a summary", arguments: ["", "Archive: x", "x files, y bytes uncompressed"])
    func garbage(output: String) {
        #expect(ArchiveCapacityCheck.parse(output) == nil)
    }

    @Test("rejects archives over the cap, with too many entries, or larger than the free space")
    func limits() {
        var check = ArchiveCapacityCheck(commandRunner: ProcessCommandRunner())
        check.maxUncompressedBytes = 1_000
        check.maxEntries = 10
        check.freeSpaceMargin = 100
        check.availableCapacity = { _ in 600 }

        #expect(throws: Never.self) { try check.validate(.init(fileCount: 3, uncompressedBytes: 500), extractingInto: directory) }
        #expect(throws: UpdaterError.self) { try check.validate(.init(fileCount: 3, uncompressedBytes: 501), extractingInto: directory) }
        #expect(throws: UpdaterError.self) { try check.validate(.init(fileCount: 11, uncompressedBytes: 1), extractingInto: directory) }
        check.availableCapacity = { _ in nil }
        #expect(throws: UpdaterError.self) { try check.validate(.init(fileCount: 1, uncompressedBytes: 1_001), extractingInto: directory) }
    }

    @Test("reads a real zip with /usr/bin/unzip")
    func realZip() async throws {
        let root = makeInstallTempDirectory("ArchiveCapacity")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Foo.app")
        try FakeAppBundle.make(at: app, bundleID: "com.example.zip", version: "1")
        let zip = root.appendingPathComponent("Foo.zip")
        try await ProcessCommandRunner().run("/usr/bin/ditto", arguments: ["-c", "-k", "--keepParent", app.path, zip.path])

        try await ArchiveCapacityCheck(commandRunner: ProcessCommandRunner()).check(zip, extractingInto: root)
        await #expect(throws: UpdaterError.self) {
            try await ArchiveCapacityCheck(commandRunner: ProcessCommandRunner())
                .check(root.appendingPathComponent("missing.zip"), extractingInto: root)
        }
    }
}

// MARK: - BundleReplacer (M-6)

@Suite("BundleReplacer")
struct BundleReplacerTests {
    private let root = makeInstallTempDirectory("BundleReplacer")

    @Test("the staging directory is private (0700) and owned by the current user")
    func privateWorkDirectory() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Foo.app")
        try FakeAppBundle.make(at: target, bundleID: "com.example.r", version: "1")
        let work = try BundleReplacer(fileManager: .default).makeWorkDirectory(near: target)
        defer { try? FileManager.default.removeItem(at: work) }

        let attributes = try FileManager.default.attributesOfItem(atPath: work.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid())
    }

    @Test("securePrivateDirectory tightens loose permissions and refuses symlinks")
    func securesDirectory() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let loose = root.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        try BundleReplacer.securePrivateDirectory(loose)
        #expect((try FileManager.default.attributesOfItem(atPath: loose.path)[.posixPermissions] as? Int) == 0o700)

        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: loose)
        #expect(throws: UpdaterError.self) { try BundleReplacer.securePrivateDirectory(link) }
    }

    @Test("a failed post-swap verification swaps the previous bundle back")
    func rollsBack() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Foo.app")
        let staged = root.appendingPathComponent("staged/Foo.app")
        try FakeAppBundle.make(at: target, bundleID: "com.example.r", version: "1")
        try FakeAppBundle.make(at: staged, bundleID: "com.example.r", version: "2")
        struct Tampered: Error {}

        await #expect(throws: Tampered.self) {
            try await BundleReplacer(fileManager: .default).replace(target, with: staged) { _ in throw Tampered() }
        }
        #expect(try FakeAppBundle.version(of: target) == "1")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["Foo.app", "staged"])
    }

    /// Makes `url` and its subfolders read-only, like a root-owned bundle seen by the user:
    /// it can be renamed inside its folder but neither moved elsewhere nor deleted.
    private static func lock(_ url: URL, _ locked: Bool) {
        let mode = locked ? 0o555 : 0o755
        for path in [url.appendingPathComponent("Contents").path, url.path] {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
    }

    @Test("a bundle that cannot be moved (root-owned) is renamed in place and the old one is hidden")
    func renamesRootOwnedInPlace() async throws {
        let folder = root.appendingPathComponent("Applications", isDirectory: true)
        let target = folder.appendingPathComponent("Foo.app")
        let hidden = folder.appendingPathComponent(".Foo-AppUpdaterBackup.app")
        defer {
            Self.lock(hidden, false)
            Self.lock(folder.appendingPathComponent("Foo-AppUpdaterBackup.app"), false)
            try? FileManager.default.removeItem(at: root)
        }
        let staged = root.appendingPathComponent("staged/Foo.app")
        try FakeAppBundle.make(at: target, bundleID: "com.example.r", version: "1")
        try FakeAppBundle.make(at: staged, bundleID: "com.example.r", version: "2")
        Self.lock(target, true)

        var replacer = BundleReplacer(fileManager: .default)
        replacer.recycler = { _ in throw CocoaError(.fileWriteNoPermission) }
        try await replacer.replace(target, with: staged) { _ in }

        #expect(try FakeAppBundle.version(of: target) == "2")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == [".Foo-AppUpdaterBackup.app", "Foo.app"])
    }

    @Test("a root-owned bundle is trashed when the Finder can, and rolled back by renaming")
    func rootOwnedTrashAndRollback() async throws {
        let folder = root.appendingPathComponent("Applications", isDirectory: true)
        let target = folder.appendingPathComponent("Foo.app")
        defer {
            Self.lock(target, false)
            Self.lock(folder.appendingPathComponent("Foo-AppUpdaterBackup.app"), false)
            try? FileManager.default.removeItem(at: root)
        }
        try FakeAppBundle.make(at: target, bundleID: "com.example.r", version: "1")
        try FakeAppBundle.make(at: root.appendingPathComponent("staged/Foo.app"), bundleID: "com.example.r", version: "2")
        Self.lock(target, true)
        struct Tampered: Error {}

        await #expect(throws: Tampered.self) {
            try await BundleReplacer(fileManager: .default)
                .replace(target, with: root.appendingPathComponent("staged/Foo.app")) { _ in throw Tampered() }
        }
        #expect(try FakeAppBundle.version(of: target) == "1")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Foo.app"])

        let trashed = Trashed()
        try FakeAppBundle.make(at: root.appendingPathComponent("staged2/Foo.app"), bundleID: "com.example.r", version: "3")
        var replacer = BundleReplacer(fileManager: .default)
        replacer.recycler = { url in
            trashed.append(url.lastPathComponent)
            Self.lock(url, false)
            try FileManager.default.removeItem(at: url)
        }
        try await replacer.replace(target, with: root.appendingPathComponent("staged2/Foo.app")) { _ in }
        #expect(try FakeAppBundle.version(of: target) == "3")
        #expect(trashed.names == ["Foo-AppUpdaterBackup.app"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Foo.app"])
    }

    private final class Trashed: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var names: [String] { lock.withLock { stored } }
        func append(_ name: String) { lock.withLock { stored.append(name) } }
    }

    @Test("a folder the user cannot write still fails with the plain error")
    func deniedWithoutAuthorizer() async throws {
        let folder = root.appendingPathComponent("Applications", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: root)
        }
        let target = folder.appendingPathComponent("Foo.app")
        let staged = root.appendingPathComponent("staged/Foo.app")
        try FakeAppBundle.make(at: target, bundleID: "com.example.r", version: "1")
        try FakeAppBundle.make(at: staged, bundleID: "com.example.r", version: "2")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)

        await #expect(throws: UpdaterError.self) {
            try await BundleReplacer(fileManager: .default).replace(target, with: staged) { _ in }
        }
        #expect(try FakeAppBundle.version(of: target) == "1")
    }
}

// MARK: - Install pipeline (H-2, M-2, M-5, M-6, L-3)

/// Team per bundle, decided by the bundle's *current* Info.plist version, so it reflects
/// tampering that happens between checks. Unlisted versions throw (unsigned).
private struct VersionTeamVerifier: SignatureVerifying {
    let teams: [String: String]

    func teamIdentifier(of bundleURL: URL) async throws -> String {
        let version = (try? FakeAppBundle.version(of: bundleURL)).flatMap { $0 } ?? "?"
        guard let team = teams[version] else { throw UpdaterError.signatureInvalid("unsigned") }
        return team
    }
}

/// Fails the post-swap check: the staged bundle verifies, the same bundle in /Applications does not.
private struct InstalledLocationTamperVerifier: SignatureVerifying {
    let installedURL: URL

    func teamIdentifier(of bundleURL: URL) async throws -> String {
        let isInstalled = bundleURL.standardizedFileURL.path == installedURL.standardizedFileURL.path
        let version = (try? FakeAppBundle.version(of: bundleURL)).flatMap { $0 }
        return isInstalled && version == "2.0" ? "EVIL999999" : "ABCDE12345"
    }
}

private struct StubDiskImageVerifier: DiskImageSignatureVerifying {
    let result: Result<DiskImageSignatureStatus, UpdaterError>
    let seenTeams = OSAllocatedUnfairLock(initialState: [String?]())

    func verifyDiskImage(at imageURL: URL, expectedTeam: String?) async throws -> DiskImageSignatureStatus {
        seenTeams.withLock { $0.append(expectedTeam) }
        return try result.get()
    }
}

@Suite("AppInstaller security pipeline", .serialized)
struct AppInstallerSecurityTests {
    private static let bundleID = "com.example.pipeline"
    private static let team = "ABCDE12345"

    private let root = makeInstallTempDirectory("AppInstallerSecurity")
    private var installedURL: URL { root.appendingPathComponent("Applications/Foo.app") }
    private var packageURL: URL { root.appendingPathComponent("download/Foo.zip") }

    private func prepare(installed: String = "1.0", staged: String = "2.0") async throws {
        try FakeAppBundle.make(at: installedURL, bundleID: Self.bundleID, version: installed)
        let build = root.appendingPathComponent("build/Foo.app")
        try FakeAppBundle.make(at: build, bundleID: Self.bundleID, version: staged)
        try FileManager.default.createDirectory(at: packageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await ProcessCommandRunner().run(
            "/usr/bin/ditto", arguments: ["-c", "-k", "--keepParent", build.path, packageURL.path]
        )
    }

    private func installer(
        _ verifier: any SignatureVerifying,
        runner: any CommandRunner = ProcessCommandRunner(),
        diskImageVerifier: (any DiskImageSignatureVerifying)? = nil
    ) -> AppInstaller {
        AppInstaller(
            commandRunner: runner, signatureVerifier: verifier, terminator: RecordingTerminator(),
            backupStore: nil, relauncher: RecordingRelauncher(), relaunchAfterInstall: false,
            gatekeeperAssessor: FixedGatekeeperAssessor(.notarized), notarizationPolicy: .require,
            diskImageVerifier: diskImageVerifier
        )
    }

    private func update(installed: String = "1.0", advertised: String = "2.0", expectedTeam: String? = nil, file: String = "Foo.zip") -> AvailableUpdate {
        AvailableUpdate(
            app: FakeAppBundle.installedApp(at: installedURL, bundleID: Self.bundleID, version: installed),
            newVersion: advertised, downloadURL: URL(string: "https://example.com/\(file)")!, source: .vendor,
            expectedTeamID: expectedTeam
        )
    }

    private var installedVersion: String? { (try? FakeAppBundle.version(of: installedURL)).flatMap { $0 } }

    @Test("M-2: a staged bundle older than the installed one is rejected")
    func olderStagedRejected() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try await prepare(installed: "3.0", staged: "2.0")
        let verifier = VersionTeamVerifier(teams: ["3.0": Self.team, "2.0": Self.team])

        await #expect(throws: UpdaterError.self) {
            try await installer(verifier).install(update(installed: "3.0", advertised: "99.0"), from: packageURL)
        }
        #expect(installedVersion == "3.0")
    }

    @Test("M-2: a staged bundle that differs from the advertised version is rejected")
    func advertisedMismatchRejected() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try await prepare(installed: "1.0", staged: "1.5")
        let verifier = VersionTeamVerifier(teams: ["1.0": Self.team, "1.5": Self.team])

        await #expect(throws: UpdaterError.self) {
            try await installer(verifier).install(update(advertised: "99.0"), from: packageURL)
        }
        #expect(installedVersion == "1.0")
    }

    @Test("M-5: expectedTeamID must match the installed app's team")
    func expectedTeamMismatch() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try await prepare()
        let verifier = VersionTeamVerifier(teams: ["1.0": Self.team, "2.0": Self.team])

        await #expect(throws: UpdaterError.teamIdentifierMismatch(expected: "ZZZZZ99999", actual: Self.team)) {
            try await installer(verifier).install(update(expectedTeam: "ZZZZZ99999"), from: packageURL)
        }
        #expect(installedVersion == "1.0")
    }

    @Test("M-5: an unsigned installed app updates only when the source pins the team")
    func unsignedInstalledNeedsPin() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try await prepare()
        let verifier = VersionTeamVerifier(teams: ["2.0": Self.team])

        await #expect {
            try await installer(verifier).install(update(), from: packageURL)
        } throws: { error in
            guard case UpdaterError.signatureInvalid(let message) = error else { return false }
            return message.contains("not signed with a valid Developer ID")
        }
        #expect(installedVersion == "1.0")

        try await installer(verifier).install(update(expectedTeam: Self.team), from: packageURL)
        #expect(installedVersion == "2.0")
    }

    @Test("M-5: with an unsigned installed app the staged bundle must carry the pinned team")
    func unsignedInstalledWrongStagedTeam() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try await prepare()
        let verifier = VersionTeamVerifier(teams: ["2.0": "EVIL999999"])

        await #expect(throws: UpdaterError.teamIdentifierMismatch(expected: Self.team, actual: "EVIL999999")) {
            try await installer(verifier).install(update(expectedTeam: Self.team), from: packageURL)
        }
        #expect(installedVersion == "1.0")
    }

    @Test("M-6: a bundle that fails verification once in place is rolled back")
    func postSwapVerificationRollsBack() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try await prepare()
        let verifier = InstalledLocationTamperVerifier(installedURL: installedURL)

        await #expect(throws: UpdaterError.teamIdentifierMismatch(expected: Self.team, actual: "EVIL999999")) {
            try await installer(verifier).install(update(), from: packageURL)
        }
        #expect(installedVersion == "1.0")
        let siblings = try FileManager.default.contentsOfDirectory(atPath: installedURL.deletingLastPathComponent().path)
        #expect(siblings == ["Foo.app"])
    }

    @Test("L-3: a disk image whose signature fails is never mounted")
    func badDiskImageNotMounted() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FakeAppBundle.make(at: installedURL, bundleID: Self.bundleID, version: "1.0")
        let runner = FakeDiskImageRunner(mountedBundleID: Self.bundleID)
        let dmgVerifier = StubDiskImageVerifier(result: .failure(.teamIdentifierMismatch(expected: Self.team, actual: "EVIL999999")))
        let verifier = VersionTeamVerifier(teams: ["1.0": Self.team, "2.0": Self.team])

        await #expect(throws: UpdaterError.teamIdentifierMismatch(expected: Self.team, actual: "EVIL999999")) {
            try await installer(verifier, runner: runner, diskImageVerifier: dmgVerifier)
                .install(update(file: "Foo.dmg"), from: root.appendingPathComponent("download/Foo.dmg"))
        }
        #expect(runner.invocations.isEmpty)
        #expect(dmgVerifier.seenTeams.withLock { $0 } == [Self.team])
    }

    @Test("L-3: an unsigned disk image is mounted and its app verified as usual")
    func unsignedDiskImageInstalls() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FakeAppBundle.make(at: installedURL, bundleID: Self.bundleID, version: "1.0")
        let runner = FakeDiskImageRunner(mountedBundleID: Self.bundleID)
        let verifier = VersionTeamVerifier(teams: ["1.0": Self.team, "2.0": Self.team])

        try await installer(verifier, runner: runner, diskImageVerifier: StubDiskImageVerifier(result: .success(.unsigned)))
            .install(update(file: "Foo.dmg"), from: root.appendingPathComponent("download/Foo.dmg"))
        #expect(installedVersion == "2.0")
    }
}

// MARK: - Restore gates (H-2)

/// Records every assessed bundle path.
private final class PathRecordingAssessor: GatekeeperAssessing {
    private let verdict: GatekeeperVerdict
    private let calls = OSAllocatedUnfairLock(initialState: [String]())

    init(_ verdict: GatekeeperVerdict) {
        self.verdict = verdict
    }

    var assessedPaths: [String] { calls.withLock { $0 } }

    func assess(_ bundleURL: URL) async -> GatekeeperVerdict {
        calls.withLock { $0.append(bundleURL.standardizedFileURL.path) }
        return verdict
    }
}

@Suite("BackupStore restore gates")
struct BackupRestoreGateTests {
    private static let bundleID = "com.example.restore-gates"

    private let root = makeInstallTempDirectory("BackupRestoreGates")
    private var backupsDirectory: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    private var installedURL: URL { root.appendingPathComponent("Applications/Foo.app") }

    private func store(_ assessor: any GatekeeperAssessing, policy: NotarizationPolicy = .require) -> BackupStore {
        BackupStore(
            baseDirectory: backupsDirectory, signatureVerifier: PathTeamVerifier(team: "TEAM123"),
            terminator: RecordingTerminator(), relauncher: RecordingRelauncher(), relaunchAfterRestore: false,
            gatekeeperAssessor: assessor, notarizationPolicy: policy
        )
    }

    private func install(_ version: String) throws -> InstalledApp {
        try? FileManager.default.removeItem(at: installedURL)
        try FakeAppBundle.make(at: installedURL, bundleID: Self.bundleID, version: version)
        return FakeAppBundle.installedApp(at: installedURL, bundleID: Self.bundleID, version: version)
    }

    @Test("restore assesses the private staged copy and blocks a rejected backup", arguments: [
        (GatekeeperVerdict.rejected(reason: "revoked"), NotarizationPolicy.warnOnly),
        (.unknown(reason: "offline"), .require),
        (.developerIDNotNotarized, .require),
    ])
    func restoreRunsGate(verdict: GatekeeperVerdict, policy: NotarizationPolicy) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let assessor = PathRecordingAssessor(verdict)
        let store = store(assessor, policy: policy)
        let backup = try await store.backUp(try install("1.0"))
        let current = try install("2.0")

        await #expect(throws: UpdaterError.self) { try await store.restore(backup, over: current) }
        #expect(try FakeAppBundle.version(of: installedURL) == "2.0")
        let assessed = assessor.assessedPaths
        #expect(assessed.count == 1)
        #expect(assessed.allSatisfy { !$0.hasPrefix(backupsDirectory.path) })
        #expect(try await store.backups(for: Self.bundleID) == [backup])
    }

    @Test("backups live in a 0700 directory")
    func backupDirectoryIsPrivate() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await store(FixedGatekeeperAssessor(.notarized)).backUp(try install("1.0"))
        let attributes = try FileManager.default.attributesOfItem(atPath: backupsDirectory.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
    }
}

// MARK: - Vendor feeds (M-5)

@Suite("VendorFeedSource team pin")
struct VendorFeedTeamPinTests {
    @Test("updates carry the definition's expectedTeamID")
    func carriesTeam() async throws {
        let feedURL = URL(string: "https://product-details.mozilla.org/1.0/firefox_versions.json")!
        let source = VendorFeedSource(
            definitions: try VendorFeedSource.bundledDefinitions(),
            http: MockHTTPClient(strings: [feedURL.absoluteString: #"{"LATEST_FIREFOX_VERSION": "131.0.3"}"#]),
            comparator: NumericStubComparator()
        )
        let app = TestApps.make(bundleIdentifier: "org.mozilla.firefox", shortVersion: "130.0")
        let update = try #require(try await source.lookup(app).update)
        #expect(update.expectedTeamID == "43AQ936H96")
    }
}
