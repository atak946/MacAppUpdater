import Foundation
import os
import Testing
@testable import AppUpdaterCore

/// Simulates `hdiutil` and `ditto`: `attach` materializes a fake app at the mount point,
/// `ditto <src> <dst>` copies, `detach` is recorded. Failures are configurable per verb.
final class FakeDiskImageRunner: CommandRunner {
    struct Failure: Error, Equatable {}

    private let calls = OSAllocatedUnfairLock(initialState: [[String]]())
    private let mountedBundleID: String
    private let mountedAppName: String
    private let failingVerbs: Set<String>

    init(mountedBundleID: String, mountedAppName: String = "Foo.app", failingVerbs: Set<String> = []) {
        self.mountedBundleID = mountedBundleID
        self.mountedAppName = mountedAppName
        self.failingVerbs = failingVerbs
    }

    var invocations: [[String]] { calls.withLock { $0 } }
    var verbs: [String] { invocations.compactMap { $0.dropFirst().first } }

    func run(_ executable: String, arguments: [String]) async throws -> String {
        calls.withLock { $0.append([executable] + arguments) }
        let verb = arguments.first ?? ""
        if failingVerbs.contains(verb) || (executable.hasSuffix("ditto") && failingVerbs.contains("ditto")) {
            throw Failure()
        }
        switch (executable, verb) {
        case ("/usr/bin/hdiutil", "attach"):
            guard let index = arguments.firstIndex(of: "-mountpoint") else { return "" }
            let mountPoint = URL(fileURLWithPath: arguments[index + 1])
            try FakeAppBundle.make(
                at: mountPoint.appendingPathComponent(mountedAppName), bundleID: mountedBundleID, version: "2.0"
            )
        case ("/usr/bin/ditto", _) where arguments.count == 2:
            let destination = URL(fileURLWithPath: arguments[1])
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[0]), to: destination)
        default:
            break
        }
        return ""
    }
}

@Suite("DiskImageMounter")
struct DiskImageMounterTests {
    private let image = URL(fileURLWithPath: "/tmp/Foo.dmg")
    private let mountPoint = makeInstallTempDirectory("Mount")

    @Test("attaches read-only without Finder windows and detaches after the body")
    func attachAndDetach() async throws {
        defer { try? FileManager.default.removeItem(at: mountPoint) }
        let runner = FakeDiskImageRunner(mountedBundleID: "com.example.foo")

        let result = try await DiskImageMounter(commandRunner: runner).withMountedImage(at: image, mountPoint: mountPoint) {
            $0.lastPathComponent
        }

        #expect(result == mountPoint.lastPathComponent)
        #expect(runner.invocations.first == [
            "/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen",
            "-mountpoint", mountPoint.path, image.path,
        ])
        #expect(runner.invocations.last == ["/usr/bin/hdiutil", "detach", "-force", mountPoint.path])
    }

    @Test("detaches even when the body throws, and rethrows the body's error")
    func detachesOnError() async {
        defer { try? FileManager.default.removeItem(at: mountPoint) }
        let runner = FakeDiskImageRunner(mountedBundleID: "com.example.foo")

        await #expect(throws: FakeDiskImageRunner.Failure()) {
            try await DiskImageMounter(commandRunner: runner).withMountedImage(at: image, mountPoint: mountPoint) { _ in
                throw FakeDiskImageRunner.Failure()
            }
        }
        #expect(runner.verbs == ["attach", "detach"])
    }

    @Test("a failing attach never runs the body or a detach")
    func attachFailure() async {
        let runner = FakeDiskImageRunner(mountedBundleID: "x", failingVerbs: ["attach"])
        let ran = OSAllocatedUnfairLock(initialState: false)

        await #expect(throws: FakeDiskImageRunner.Failure()) {
            try await DiskImageMounter(commandRunner: runner).withMountedImage(at: image, mountPoint: mountPoint) { _ in
                ran.withLock { $0 = true }
            }
        }
        #expect(!ran.withLock { $0 })
        #expect(runner.verbs == ["attach"])
    }

    @Test("a failing detach is retried three times, then logged, not thrown")
    func detachFailureIsSwallowed() async throws {
        defer { try? FileManager.default.removeItem(at: mountPoint) }
        let runner = FakeDiskImageRunner(mountedBundleID: "x", failingVerbs: ["detach"])
        var mounter = DiskImageMounter(commandRunner: runner)
        mounter.detachRetryDelay = .zero

        let value = try await mounter.withMountedImage(at: image, mountPoint: mountPoint) { _ in 7 }

        #expect(value == 7)
        #expect(runner.verbs == ["attach", "detach", "detach", "detach"])
    }
}

@Suite("AppInstaller disk images and validation")
struct AppInstallerDiskImageTests {
    private static let bundleID = "com.example.dmg-test"

    private let root = makeInstallTempDirectory("AppInstallerDMG")
    private var installedURL: URL { root.appendingPathComponent("Applications/Foo.app") }
    private var imageURL: URL { root.appendingPathComponent("download/Foo-2.0.dmg") }

    private func prepare() throws {
        try FakeAppBundle.make(at: installedURL, bundleID: Self.bundleID, version: "1.0")
    }

    private func makeInstaller(runner: FakeDiskImageRunner, terminator: RecordingTerminator = RecordingTerminator()) -> AppInstaller {
        AppInstaller(
            commandRunner: runner,
            signatureVerifier: PathTeamVerifier(team: "TEAM123"),
            terminator: terminator,
            backupStore: nil,
            relauncher: RecordingRelauncher(),
            relaunchAfterInstall: false,
            gatekeeperAssessor: SpctlGatekeeperAssessor(),
            notarizationPolicy: .off
        )
    }

    private func makeUpdate() -> AvailableUpdate {
        AvailableUpdate(
            app: FakeAppBundle.installedApp(at: installedURL, bundleID: Self.bundleID, version: "1.0"),
            newVersion: "2.0", downloadURL: URL(string: "https://example.com/Foo-2.0.dmg")!, source: .homebrew
        )
    }

    @Test("installs from a dmg: mounts, copies the app out with ditto, detaches and replaces")
    func installsFromDiskImage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try prepare()
        let runner = FakeDiskImageRunner(mountedBundleID: Self.bundleID)

        try await makeInstaller(runner: runner).install(makeUpdate(), from: imageURL)

        #expect(try FakeAppBundle.version(of: installedURL) == "2.0")
        #expect(runner.invocations.map(\.first) == ["/usr/bin/hdiutil", "/usr/bin/ditto", "/usr/bin/hdiutil"])
        #expect(runner.verbs.last == "detach")
    }

    @Test("rejects a dmg whose app has a different bundle identifier and keeps the old app")
    func bundleIdentifierMismatch() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try prepare()
        let runner = FakeDiskImageRunner(mountedBundleID: "com.evil.other")
        let terminator = RecordingTerminator()

        await #expect(throws: UpdaterError.installFailed(
            "Bundle identifier mismatch (expected \(Self.bundleID), got com.evil.other)"
        )) {
            try await makeInstaller(runner: runner, terminator: terminator).install(makeUpdate(), from: imageURL)
        }
        #expect(try FakeAppBundle.version(of: installedURL) == "1.0")
        #expect(terminator.terminatedBundleIDs.isEmpty)
        #expect(runner.verbs.last == "detach")
    }

    @Test("a dmg without any app bundle fails and still detaches")
    func noAppInImage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try prepare()
        let runner = FakeDiskImageRunner(mountedBundleID: Self.bundleID, mountedAppName: "README.txt")

        await #expect(throws: UpdaterError.installFailed("No matching .app bundle found in package")) {
            try await makeInstaller(runner: runner).install(makeUpdate(), from: imageURL)
        }
        #expect(runner.verbs.last == "detach")
    }

    @Test("unknown package formats are refused before anything runs", arguments: ["Foo.tar.gz", "Foo"])
    func unknownFormat(fileName: String) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try prepare()
        let runner = FakeDiskImageRunner(mountedBundleID: Self.bundleID)
        let expected = URL(fileURLWithPath: fileName).pathExtension.isEmpty ? "unknown" : URL(fileURLWithPath: fileName).pathExtension

        await #expect(throws: UpdaterError.unsupportedFormat(expected)) {
            try await makeInstaller(runner: runner).install(makeUpdate(), from: root.appendingPathComponent(fileName))
        }
        #expect(runner.invocations.isEmpty)
        #expect(try FakeAppBundle.version(of: installedURL) == "1.0")
    }
}

@Suite("AppBundleLocator")
struct AppBundleLocatorTests {
    private let root = makeInstallTempDirectory("Locator")

    @Test("prefers the bundle id, then the preferred name, then the only app")
    func fallbackOrder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FakeAppBundle.make(at: root.appendingPathComponent("Wrapped/Other.app"), bundleID: "com.other", version: "1")
        try FakeAppBundle.make(at: root.appendingPathComponent("Foo.app"), bundleID: "com.foo.renamed", version: "1")
        let locator = AppBundleLocator()

        let byID = try locator.locateApp(in: root, bundleIdentifier: "com.other", preferredName: "Foo.app")
        let byName = try locator.locateApp(in: root, bundleIdentifier: "com.missing", preferredName: "Foo.app")

        #expect(byID.lastPathComponent == "Other.app")
        #expect(byName.lastPathComponent == "Foo.app")
        #expect(throws: UpdaterError.installFailed("No matching .app bundle found in package")) {
            try locator.locateApp(in: root, bundleIdentifier: "com.missing", preferredName: "Nope.app")
        }
    }

    @Test("falls back to the single app when neither id nor name match")
    func singleCandidate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FakeAppBundle.make(at: root.appendingPathComponent("Renamed.app"), bundleID: "com.renamed", version: "1")

        let found = try AppBundleLocator().locateApp(in: root, bundleIdentifier: "com.foo", preferredName: "Foo.app")

        #expect(found.lastPathComponent == "Renamed.app")
    }

    @Test("ignores symlinked apps and apps nested deeper than two levels")
    func ignoresSymlinksAndDeepApps() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let real = makeInstallTempDirectory("LocatorTarget")
        defer { try? FileManager.default.removeItem(at: real) }
        try FakeAppBundle.make(at: real.appendingPathComponent("Foo.app"), bundleID: "com.foo", version: "1")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Foo.app"), withDestinationURL: real.appendingPathComponent("Foo.app")
        )
        try FakeAppBundle.make(at: root.appendingPathComponent("a/b/c/Deep.app"), bundleID: "com.foo", version: "1")

        #expect(throws: UpdaterError.installFailed("No matching .app bundle found in package")) {
            try AppBundleLocator().locateApp(in: root, bundleIdentifier: "com.foo", preferredName: "Foo.app")
        }
    }

    @Test("finds Finder-hidden apps (Parallels) but skips dot-files, and unhide clears the flag")
    func hiddenApps() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var hidden = root.appendingPathComponent("Parallels Desktop.app")
        try FakeAppBundle.make(at: hidden, bundleID: "com.parallels.desktop.console", version: "1")
        try FakeAppBundle.make(at: root.appendingPathComponent("Install.app"), bundleID: "com.parallels.install", version: "1")
        try FakeAppBundle.make(at: root.appendingPathComponent(".hidden/Dot.app"), bundleID: "com.dot", version: "1")
        var values = URLResourceValues()
        values.isHidden = true
        try hidden.setResourceValues(values)

        let found = try AppBundleLocator().locateApp(
            in: root, bundleIdentifier: "com.parallels.desktop.console", preferredName: "Parallels Desktop.app"
        )
        #expect(found.lastPathComponent == "Parallels Desktop.app")
        #expect(throws: UpdaterError.installFailed("No matching .app bundle found in package")) {
            try AppBundleLocator().locateApp(in: root, bundleIdentifier: "com.dot", preferredName: "Dot.app")
        }

        AppBundleLocator.unhide(found)
        hidden.removeAllCachedResourceValues()
        #expect(try hidden.resourceValues(forKeys: [.isHiddenKey]).isHidden == false)
    }

    @Test("bundleIdentifier(of:) is nil for a missing or malformed Info.plist")
    func unreadablePlist() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = root.appendingPathComponent("Broken.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: broken.appendingPathComponent("Info.plist"))

        #expect(AppBundleLocator.bundleIdentifier(of: root.appendingPathComponent("Broken.app")) == nil)
        #expect(AppBundleLocator.bundleIdentifier(of: root.appendingPathComponent("Missing.app")) == nil)
    }
}
