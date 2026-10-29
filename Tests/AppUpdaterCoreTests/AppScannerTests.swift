import Testing
import Foundation
@testable import AppUpdaterCore

// MARK: - Fixtures

/// Runs `body` with a fresh temporary directory that is removed afterwards.
private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppScannerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

/// Creates `<directory>/<fileName>.app/Contents/Info.plist` with the given keys.
@discardableResult
private func makeApp(
    in directory: URL,
    fileName: String,
    info: [String: Any],
    masReceipt: Bool = false
) throws -> URL {
    let appURL = directory.appendingPathComponent("\(fileName).app", isDirectory: true)
    let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    if masReceipt {
        let receiptDir = contents.appendingPathComponent("_MASReceipt", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
        try Data("receipt".utf8).write(to: receiptDir.appendingPathComponent("receipt"))
    }
    return appURL
}

private func basicInfo(_ id: String, name: String, version: String = "1.0") -> [String: Any] {
    ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": version]
}

// MARK: - AppScanner

@Suite struct AppScannerTests {
    @Test func findsTopLevelAndNestedAppsSortedByName() async throws {
        try await withTemporaryDirectory { root in
            try makeApp(in: root, fileName: "Zeta", info: basicInfo("com.test.zeta", name: "Zeta"))
            let utilities = root.appendingPathComponent("Utilities", isDirectory: true)
            try makeApp(in: utilities, fileName: "Alpha", info: basicInfo("com.test.alpha", name: "Alpha"))
            let tooDeep = utilities.appendingPathComponent("Deeper", isDirectory: true)
            try makeApp(in: tooDeep, fileName: "Hidden", info: basicInfo("com.test.hidden", name: "Hidden"))

            let apps = try await AppScanner(searchDirectories: [root]).scan()

            #expect(apps.map(\.bundleIdentifier) == ["com.test.alpha", "com.test.zeta"])
        }
    }

    @Test func skipsInvalidBundles() async throws {
        try await withTemporaryDirectory { root in
            try makeApp(in: root, fileName: "Good", info: basicInfo("com.test.good", name: "Good"))
            try makeApp(in: root, fileName: "NoID", info: ["CFBundleShortVersionString": "1.0"])
            let noPlist = root.appendingPathComponent("Empty.app/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: noPlist, withIntermediateDirectories: true)

            let apps = try await AppScanner(searchDirectories: [root]).scan()

            #expect(apps.map(\.bundleIdentifier) == ["com.test.good"])
        }
    }

    @Test func dedupesByBundleIdentifierPreferringEarlierDirectory() async throws {
        try await withTemporaryDirectory { root in
            let first = root.appendingPathComponent("First", isDirectory: true)
            let second = root.appendingPathComponent("Second", isDirectory: true)
            try makeApp(in: first, fileName: "App", info: basicInfo("com.test.app", name: "App", version: "2.0"))
            try makeApp(in: second, fileName: "App", info: basicInfo("com.test.app", name: "App", version: "1.0"))

            let apps = try await AppScanner(searchDirectories: [first, second]).scan()

            #expect(apps.count == 1)
            #expect(apps.first?.shortVersion == "2.0")
        }
    }

    @Test func missingSearchDirectoryYieldsNoApps() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let apps = try await AppScanner(searchDirectories: [missing]).scan()
        #expect(apps.isEmpty)
    }
}

// MARK: - BundleInfoReader

@Suite struct BundleInfoReaderTests {
    let reader = BundleInfoReader()

    @Test func readsAllFields() async throws {
        try await withTemporaryDirectory { root in
            let info: [String: Any] = [
                "CFBundleIdentifier": "com.test.full",
                "CFBundleDisplayName": "Full Display",
                "CFBundleName": "Full",
                "CFBundleShortVersionString": "3.2.1",
                "CFBundleVersion": "321",
                "SUFeedURL": "https://example.com/appcast.xml",
            ]
            let url = try makeApp(in: root, fileName: "FullApp", info: info, masReceipt: true)

            let app = try reader.read(appAt: url)

            #expect(app.bundleIdentifier == "com.test.full")
            #expect(app.name == "Full Display")
            #expect(app.shortVersion == "3.2.1")
            #expect(app.buildVersion == "321")
            #expect(app.sparkleFeedURL == URL(string: "https://example.com/appcast.xml"))
            #expect(app.isFromAppStore)
            #expect(app.url == url)
        }
    }

    @Test func nameFallsBackToBundleNameThenFileName() async throws {
        try await withTemporaryDirectory { root in
            let named = try makeApp(in: root, fileName: "A", info: basicInfo("com.test.a", name: "Bundle Name"))
            let unnamed = try makeApp(
                in: root,
                fileName: "File Name",
                info: ["CFBundleIdentifier": "com.test.b", "CFBundleShortVersionString": "1"]
            )

            #expect(try reader.read(appAt: named).name == "Bundle Name")
            let fallback = try reader.read(appAt: unnamed)
            #expect(fallback.name == "File Name")
            #expect(fallback.sparkleFeedURL == nil)
            #expect(!fallback.isFromAppStore)
        }
    }

    @Test func throwsInvalidBundleWhenVersionMissing() async throws {
        try await withTemporaryDirectory { root in
            let url = try makeApp(in: root, fileName: "NoVersion", info: ["CFBundleIdentifier": "com.test.nv"])
            #expect(throws: UpdaterError.invalidBundle(url)) {
                try reader.read(appAt: url)
            }
        }
    }

    @Test func throwsInvalidBundleWhenPlistMissing() async throws {
        try await withTemporaryDirectory { root in
            let url = root.appendingPathComponent("Ghost.app", isDirectory: true)
            #expect(throws: UpdaterError.invalidBundle(url)) {
                try reader.read(appAt: url)
            }
        }
    }
}
