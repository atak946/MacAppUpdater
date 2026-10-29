import Foundation
import Testing
@testable import AppUpdaterCore

/// Returns a team for listed bundle paths (by last path component) and throws for the rest.
struct BundleTeamStubVerifier: SignatureVerifying {
    let teams: [String: String]

    func teamIdentifier(of bundleURL: URL) async throws -> String {
        guard let team = teams[bundleURL.lastPathComponent] else {
            throw UpdaterError.signatureInvalid("unsigned fixture")
        }
        return team
    }
}

struct FixedDuplicateFinder: DuplicateBundleFinding {
    let bundles: [URL]
    func bundles(withIdentifier bundleIdentifier: String) async -> [URL] { bundles }
}

@discardableResult
private func makeBundle(in directory: URL, fileName: String, id: String, version: String) throws -> URL {
    let appURL = directory.appendingPathComponent("\(fileName).app", isDirectory: true)
    let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": fileName, "CFBundleShortVersionString": version]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    return appURL
}

private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("HygieneWave2Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

// MARK: - L-10

@Suite struct AppStoreBundleIDMatchTests {
    private let lookup = URL(string: "https://itunes.apple.com/lookup?bundleId=com.example.mas&entity=macSoftware")!

    private func source(_ json: String) -> AppStoreSource {
        AppStoreSource(http: MockHTTPClient(strings: [lookup.absoluteString: json]), comparator: NumericStubComparator())
    }

    private var app: InstalledApp {
        TestApps.make(bundleIdentifier: "com.example.mas", shortVersion: "1.0", isFromAppStore: true)
    }

    @Test("a result without bundleId is not trusted")
    func missingBundleIDIsNotFound() async throws {
        let json = #"{"results":[{"version":"9.0","trackViewUrl":"https://apps.apple.com/app/id1"}]}"#
        #expect(try await source(json).lookup(app) == .notFound)
    }

    @Test("a result for a different bundleId is not trusted")
    func otherBundleIDIsNotFound() async throws {
        let json = #"{"results":[{"version":"9.0","bundleId":"com.evil","trackViewUrl":"https://apps.apple.com/app/id1"}]}"#
        #expect(try await source(json).lookup(app) == .notFound)
    }

    @Test("the matching result is picked even when it is not first")
    func matchingResultIsPicked() async throws {
        let json = #"""
        {"results":[{"version":"9.0","bundleId":"com.evil","trackViewUrl":"https://apps.apple.com/app/id9"},
        {"version":"2.0","bundleId":"com.example.mas","trackViewUrl":"https://apps.apple.com/app/id1"}]}
        """#
        #expect(try await source(json).lookup(app).update?.newVersion == "2.0")
    }
}

// MARK: - L-11 scanner

@Suite struct AppScannerDuplicateTests {
    @Test("a validly signed later bundle beats an unsigned earlier one, and duplicates are recorded")
    func prefersSignedBundle() async throws {
        try await withTemporaryDirectory { root in
            let first = root.appendingPathComponent("First", isDirectory: true)
            let second = root.appendingPathComponent("Second", isDirectory: true)
            let fake = try makeBundle(in: first, fileName: "Fake", id: "com.test.app", version: "9.0")
            let real = try makeBundle(in: second, fileName: "Real", id: "com.test.app", version: "1.0")
            let scanner = AppScanner(
                searchDirectories: [first, second], signatureVerifier: BundleTeamStubVerifier(teams: ["Real.app": "TEAM1"])
            )

            let result = try await scanner.scanResult()

            #expect(result.apps.map(\.url.lastPathComponent) == ["Real.app"])
            #expect(result.duplicates["com.test.app"]?.map(\.lastPathComponent) == [fake.lastPathComponent])
            #expect(try await scanner.scan().first?.url.lastPathComponent == real.lastPathComponent)
        }
    }

    @Test("when nothing is validly signed the earlier directory wins")
    func earlierWinsWhenNoneSigned() async throws {
        try await withTemporaryDirectory { root in
            let first = root.appendingPathComponent("First", isDirectory: true)
            let second = root.appendingPathComponent("Second", isDirectory: true)
            try makeBundle(in: first, fileName: "A", id: "com.test.app", version: "2.0")
            try makeBundle(in: second, fileName: "B", id: "com.test.app", version: "1.0")
            try makeBundle(in: second, fileName: "Solo", id: "com.test.solo", version: "1.0")
            let scanner = AppScanner(searchDirectories: [first, second], signatureVerifier: BundleTeamStubVerifier(teams: [:]))

            let result = try await scanner.scanResult()

            #expect(result.apps.first { $0.bundleIdentifier == "com.test.app" }?.shortVersion == "2.0")
            #expect(result.duplicates.keys.sorted() == ["com.test.app"])
            #expect(await scanner.bundles(withIdentifier: "com.test.app").count == 2)
        }
    }
}

// MARK: - L-11 uninstaller

@Suite struct UninstallIntegrityTests {
    @Test("the plan carries the team ID and no warnings for a signed unique bundle")
    func signedUniqueBundle() async throws {
        try await UninstallSandbox.run { box in
            let app = try box.makeApp(id: "com.foo.app", name: "Foo")
            let cache = try box.make("Caches/com.foo.app")
            let sut = AppUninstaller(
                scanner: box.scanner, runningChecker: FakeRunningChecker(running: []),
                trasher: RecordingTrasher(trashDirectory: box.trash), protectedBundleIdentifiers: [],
                signatureVerifier: BundleTeamStubVerifier(teams: ["Foo.app": "TEAM1"]),
                duplicateFinder: FixedDuplicateFinder(bundles: [app.url])
            )

            let plan = try await sut.scan(app)

            #expect(plan.integrity.teamIdentifier == "TEAM1")
            #expect(plan.integrity.signatureProblem == nil)
            #expect(!plan.integrity.hasDuplicates)
            #expect(Set(plan.defaultSelection.map(\.path)).contains(cache.path))
        }
    }

    @Test("an unsigned bundle with a look-alike elsewhere is flagged and only the bundle is preselected")
    func unsignedDuplicateBundle() async throws {
        try await UninstallSandbox.run { box in
            let app = try box.makeApp(id: "com.foo.app", name: "Foo")
            try box.make("Caches/com.foo.app")
            let other = box.outside.appendingPathComponent("Foo.app", isDirectory: true)
            let sut = AppUninstaller(
                scanner: box.scanner, runningChecker: FakeRunningChecker(running: []),
                trasher: RecordingTrasher(trashDirectory: box.trash), protectedBundleIdentifiers: [],
                signatureVerifier: BundleTeamStubVerifier(teams: [:]),
                duplicateFinder: FixedDuplicateFinder(bundles: [app.url, other])
            )

            let plan = try await sut.scan(app)

            #expect(plan.integrity.teamIdentifier == nil)
            #expect(plan.integrity.signatureProblem != nil)
            #expect(plan.integrity.duplicateBundles == [other])
            #expect(plan.defaultSelection == [plan.bundle.url])
        }
    }

    @Test("the organization gate error has a user-facing message")
    func disabledByOrganizationMessage() {
        #expect(UninstallError.disabledByOrganization.errorDescription?.isEmpty == false)
    }
}
