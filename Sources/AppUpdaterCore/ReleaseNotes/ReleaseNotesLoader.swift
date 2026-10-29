import Foundation
import os

/// Release notes resolved to something a view can render directly.
public enum ReleaseNotesContent: Sendable, Equatable {
    /// HTML; `baseURL` resolves relative links/images of a fetched page.
    case html(String, baseURL: URL?)
    case markdown(String)
    case plainText(String)
    /// The source published nothing (or only whitespace).
    case empty
}

public enum ReleaseNotesError: Error, Sendable, Equatable, LocalizedError {
    case insecureURL(URL)
    case tooLarge(bytes: Int, limit: Int)
    case invalidEncoding

    public var errorDescription: String? {
        switch self {
        case .insecureURL(let url): String(coreLocalized: "Release notes must be served over HTTPS (\(url.absoluteString))")
        case .tooLarge(let bytes, let limit): String(coreLocalized: "Release notes are too large (\(bytes) bytes, limit \(limit))")
        case .invalidEncoding: String(coreLocalized: "Release notes are not valid UTF-8 text")
        }
    }
}

public protocol ReleaseNotesLoading: Sendable {
    func load(_ notes: ReleaseNotes) async throws -> ReleaseNotesContent
}

/// Resolves `ReleaseNotes` into displayable content, fetching remote pages over HTTPS only.
public struct ReleaseNotesLoader: ReleaseNotesLoading {
    public static let defaultMaxBytes = HTTPFetchLimit.releaseNotes
    private static let logger = Logger(subsystem: "com.macappupdater", category: "ReleaseNotes")

    private let httpClient: any HTTPClient
    private let maxBytes: Int

    public init(httpClient: any HTTPClient = URLSessionHTTPClient(), maxBytes: Int = ReleaseNotesLoader.defaultMaxBytes) {
        self.httpClient = httpClient
        self.maxBytes = maxBytes
    }

    public func load(_ notes: ReleaseNotes) async throws -> ReleaseNotesContent {
        switch notes {
        case .html(let html): Self.nonEmpty(html) { .html($0, baseURL: nil) }
        case .markdown(let markdown): Self.nonEmpty(markdown) { .markdown($0) }
        case .remote(let url): try await fetch(url)
        }
    }

    private func fetch(_ url: URL) async throws -> ReleaseNotesContent {
        guard url.scheme?.lowercased() == "https" else { throw ReleaseNotesError.insecureURL(url) }
        // Streamed and capped by a bounded client; others are checked after the fact below.
        let data = if let bounded = httpClient as? any BoundedHTTPClient {
            try await bounded.data(from: url, maxBytes: maxBytes)
        } else {
            try await httpClient.data(from: url)
        }
        guard data.count <= maxBytes else {
            Self.logger.error("Release notes too large: \(data.count) bytes from \(url.absoluteString, privacy: .public)")
            throw ReleaseNotesError.tooLarge(bytes: data.count, limit: maxBytes)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ReleaseNotesError.invalidEncoding }
        return Self.classify(text, from: url)
    }

    /// Picks a renderer from the file extension; Sparkle release-notes links default to HTML.
    static func classify(_ text: String, from url: URL) -> ReleaseNotesContent {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": nonEmpty(text) { .markdown($0) }
        case "txt", "text": nonEmpty(text) { .plainText($0) }
        default: nonEmpty(text) { .html($0, baseURL: url) }
        }
    }

    private static func nonEmpty(_ text: String, _ make: (String) -> ReleaseNotesContent) -> ReleaseNotesContent {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : make(text)
    }
}
