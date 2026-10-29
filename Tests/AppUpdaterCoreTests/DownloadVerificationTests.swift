import CryptoKit
import Foundation
import Testing
@testable import AppUpdaterCore

/// Writes fixed bytes to a fresh temporary file for every download.
private struct StubDownloadHTTPClient: DownloadTransport {
    let payload: Data

    func download(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-\(UUID().uuidString)")
        try payload.write(to: fileURL)
        return fileURL
    }
}

@Suite("Download verification", .serialized)
struct DownloadVerificationTests {
    private static let payload = Data("fake-archive-contents".utf8)

    private static func makeUpdate(
        url: String = "https://example.com/Foo-2.0.zip",
        sha256: String? = nil,
        edSignature: String? = nil
    ) -> AvailableUpdate {
        let app = InstalledApp(
            bundleIdentifier: "com.example.foo", name: "Foo",
            url: URL(fileURLWithPath: "/Applications/Foo.app"),
            shortVersion: "1.0", buildVersion: nil, sparkleFeedURL: nil, isFromAppStore: false
        )
        return AvailableUpdate(
            app: app, newVersion: "2.0", downloadURL: URL(string: url)!,
            source: .sparkle, edSignature: edSignature, sha256: sha256
        )
    }

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private let downloader = ProgressDownloader(transport: StubDownloadHTTPClient(payload: payload))

    @Test("accepts a download whose checksum matches")
    func checksumMatches() async throws {
        let update = Self.makeUpdate(sha256: Self.hex(Self.payload).uppercased())
        let fileURL = try await downloader.download(update)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        #expect(fileURL.lastPathComponent == "Foo-2.0.zip")
        #expect(try Data(contentsOf: fileURL) == Self.payload)
    }

    @Test("throws checksumMismatch and leaves no file behind")
    func checksumMismatch() async throws {
        let update = Self.makeUpdate(sha256: String(repeating: "0", count: 64))
        let before = try Self.downloadDirectories()

        await #expect(throws: UpdaterError.checksumMismatch) {
            try await downloader.download(update)
        }
        #expect(try Self.downloadDirectories() == before)
    }

    @Test("rejects non-HTTPS URLs", arguments: ["http://example.com/Foo.zip", "file:///tmp/Foo.zip"])
    func rejectsInsecureScheme(url: String) async {
        await #expect(throws: UpdaterError.self) {
            try await downloader.download(Self.makeUpdate(url: url))
        }
    }

    @Test("verifies EdDSA signature when a public key is available")
    func edSignatureValid() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: Self.payload).base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let signed = ProgressDownloader(
            transport: StubDownloadHTTPClient(payload: Self.payload),
            publicEDKey: { _ in publicKey }
        )

        let fileURL = try await signed.download(Self.makeUpdate(edSignature: signature))
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    @Test("rejects an EdDSA signature from a different key")
    func edSignatureInvalid() async throws {
        let signature = try Curve25519.Signing.PrivateKey().signature(for: Self.payload).base64EncodedString()
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let signed = ProgressDownloader(
            transport: StubDownloadHTTPClient(payload: Self.payload),
            publicEDKey: { _ in otherKey }
        )

        await #expect(throws: UpdaterError.self) {
            try await signed.download(Self.makeUpdate(edSignature: signature))
        }
    }

    private static func downloadDirectories() throws -> Set<String> {
        let entries = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        return Set(entries.filter { $0.hasPrefix("AppUpdater-") })
    }
}
