import Foundation
import Testing
@testable import AppUpdaterCore

/// Canned responses for `URLSessionHTTPClient` without the network. The path decides the behaviour.
final class HTTPClientStubProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data("hello".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        switch url.path {
        case "/echo-headers":
            let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            let custom = request.value(forHTTPHeaderField: "X-Test") ?? ""
            respond(status: 200, body: Data("\(agent)|\(custom)".utf8))
        case "/missing":
            respond(status: 404, body: Data())
        case "/server-error":
            respond(status: 503, body: Data())
        case "/fail":
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case "/non-http":
            let response = URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 2, textEncodingName: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("hi".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case "/big":
            respond(status: 200, body: Data(repeating: 0x61, count: 100))
        case "/big-chunked":
            // No Content-Length: the limit must be enforced while streaming.
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for _ in 0..<10 { client?.urlProtocol(self, didLoad: Data(repeating: 0x62, count: 10)) }
            client?.urlProtocolDidFinishLoading(self)
        case "/echo-auth":
            respond(status: 200, body: Data((request.value(forHTTPHeaderField: "Authorization") ?? "<none>").utf8))
        case "/redirect-same":
            redirect(to: "https://stub.example.com/echo-auth")
        case "/redirect-cross":
            redirect(to: "https://other.example.net/echo-auth")
        case "/redirect-http":
            redirect(to: "http://stub.example.com/echo-auth")
        case "/download":
            respond(status: 200, body: Self.body, headers: ["Content-Disposition": "attachment; filename=\"Foo-2.0.dmg\""])
        default:
            respond(status: 200, body: Self.body)
        }
    }

    private func redirect(to location: String) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location]
        )!
        var next = request
        next.url = URL(string: location)
        client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func respond(status: Int, body: Data, headers: [String: String] = [:]) {
        let fields = headers.merging(["Content-Length": "\(body.count)"]) { current, _ in current }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("URLSessionHTTPClient")
struct URLSessionHTTPClientTests {
    private func makeClient() -> URLSessionHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPClientStubProtocol.self]
        return URLSessionHTTPClient(session: URLSessionHTTPClient.makeSession(configuration: configuration))
    }

    private static func url(_ path: String) -> URL {
        URL(string: "https://stub.example.com\(path)")!
    }

    @Test("data(from:) returns the body of a 2xx response")
    func dataReturnsBody() async throws {
        let data = try await makeClient().data(from: Self.url("/ok"))

        #expect(data == HTTPClientStubProtocol.body)
    }

    @Test("sends the MacAppUpdater User-Agent and custom headers")
    func sendsHeaders() async throws {
        let data = try await makeClient().data(from: Self.url("/echo-headers"), headers: ["X-Test": "42"])

        #expect(String(decoding: data, as: UTF8.self) == "MacAppUpdater/1.0|42")
    }

    @Test("non-2xx status codes become UpdaterError.network with the status", arguments: [
        ("/missing", 404), ("/server-error", 503),
    ])
    func rejectsErrorStatus(path: String, status: Int) async {
        let url = Self.url(path)
        await #expect(throws: UpdaterError.network("HTTP \(status) from \(url.absoluteString)")) {
            try await makeClient().data(from: url)
        }
        await #expect(throws: UpdaterError.network("HTTP \(status) from \(url.absoluteString)")) {
            try await makeClient().data(from: url, headers: [:])
        }
    }

    @Test("transport failures are wrapped in UpdaterError.network")
    func wrapsTransportErrors() async {
        let client = makeClient()

        for operation in [0, 1] {
            do {
                switch operation {
                case 0: _ = try await client.data(from: Self.url("/fail"))
                default: _ = try await client.data(from: Self.url("/fail"), headers: ["A": "b"])
                }
                Issue.record("Expected a network error")
            } catch let error as UpdaterError {
                guard case .network = error else { Issue.record("Unexpected \(error)"); continue }
            } catch {
                Issue.record("Expected UpdaterError, got \(error)")
            }
        }
    }
}

@Suite("URLSessionHTTPClient limits and redirects")
struct URLSessionHTTPClientHardeningTests {
    private func makeClient() -> URLSessionHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPClientStubProtocol.self]
        return URLSessionHTTPClient(session: URLSessionHTTPClient.makeSession(configuration: configuration))
    }

    private static func url(_ path: String) -> URL {
        URL(string: "https://stub.example.com\(path)")!
    }

    @Test("a declared Content-Length above the limit is rejected", arguments: ["/big", "/big-chunked"])
    func rejectsOversizedBodies(path: String) async {
        await #expect(throws: UpdaterError.network("Response too large")) {
            try await makeClient().data(from: Self.url(path), maxBytes: 10)
        }
        await #expect(throws: UpdaterError.network("Response too large")) {
            try await makeClient().data(from: Self.url(path), headers: ["X": "y"], maxBytes: 99)
        }
    }

    @Test("a body exactly at the limit is returned", arguments: ["/big", "/big-chunked"])
    func acceptsBodyAtLimit(path: String) async throws {
        let data = try await makeClient().data(from: Self.url(path), maxBytes: 100)
        #expect(data.count == 100)
    }

    @Test("the unbounded protocol methods use the default limit")
    func defaultLimitApplies() async throws {
        let data = try await makeClient().data(from: Self.url("/big"))
        #expect(data.count == 100)
        #expect(HTTPFetchLimit.default == HTTPFetchLimit.feed)
    }

    @Test("Authorization is kept on a same-host redirect")
    func keepsAuthorizationOnSameHost() async throws {
        let data = try await makeClient().data(from: Self.url("/redirect-same"), headers: ["Authorization": "Bearer t0k"])
        #expect(String(decoding: data, as: UTF8.self) == "Bearer t0k")
    }

    @Test("Authorization is stripped on a cross-host redirect")
    func stripsAuthorizationAcrossHosts() async throws {
        let data = try await makeClient().data(from: Self.url("/redirect-cross"), headers: ["Authorization": "Bearer t0k"])
        #expect(String(decoding: data, as: UTF8.self) == "<none>")
    }

    @Test("a redirect to http is refused and surfaces as the 3xx status")
    func refusesInsecureRedirect() async {
        let url = Self.url("/redirect-http")
        await #expect(throws: UpdaterError.network("HTTP 302 from \(url.absoluteString)")) {
            try await makeClient().data(from: url)
        }
    }
}

@Suite("HTTPRedirectPolicy")
struct HTTPRedirectPolicyTests {
    private static let original = URL(string: "https://api.github.com/repos/a/b/releases/latest")!

    private static func request(_ string: String, token: String? = "Bearer x") -> URLRequest {
        var request = URLRequest(url: URL(string: string)!)
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "X-Other")
        return request
    }

    @Test("non-https redirects are refused", arguments: ["http://api.github.com/x", "ftp://api.github.com/x", "file:///etc/passwd"])
    func refusesNonHTTPS(target: String) {
        #expect(HTTPRedirectPolicy.redirectedRequest(Self.request(target), originalURL: Self.original) == nil)
    }

    @Test("same host (case-insensitive) keeps every header")
    func sameHostKeepsHeaders() throws {
        let result = try #require(
            HTTPRedirectPolicy.redirectedRequest(Self.request("https://API.github.com/y"), originalURL: Self.original)
        )
        #expect(result.value(forHTTPHeaderField: "Authorization") == "Bearer x")
    }

    @Test("another host loses Authorization only", arguments: [
        "https://objects.githubusercontent.com/z", "https://github.com.evil.example/z",
    ])
    func crossHostStripsAuthorization(target: String) throws {
        let result = try #require(HTTPRedirectPolicy.redirectedRequest(Self.request(target), originalURL: Self.original))
        #expect(result.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(result.value(forHTTPHeaderField: "X-Other") == "1")
    }

    @Test("an unknown original host is treated as cross-host")
    func missingOriginalStrips() throws {
        let result = try #require(HTTPRedirectPolicy.redirectedRequest(Self.request("https://api.github.com/y"), originalURL: nil))
        #expect(result.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

/// Records the limit each source asks for; answers every URL with `body`.
private final class LimitRecordingClient: HTTPClient, BoundedHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var limits: [Int] = []
    let body: Data

    init(body: Data) { self.body = body }

    var recordedLimits: [Int] { lock.withLock { limits } }

    func data(from url: URL) async throws -> Data {
        Issue.record("unbounded fetch of \(url)")
        return body
    }

    func download(from url: URL) async throws -> URL { throw UpdaterError.network("unused") }

    func data(from url: URL, maxBytes: Int) async throws -> Data {
        lock.withLock { limits.append(maxBytes) }
        return body
    }

    func data(from url: URL, headers: [String: String], maxBytes: Int) async throws -> Data {
        try await data(from: url, maxBytes: maxBytes)
    }
}

@Suite("Per-source fetch limits")
struct SourceFetchLimitTests {
    @Test("GitHub and Sparkle cap at 8 MB, the Homebrew index at 64 MB")
    func limitsPerSource() async throws {
        let github = LimitRecordingClient(body: Data(#"{"tag_name":"v1.0","draft":false,"prerelease":false,"assets":[]}"#.utf8))
        _ = try await GitHubReleasesSource(
            repositories: ["com.example.app": "o/r"], http: github, comparator: NumericStubComparator()
        ).lookup(TestApps.make())
        #expect(github.recordedLimits == [8 * 1024 * 1024])

        let sparkle = LimitRecordingClient(body: Data("<rss><channel></channel></rss>".utf8))
        _ = try await SparkleSource(http: sparkle, comparator: NumericStubComparator())
            .lookup(TestApps.make(sparkleFeedURL: URL(string: "https://example.com/appcast.xml")))
        #expect(sparkle.recordedLimits == [HTTPFetchLimit.feed])

        let homebrew = LimitRecordingClient(body: Data("[]".utf8))
        _ = try await HomebrewCaskSource(http: homebrew, comparator: NumericStubComparator()).lookup(TestApps.make())
        #expect(homebrew.recordedLimits == [64 * 1024 * 1024])
    }

    @Test("clients without streaming support are checked after the fetch")
    func fallbackChecksSize() async throws {
        let url = URL(string: "https://example.com/feed")!
        let client: any HTTPClient = MockHTTPClient(responses: [url: Data(repeating: 1, count: 11)])
        await #expect(throws: UpdaterError.network("Response too large")) {
            try await client.data(from: url, maxBytes: 10)
        }
        await #expect(throws: UpdaterError.network("Response too large")) {
            try await client.data(from: url, headers: ["A": "b"], maxBytes: 10)
        }
        #expect(try await client.data(from: url, maxBytes: 11).count == 11)
    }
}
