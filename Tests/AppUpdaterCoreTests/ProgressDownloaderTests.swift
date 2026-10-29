import CryptoKit
import Foundation
import os
import Testing
@testable import AppUpdaterCore

/// Writes the payload to a temp file and reports two progress steps.
private struct StubTransport: DownloadTransport {
    let payload: Data

    func download(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        progress(0.5)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("stub-\(UUID().uuidString)")
        try payload.write(to: fileURL)
        return fileURL
    }
}

/// Never finishes on its own; only Task cancellation ends it.
private struct HangingTransport: DownloadTransport {
    func download(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await Task.sleep(for: .seconds(60))
        throw UpdaterError.network("should have been cancelled")
    }
}

/// Serves canned HTTPS responses without the network. Path decides the behaviour.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let payload = Data(repeating: 0xAB, count: 256 * 1024)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        switch url.path {
        case "/hang":
            return
        case "/missing":
            respond(status: 404, body: Data())
        default:
            respond(status: 200, body: Self.payload)
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, body: Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(body.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk = 64 * 1024
        stride(from: 0, to: body.count, by: chunk).forEach { start in
            client?.urlProtocol(self, didLoad: body.subdata(in: start..<min(start + chunk, body.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class ProgressLog: Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [Double]())
    var all: [Double] { values.withLock { $0 } }
    func append(_ value: Double) { values.withLock { $0.append(value) } }
}

@Suite("ProgressDownloader")
struct ProgressDownloaderTests {
    private static let payload = Data("progress-archive".utf8)

    private static func makeUpdate(
        url: String = "https://example.com/Foo-2.0.zip", sha256: String? = nil, edSignature: String? = nil
    ) -> AvailableUpdate {
        AvailableUpdate(
            app: TestApps.make(bundleIdentifier: "com.example.foo", name: "Foo", fileName: "Foo.app"),
            newVersion: "2.0", downloadURL: URL(string: url)!, source: .sparkle,
            edSignature: edSignature, sha256: sha256
        )
    }

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func stubSession() -> URLSessionDownloadTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSessionDownloadTransport(configuration: configuration)
    }

    private static func remove(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    @Test("verifies checksum, names the file and reports completion")
    func verifiesAndReportsProgress() async throws {
        let log = ProgressLog()
        let downloader = ProgressDownloader(transport: StubTransport(payload: Self.payload))

        let fileURL = try await downloader.download(Self.makeUpdate(sha256: Self.hex(Self.payload))) { log.append($0) }
        defer { Self.remove(fileURL) }

        #expect(fileURL.lastPathComponent == "Foo-2.0.zip")
        #expect(try Data(contentsOf: fileURL) == Self.payload)
        #expect(log.all == [0.5, 1])
    }

    @Test("throws checksumMismatch through the shared verifier")
    func checksumMismatch() async {
        let downloader = ProgressDownloader(transport: StubTransport(payload: Self.payload))
        await #expect(throws: UpdaterError.checksumMismatch) {
            try await downloader.download(Self.makeUpdate(sha256: String(repeating: "0", count: 64))) { _ in }
        }
    }

    @Test("rejects an EdDSA signature from another key")
    func edSignatureInvalid() async throws {
        let signature = try Curve25519.Signing.PrivateKey().signature(for: Self.payload).base64EncodedString()
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let downloader = ProgressDownloader(transport: StubTransport(payload: Self.payload), publicEDKey: { _ in otherKey })

        await #expect(throws: UpdaterError.self) {
            try await downloader.download(Self.makeUpdate(edSignature: signature))
        }
    }

    @Test("rejects non-HTTPS URLs", arguments: ["http://example.com/Foo.zip", "file:///tmp/Foo.zip"])
    func rejectsInsecureScheme(url: String) async {
        let downloader = ProgressDownloader(transport: StubTransport(payload: Self.payload))
        await #expect(throws: UpdaterError.self) {
            try await downloader.download(Self.makeUpdate(url: url)) { _ in }
        }
    }

    @Test("Task cancellation stops a pending transfer")
    func cancellationThroughSeam() async {
        let downloader = ProgressDownloader(transport: HangingTransport())
        let task = Task { try await downloader.download(Self.makeUpdate()) { _ in } }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("URLSession transport downloads with fractional progress")
    func urlSessionTransportProgress() async throws {
        let log = ProgressLog()
        let downloader = ProgressDownloader(transport: Self.stubSession())

        let fileURL = try await downloader.download(Self.makeUpdate(sha256: Self.hex(StubURLProtocol.payload))) {
            log.append($0)
        }
        defer { Self.remove(fileURL) }

        #expect(try Data(contentsOf: fileURL) == StubURLProtocol.payload)
        #expect(log.all.last == 1)
        #expect(log.all == log.all.sorted())
    }

    @Test("URLSession transport maps HTTP errors")
    func urlSessionTransportHTTPError() async {
        let downloader = ProgressDownloader(transport: Self.stubSession())
        await #expect(throws: UpdaterError.network("HTTP 404 for https://example.com/missing")) {
            try await downloader.download(Self.makeUpdate(url: "https://example.com/missing"))
        }
    }

    @Test("cancelling the Task cancels the URLSessionDownloadTask")
    func urlSessionTransportCancellation() async throws {
        let downloader = ProgressDownloader(transport: Self.stubSession())
        let task = Task { try await downloader.download(Self.makeUpdate(url: "https://example.com/hang")) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
