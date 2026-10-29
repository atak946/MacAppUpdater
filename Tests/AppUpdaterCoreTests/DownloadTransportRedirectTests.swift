import Foundation
import Testing
@testable import AppUpdaterCore

/// Redirects and failures for the URLSession download transport. Path decides the behaviour.
final class RedirectStubProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data("payload".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        switch url.path {
        case "/to-http":
            redirect(to: "http://downgrade.example.com/final")
        case "/to-https":
            redirect(to: "https://cdn.example.com/final")
        case "/fail":
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        default:
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": "\(Self.body.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func redirect(to target: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": target])!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
    }
}

@Suite("URLSessionDownloadTransport redirects")
struct DownloadTransportRedirectTests {
    private static func transport() -> URLSessionDownloadTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStubProtocol.self]
        return URLSessionDownloadTransport(configuration: configuration)
    }

    @Test("refuses a redirect that downgrades to plain HTTP")
    func refusesHTTPRedirect() async {
        await #expect(throws: UpdaterError.network("Refusing non-HTTPS redirect")) {
            try await Self.transport().download(from: URL(string: "https://example.com/to-http")!) { _ in }
        }
    }

    @Test("follows HTTPS-to-HTTPS redirects")
    func followsHTTPSRedirect() async throws {
        let file = try await Self.transport().download(from: URL(string: "https://example.com/to-https")!) { _ in }
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(try Data(contentsOf: file) == RedirectStubProtocol.body)
        #expect(file.lastPathComponent.hasPrefix("AppUpdaterDownload-"))
    }

    @Test("transport errors become UpdaterError.network")
    func mapsTransportErrors() async {
        do {
            _ = try await Self.transport().download(from: URL(string: "https://example.com/fail")!) { _ in }
            Issue.record("Expected a failure")
        } catch let error as UpdaterError {
            guard case .network = error else { Issue.record("Unexpected \(error)"); return }
        } catch {
            Issue.record("Expected UpdaterError, got \(error)")
        }
    }
}
