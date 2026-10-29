import Foundation
import os
@testable import AppUpdaterCore

/// In-memory `HTTPClient` keyed by URL. Unknown URLs throw `UpdaterError.network`.
final class MockHTTPClient: HTTPClient {
    private struct State {
        var requests: [URL] = []
        var headers: [URL: [String: String]] = [:]
    }

    private let responses: [URL: Data]
    private let downloads: [URL: URL]
    private let failures: [URL: UpdaterError]
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        responses: [URL: Data] = [:],
        downloads: [URL: URL] = [:],
        failures: [URL: UpdaterError] = [:]
    ) {
        self.responses = responses
        self.downloads = downloads
        self.failures = failures
    }

    convenience init(strings: [String: String]) {
        let pairs = strings.compactMap { key, value in URL(string: key).map { ($0, Data(value.utf8)) } }
        self.init(responses: Dictionary(uniqueKeysWithValues: pairs))
    }

    var requestedURLs: [URL] {
        state.withLock { $0.requests }
    }

    func headers(for url: URL) -> [String: String]? {
        state.withLock { $0.headers[url] }
    }

    func requestCount(for url: URL) -> Int {
        requestedURLs.filter { $0 == url }.count
    }

    func data(from url: URL) async throws -> Data {
        record(url)
        if let failure = failures[url] { throw failure }
        guard let data = responses[url] else {
            throw UpdaterError.network("No stubbed response for \(url.absoluteString)")
        }
        return data
    }

    func download(from url: URL) async throws -> URL {
        record(url)
        if let failure = failures[url] { throw failure }
        guard let file = downloads[url] else {
            throw UpdaterError.network("No stubbed download for \(url.absoluteString)")
        }
        return file
    }

    private func record(_ url: URL) {
        state.withLock { $0.requests.append(url) }
    }
}

extension MockHTTPClient: HTTPRequestClient {
    func data(from url: URL, headers: [String: String]) async throws -> Data {
        state.withLock { $0.headers[url] = headers }
        return try await data(from: url)
    }
}

/// Minimal dotted-numeric comparator so source tests don't depend on `VersionComparator`.
struct NumericStubComparator: VersionComparing {
    func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = Self.components(candidate)
        let rhs = Self.components(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}

enum TestApps {
    static func make(
        bundleIdentifier: String = "com.example.app",
        name: String = "Example",
        fileName: String = "Example.app",
        shortVersion: String = "1.0",
        buildVersion: String? = nil,
        sparkleFeedURL: URL? = nil,
        isFromAppStore: Bool = false
    ) -> InstalledApp {
        InstalledApp(
            bundleIdentifier: bundleIdentifier,
            name: name,
            url: URL(fileURLWithPath: "/Applications/\(fileName)"),
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            sparkleFeedURL: sparkleFeedURL,
            isFromAppStore: isFromAppStore
        )
    }
}
