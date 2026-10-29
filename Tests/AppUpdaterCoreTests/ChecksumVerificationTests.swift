import CryptoKit
import Foundation
import Testing
@testable import AppUpdaterCore

/// Writes fixed bytes to a fresh temporary file for every download.
private struct PayloadHTTPClient: DownloadTransport {
    let payload: Data

    func download(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("sha512-\(UUID().uuidString)")
        try payload.write(to: fileURL)
        return fileURL
    }
}

@Suite("SHA-512 checksum verification")
struct ChecksumVerificationTests {
    private static let payload = Data("electron-archive".utf8)
    private static let sha512 = Data(SHA512.hash(data: payload))

    private static func makeUpdate(sha256: String? = nil) -> AvailableUpdate {
        AvailableUpdate(
            app: TestApps.make(bundleIdentifier: "com.acme.tool"),
            newVersion: "2.0", downloadURL: URL(string: "https://example.com/Tool-2.0-mac.zip")!,
            source: .electron, sha256: sha256
        )
    }

    private static func cleanUp(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    @Test("ExpectedChecksum decodes hex and base64 and rejects malformed values")
    func decoding() {
        let hex = Self.sha512.map { String(format: "%02x", $0) }.joined()
        #expect(ExpectedChecksum(algorithm: .sha512, value: hex.uppercased()).digestBytes == Self.sha512)
        #expect(ExpectedChecksum(algorithm: .sha512, value: Self.sha512.base64EncodedString()).digestBytes == Self.sha512)
        #expect(ExpectedChecksum(algorithm: .sha512, value: "not-a-digest").digestBytes == nil)
        #expect(ExpectedChecksum(algorithm: .sha256, value: Self.sha512.base64EncodedString()).digestBytes == nil)
        let plusHex = "+" + String(hex.dropFirst())
        #expect(ExpectedChecksum(algorithm: .sha512, value: plusHex).digestBytes == nil)
    }

    @Test("ProgressDownloader accepts a matching base64 SHA-512 from the ChecksumStore")
    func storeMatch() async throws {
        let update = Self.makeUpdate()
        let store = ChecksumStore()
        await store.register(ExpectedChecksum(algorithm: .sha512, value: Self.sha512.base64EncodedString()), forUpdateID: update.id)
        let downloader = ProgressDownloader(transport: PayloadHTTPClient(payload: Self.payload), checksum: store.lookup)

        let fileURL = try await downloader.download(update)
        defer { Self.cleanUp(fileURL) }
        #expect(try Data(contentsOf: fileURL) == Self.payload)
    }

    @Test("ProgressDownloader rejects a mismatching SHA-512")
    func storeMismatch() async throws {
        let update = Self.makeUpdate()
        let store = ChecksumStore()
        let wrong = Data(SHA512.hash(data: Data("other".utf8))).base64EncodedString()
        await store.register(ExpectedChecksum(algorithm: .sha512, value: wrong), forUpdateID: update.id)
        let downloader = ProgressDownloader(transport: PayloadHTTPClient(payload: Self.payload), checksum: store.lookup)

        await #expect(throws: UpdaterError.checksumMismatch) { try await downloader.download(update) }
    }

    @Test("a malformed expected digest is a mismatch, not a skip")
    func malformedDigest() async throws {
        let update = Self.makeUpdate()
        let downloader = ProgressDownloader(
            transport: PayloadHTTPClient(payload: Self.payload),
            checksum: { _ in ExpectedChecksum(algorithm: .sha512, value: "garbage") }
        )
        await #expect(throws: UpdaterError.checksumMismatch) { try await downloader.download(update) }
    }

    @Test("ChecksumStore lookup falls back to the update's sha256 field")
    func fallsBackToSHA256() async throws {
        let wrongSHA256 = String(repeating: "0", count: 64)
        let store = ChecksumStore()
        #expect(await store.lookup(Self.makeUpdate(sha256: wrongSHA256)) == ExpectedChecksum(algorithm: .sha256, value: wrongSHA256))
        #expect(await store.lookup(Self.makeUpdate()) == nil)

        let downloader = ProgressDownloader(transport: PayloadHTTPClient(payload: Self.payload), checksum: store.lookup)
        await #expect(throws: UpdaterError.checksumMismatch) {
            try await downloader.download(Self.makeUpdate(sha256: wrongSHA256))
        }
    }

    @Test("removeChecksum forgets the digest")
    func removal() async {
        let store = ChecksumStore()
        await store.register(ExpectedChecksum(algorithm: .sha512, value: "x"), forUpdateID: "a@1")
        await store.removeChecksum(forUpdateID: "a@1")
        #expect(await store.checksum(forUpdateID: "a@1") == nil)
    }

    @Test("DownloadVerifier hashes files with SHA-512")
    func digestOfFile() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("digest-\(UUID().uuidString)")
        try Self.payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        #expect(try DownloadVerifier.digest(of: fileURL, algorithm: .sha512) == Self.sha512)
    }
}
