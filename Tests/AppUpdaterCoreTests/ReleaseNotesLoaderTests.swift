import Foundation
import os
import Testing
@testable import AppUpdaterCore

@Suite("ReleaseNotesLoader")
struct ReleaseNotesLoaderTests {
    private let pageURL = URL(string: "https://example.com/notes/2.0.html")!

    @Test func inlineHTMLPassesThrough() async throws {
        let loader = ReleaseNotesLoader(httpClient: StubReleaseNotesHTTPClient())
        let content = try await loader.load(.html("<ul><li>Fix</li></ul>"))
        #expect(content == .html("<ul><li>Fix</li></ul>", baseURL: nil))
    }

    @Test func markdownPassesThrough() async throws {
        let loader = ReleaseNotesLoader(httpClient: StubReleaseNotesHTTPClient())
        #expect(try await loader.load(.markdown("## New\n- Thing")) == .markdown("## New\n- Thing"))
    }

    @Test func whitespaceOnlyIsEmpty() async throws {
        let loader = ReleaseNotesLoader(httpClient: StubReleaseNotesHTTPClient())
        #expect(try await loader.load(.html("  \n ")) == .empty)
        #expect(try await loader.load(.markdown("")) == .empty)
    }

    @Test func remoteHTMLIsFetchedWithBaseURL() async throws {
        let client = StubReleaseNotesHTTPClient(responses: [pageURL: Data("<p>Hi</p>".utf8)])
        let content = try await ReleaseNotesLoader(httpClient: client).load(.remote(pageURL))
        #expect(content == .html("<p>Hi</p>", baseURL: pageURL))
        #expect(client.requestedURLs == [pageURL])
    }

    @Test func remoteMarkdownAndTextAreClassifiedByExtension() async throws {
        let markdownURL = URL(string: "https://example.com/CHANGELOG.md")!
        let textURL = URL(string: "https://example.com/notes.txt")!
        let client = StubReleaseNotesHTTPClient(responses: [
            markdownURL: Data("# Changes".utf8),
            textURL: Data("Plain notes".utf8),
        ])
        let loader = ReleaseNotesLoader(httpClient: client)
        #expect(try await loader.load(.remote(markdownURL)) == .markdown("# Changes"))
        #expect(try await loader.load(.remote(textURL)) == .plainText("Plain notes"))
    }

    @Test(arguments: ["http://example.com/notes.html", "file:///etc/passwd", "ftp://example.com/n.html"])
    func nonHTTPSIsRejectedWithoutFetching(_ string: String) async throws {
        let url = try #require(URL(string: string))
        let client = StubReleaseNotesHTTPClient()
        await #expect(throws: ReleaseNotesError.insecureURL(url)) {
            try await ReleaseNotesLoader(httpClient: client).load(.remote(url))
        }
        #expect(client.requestedURLs.isEmpty)
    }

    @Test func oversizedResponseIsRejected() async {
        let client = StubReleaseNotesHTTPClient(responses: [pageURL: Data(repeating: 0x61, count: 101)])
        await #expect(throws: ReleaseNotesError.tooLarge(bytes: 101, limit: 100)) {
            try await ReleaseNotesLoader(httpClient: client, maxBytes: 100).load(.remote(pageURL))
        }
    }

    @Test func responseAtLimitIsAccepted() async throws {
        let client = StubReleaseNotesHTTPClient(responses: [pageURL: Data(repeating: 0x61, count: 100)])
        let content = try await ReleaseNotesLoader(httpClient: client, maxBytes: 100).load(.remote(pageURL))
        #expect(content == .html(String(repeating: "a", count: 100), baseURL: pageURL))
    }

    @Test func invalidUTF8IsRejected() async {
        let client = StubReleaseNotesHTTPClient(responses: [pageURL: Data([0x61, 0xC3, 0x28, 0x80])])
        await #expect(throws: ReleaseNotesError.invalidEncoding) {
            try await ReleaseNotesLoader(httpClient: client).load(.remote(pageURL))
        }
    }

    @Test func networkErrorsPropagate() async {
        let client = StubReleaseNotesHTTPClient()
        await #expect(throws: UpdaterError.self) {
            try await ReleaseNotesLoader(httpClient: client).load(.remote(pageURL))
        }
    }

    @Test func defaultLimitIsOneMegabyte() {
        #expect(ReleaseNotesLoader.defaultMaxBytes == 1_048_576)
    }
}

/// Minimal URL-keyed HTTP stub, private to this suite.
private final class StubReleaseNotesHTTPClient: HTTPClient {
    private let responses: [URL: Data]
    private let requests = OSAllocatedUnfairLock(initialState: [URL]())

    init(responses: [URL: Data] = [:]) {
        self.responses = responses
    }

    var requestedURLs: [URL] { requests.withLock { $0 } }

    func data(from url: URL) async throws -> Data {
        requests.withLock { $0.append(url) }
        guard let data = responses[url] else { throw UpdaterError.network("No stub for \(url.absoluteString)") }
        return data
    }

    func download(from url: URL) async throws -> URL {
        throw UpdaterError.network("Downloads are not stubbed")
    }
}
