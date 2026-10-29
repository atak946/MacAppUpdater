import Foundation
import os
@testable import AppUpdaterCore

/// Fake home directory inside a temp dir. Never touches the real home.
struct UninstallSandbox {
    let root: URL
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    var library: URL { home.appendingPathComponent("Library", isDirectory: true) }
    var trash: URL { root.appendingPathComponent("Trash", isDirectory: true) }
    var outside: URL { root.appendingPathComponent("outside", isDirectory: true) }

    static func run(_ body: (UninstallSandbox) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UninstallTests-\(UUID().uuidString)", isDirectory: true)
        let sandbox = UninstallSandbox(root: root)
        for dir in [sandbox.library, sandbox.trash, sandbox.outside] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(sandbox)
    }

    /// Creates `~/Library/<relativePath>`; a folder (with one file inside) or a file.
    @discardableResult
    func make(_ relativePath: String, directory: Bool = true, contents: Data = Data("x".utf8)) throws -> URL {
        let url = library.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try contents.write(to: url.appendingPathComponent("data.bin"))
        } else {
            try contents.write(to: url)
        }
        return url
    }

    @discardableResult
    func makePlist(_ relativePath: String, _ plist: [String: Any]) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return try make(relativePath, directory: false, contents: data)
    }

    func makeApp(id: String, name: String) throws -> InstalledApp {
        let appURL = root.appendingPathComponent("Applications/\(name).app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": "1.0"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return InstalledApp(
            bundleIdentifier: id, name: name, url: appURL, shortVersion: "1.0",
            buildVersion: nil, sparkleFeedURL: nil, isFromAppStore: false
        )
    }

    var scanner: LeftoverScanner { LeftoverScanner(homeDirectory: home) }
}

struct FakeRunningChecker: RunningAppChecking {
    let running: Set<String>
    func isRunning(bundleIdentifier: String) async -> Bool { running.contains(bundleIdentifier) }
}

/// Moves items into the sandbox's fake Trash and records every call.
final class RecordingTrasher: Trashing, Sendable {
    private let trashDirectory: URL
    private let failing: Set<String>
    private let calls = OSAllocatedUnfairLock<[URL]>(initialState: [])

    init(trashDirectory: URL, failingPaths: Set<String> = []) {
        self.trashDirectory = trashDirectory
        self.failing = failingPaths
    }

    var trashedURLs: [URL] { calls.withLock { $0 } }

    func trashItem(at url: URL) throws -> URL? {
        calls.withLock { $0.append(url) }
        if failing.contains(url.path) { throw CocoaError(.fileWriteNoPermission) }
        let destination = trashDirectory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}
