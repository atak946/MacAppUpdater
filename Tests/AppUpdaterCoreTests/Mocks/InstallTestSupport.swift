import Foundation
import os
@testable import AppUpdaterCore

/// Builds minimal unsigned `.app` bundles for install/backup tests.
enum FakeAppBundle {
    static func make(at url: URL, bundleID: String, version: String) throws {
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

    static func version(of appURL: URL) throws -> String? {
        let data = try Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return plist?["CFBundleShortVersionString"] as? String
    }

    static func installedApp(at url: URL, bundleID: String, version: String) -> InstalledApp {
        InstalledApp(
            bundleIdentifier: bundleID, name: url.deletingPathExtension().lastPathComponent, url: url,
            shortVersion: version, buildVersion: nil, sparkleFeedURL: nil, isFromAppStore: false
        )
    }
}

/// Team id per path: bundles under any `untrustedPrefixes` get `otherTeam`, everything else `team`.
struct PathTeamVerifier: SignatureVerifying {
    let team: String
    var otherTeam: String = "EVIL999"
    var untrustedPrefixes: [String] = []

    func teamIdentifier(of bundleURL: URL) async throws -> String {
        let path = bundleURL.standardizedFileURL.path
        return untrustedPrefixes.contains { path.hasPrefix($0) } ? otherTeam : team
    }
}

/// Records calls; reports `wasRunning` as configured.
final class RecordingTerminator: RunningAppTerminating {
    private let wasRunning: Bool
    private let calls = OSAllocatedUnfairLock(initialState: [String]())

    init(wasRunning: Bool = false) {
        self.wasRunning = wasRunning
    }

    var terminatedBundleIDs: [String] { calls.withLock { $0 } }

    func terminateRunningInstances(of bundleIdentifier: String) async throws {
        _ = try await quitRunningInstances(of: bundleIdentifier)
    }

    func quitRunningInstances(of bundleIdentifier: String) async throws -> Bool {
        calls.withLock { $0.append(bundleIdentifier) }
        return wasRunning
    }
}

final class RecordingRelauncher: AppRelaunching {
    private let calls = OSAllocatedUnfairLock(initialState: [URL]())

    var relaunchedURLs: [URL] { calls.withLock { $0 } }

    func relaunch(_ appURL: URL) async throws {
        calls.withLock { $0.append(appURL) }
    }
}

/// A backup store that always fails, to prove the installer aborts.
struct FailingBackupStore: AppBackupStoring {
    struct Failure: Error {}

    func backUp(_ app: InstalledApp) async throws -> AppBackup { throw Failure() }
    func backups(for bundleIdentifier: String) async throws -> [AppBackup] { [] }
    func restore(_ backup: AppBackup, over app: InstalledApp) async throws {}
    func delete(_ backup: AppBackup) async throws {}
    func pruneAll() async throws {}
}

/// Mutable clock for retention tests.
final class BackupTestClock: Sendable {
    private let current: OSAllocatedUnfairLock<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = OSAllocatedUnfairLock(initialState: start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(by interval: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

func makeInstallTempDirectory(_ prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        .resolvingSymlinksInPath()
}
