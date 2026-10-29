import Foundation

/// HTTP client that can send custom headers (e.g. `Authorization` for the GitHub API).
/// Kept separate from the frozen `HTTPClient` protocol; sources probe for it at runtime.
public protocol HTTPRequestClient: Sendable {
    /// Performs a GET with the given extra headers and returns the body of a 2xx response.
    func data(from url: URL, headers: [String: String]) async throws -> Data
}

/// HTTP client that stops reading a response once it exceeds a byte limit, so a hostile
/// feed can't exhaust memory. Like `HTTPRequestClient`, sources probe for it at runtime.
public protocol BoundedHTTPClient: Sendable {
    /// GET that fails with `UpdaterError.network("Response too large")` beyond `maxBytes`.
    func data(from url: URL, maxBytes: Int) async throws -> Data
    /// GET with extra headers, bounded like `data(from:maxBytes:)`.
    func data(from url: URL, headers: [String: String], maxBytes: Int) async throws -> Data
}

/// Per-call-site response size limits (bytes).
public enum HTTPFetchLimit {
    /// Sparkle appcasts, vendor feeds, GitHub/App Store JSON, electron-builder YAML.
    public static let feed = 8 * 1024 * 1024
    /// Homebrew's full `cask.json` index (~10–20 MB today).
    public static let caskIndex = 64 * 1024 * 1024
    /// Remote release-notes pages.
    public static let releaseNotes = 1024 * 1024
    /// Applied by `URLSessionHTTPClient.data(from:)` when the caller passes no limit.
    public static let `default` = feed

    static let tooLargeMessage = "Response too large"

    static var tooLarge: UpdaterError { .network(tooLargeMessage) }
}

extension HTTPClient {
    /// Fetches `url` with a size limit: streamed when the client is a `BoundedHTTPClient`,
    /// otherwise (test doubles) fully buffered and checked afterwards.
    public func data(from url: URL, maxBytes: Int) async throws -> Data {
        if let bounded = self as? any BoundedHTTPClient {
            return try await bounded.data(from: url, maxBytes: maxBytes)
        }
        let data = try await data(from: url)
        guard data.count <= maxBytes else { throw HTTPFetchLimit.tooLarge }
        return data
    }

    /// Like `data(from:maxBytes:)`, sending `headers` when the client supports them.
    public func data(from url: URL, headers: [String: String], maxBytes: Int) async throws -> Data {
        if let bounded = self as? any BoundedHTTPClient {
            return try await bounded.data(from: url, headers: headers, maxBytes: maxBytes)
        }
        guard let requestClient = self as? any HTTPRequestClient else {
            return try await data(from: url, maxBytes: maxBytes)
        }
        let data = try await requestClient.data(from: url, headers: headers)
        guard data.count <= maxBytes else { throw HTTPFetchLimit.tooLarge }
        return data
    }
}
