import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("Tarball support")
struct TarballSupportTests {
    @Test("a bsdtar listing is summed; unsafe paths and garbage fail closed")
    func parseListing() throws {
        let listing = """
        drwxr-xr-x  0 dev    staff       0 Nov 18 10:00 Tool.app/
        -rw-r--r--  0 dev    staff    1234 Nov 18 10:00 Tool.app/Contents/Info.plist
        lrwxr-xr-x  0 dev    staff       0 Nov 18  2025 Tool.app/Contents/Frameworks/Current -> A
        """
        let summary = try TarballCapacityCheck.parse(listing)
        #expect(summary == ArchiveCapacityCheck.Summary(fileCount: 3, uncompressedBytes: 1234))

        for bad in [
            "-rw-r--r--  0 dev staff 10 Nov 18 10:00 ../evil",
            "-rw-r--r--  0 dev staff 10 Nov 18 10:00 /etc/evil",
            "-rw-r--r--  0 dev staff 10 Nov 18 10:00 Tool.app/../../evil",
            "not a listing",
            "",
        ] {
            #expect(throws: UpdaterError.self) { try TarballCapacityCheck.parse(bad) }
        }
    }

    @Test("the parser reads the real /usr/bin/tar listing format")
    func realTarListing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TarTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Tool.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: contents.appendingPathComponent("Info.plist"))
        let archive = root.appendingPathComponent("Tool.tar.gz")
        let runner = ProcessCommandRunner()
        try await runner.run(SystemTool.tar, arguments: ["-czf", archive.path, "-C", root.path, "Tool.app"])

        #expect(PackageSniffer.detect(archive) == .tarball)
        let listing = try await runner.run(SystemTool.tar, arguments: ["-tvf", archive.path])
        let summary = try TarballCapacityCheck.parse(listing)
        #expect(summary.uncompressedBytes == 4096)
        #expect(summary.fileCount == 3)
    }

    @Test("compressed tarballs, plain tar and a bzip2 disk image are told apart")
    func sniffing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Sniff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func write(_ data: Data) throws -> URL {
            let url = folder.appendingPathComponent(UUID().uuidString)
            try data.write(to: url)
            return url
        }
        let padding = Data(repeating: 0, count: 1024)
        #expect(PackageSniffer.detect(try write(Data([0x1F, 0x8B, 8, 0]) + padding)) == .tarball)
        #expect(PackageSniffer.detect(try write(Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) + padding)) == .tarball)
        var ustar = Data(repeating: 0, count: 257) + Data("ustar".utf8)
        ustar.append(padding)
        #expect(PackageSniffer.detect(try write(ustar)) == .tarball)
        // UDBZ: bzip2 chunks up front, the UDIF trailer decides.
        let udbz = Data("BZh91AY".utf8) + Data(repeating: 1, count: 2048) + Data("koly".utf8) + Data(repeating: 0, count: 508)
        #expect(PackageSniffer.detect(try write(udbz)) == .dmg)
        #expect(try PackageSniffer.labelling(write(Data([0x1F, 0x8B, 8, 0]) + padding)).pathExtension == "tar")
    }

    @Test("GitHub picks a macOS tarball only when the release has no dmg, zip or pkg")
    func gitHubTarballChoice() throws {
        func asset(_ name: String) -> GitHubRelease.Asset {
            let json = #"{"name": "\#(name)", "browser_download_url": "https://github.com/o/r/releases/download/v1/\#(name)"}"#
            return try! JSONDecoder().decode(GitHubRelease.Asset.self, from: Data(json.utf8))
        }
        let source = GitHubReleasesSource(repositories: [:], http: MockHTTPClient(strings: [:]), comparator: VersionComparator())
        let linuxAndMac = [asset("tool-linux-x64.tar.gz"), asset("tool-macos-universal.tar.gz")]
        #expect(source.preferredAsset(in: linuxAndMac)?.name == "tool-macos-universal.tar.gz")
        #expect(source.preferredAsset(in: [asset("tool-linux.tar.gz")]) == nil)
        #expect(source.preferredAsset(in: linuxAndMac + [asset("Tool.dmg")])?.name == "Tool.dmg")
    }
}

@Suite("Download hints and remembered formats")
struct DownloadHintTests {
    private static func update(_ url: String) -> AvailableUpdate {
        AvailableUpdate(app: TestApps.make(), newVersion: "2.0", downloadURL: URL(string: url)!, source: .vendor)
    }

    @Test("what the server says decides whether a download is worth fetching", arguments: [
        (DownloadHint(size: 1, fileName: "index.html", mimeType: "text/html"), true),
        (DownloadHint(size: 1, fileName: "download", mimeType: "text/html; charset=utf-8"), true),
        (DownloadHint(size: 1, fileName: "Tool.7z", mimeType: "application/octet-stream"), true),
        (DownloadHint(size: 1, fileName: "App.dmg", mimeType: "text/html"), false),
        (DownloadHint(size: 1, fileName: "download", mimeType: "application/octet-stream"), false),
        (DownloadHint(size: nil, fileName: nil, mimeType: nil), false),
    ])
    func knownNonPackage(hint: DownloadHint, expected: Bool) {
        #expect(hint.isKnownNonPackage == expected)
    }

    @Test("a remembered format applies to the same app and host only")
    func storeIsPerHost() throws {
        let defaults = try #require(UserDefaults(suiteName: "DetectedFormatStore.\(UUID().uuidString)"))
        let store = UserDefaultsDetectedFormatStore(defaults: defaults)
        let first = Self.update("https://dl.example.com/latest")
        store.record(.dmg, for: first)
        store.record(.unknown, for: Self.update("https://dl.example.com/other"))

        #expect(store.format(for: Self.update("https://dl.example.com/next")) == .dmg)
        #expect(store.format(for: Self.update("https://mirror.example.com/latest")) == nil)
    }

    @Test("a known format turns an extension-less link into a regular install path")
    func knownFormatResolvesMethod() {
        let update = Self.update("https://dl.example.com/latest")
        #expect(InstallMethod(update: update) == .detectedAfterDownload)
        #expect(InstallMethod(update: update, knownFormat: .zip) == .automatic)
        #expect(InstallMethod(update: update, knownFormat: .pkg) == .installerPackage)
        // A known non-package extension is never overridden.
        #expect(InstallMethod(update: Self.update("https://dl.example.com/a.webloc"), knownFormat: .dmg) == .manualDownload)
    }

    @Test("auto-install accepts an extension-less update only with a remembered in-place format")
    func autoInstallWithKnownFormat() {
        let update = Self.update("https://dl.example.com/latest")
        let policies = UpdatePolicies(defaultPolicy: .autoInstall)
        let old = Date(timeIntervalSince1970: 0)
        func verdict(_ known: PackageFormat?) -> AutoInstallVerdict {
            let input = AutoInstallInput(
                updates: [update], policies: policies, conditions: SystemConditionsSnapshot(),
                releaseDates: [update.id: ReleaseDate(date: old, kind: .published)],
                knownFormat: { _ in known }
            )
            return AutoInstallPlanner().verdict(for: update, input: input)
        }
        #expect(verdict(nil) != .install)
        #expect(verdict(.pkg) != .install)
        #expect(verdict(.dmg) == .install, "\(verdict(.dmg))")
    }
}
