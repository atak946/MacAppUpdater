import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("AppDetailsReader")
struct AppDetailsReaderTests {
    private struct StubVerifier: SignatureVerifying {
        let result: Result<String, UpdaterError>
        func teamIdentifier(of bundleURL: URL) async throws -> String { try result.get() }
    }

    private func makeApp(info: [String: Any], payloadBytes: Int = 0) throws -> (InstalledApp, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDetailsReaderTests-\(UUID().uuidString)", isDirectory: true)
        let contents = root.appendingPathComponent("Demo.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if payloadBytes > 0 {
            try Data(count: payloadBytes).write(to: contents.appendingPathComponent("payload.bin"))
        }
        let app = InstalledApp(
            bundleIdentifier: "com.example.demo",
            name: "Demo",
            url: root.appendingPathComponent("Demo.app"),
            shortVersion: "1.0",
            buildVersion: nil,
            sparkleFeedURL: nil,
            isFromAppStore: false
        )
        return (app, root)
    }

    @Test func readsInfoPlistExtrasAndSignature() async throws {
        let (app, root) = try makeApp(info: [
            "CFBundleIdentifier": "com.example.demo",
            "LSMinimumSystemVersion": "13.0",
            "NSHumanReadableCopyright": "© Example",
            "LSApplicationCategoryType": "public.app-category.developer-tools",
        ], payloadBytes: 64 * 1024)
        defer { try? FileManager.default.removeItem(at: root) }

        let details = await AppDetailsReader(verifier: StubVerifier(result: .success("TEAM123"))).details(for: app)

        #expect(details.minimumSystemVersion == "13.0")
        #expect(details.copyright == "© Example")
        #expect(details.category == "Developer Tools")
        #expect(details.signature == .signed(teamIdentifier: "TEAM123"))
        #expect((details.sizeInBytes ?? 0) >= 64 * 1024)
        #expect(details.modifiedAt != nil)
    }

    @Test func reportsUnsignedWhenVerifierThrows() async throws {
        let (app, root) = try makeApp(info: ["CFBundleIdentifier": "com.example.demo"])
        defer { try? FileManager.default.removeItem(at: root) }

        let details = await AppDetailsReader(
            verifier: StubVerifier(result: .failure(.signatureInvalid("not signed")))
        ).details(for: app)

        guard case .unsigned = details.signature else {
            Issue.record("Expected unsigned, got \(details.signature)")
            return
        }
        #expect(details.minimumSystemVersion == nil)
    }

    @Test("Category names", arguments: [
        ("public.app-category.developer-tools", "Developer Tools"),
        ("public.app-category.productivity", "Productivity"),
    ])
    func categoryName(identifier: String, expected: String) {
        #expect(AppDetailsReader.categoryName(identifier) == expected)
    }
}
