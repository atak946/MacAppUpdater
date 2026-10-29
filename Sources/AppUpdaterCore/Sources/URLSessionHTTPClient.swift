import Foundation

/// `HTTPClient` backed by `URLSession` async APIs.
///
/// Bodies are streamed and capped (`BoundedHTTPClient`); the default session applies
/// `HTTPRedirectPolicy` (https-only redirects, no `Authorization` across hosts).
public struct URLSessionHTTPClient: HTTPClient {
    private static let userAgent = "MacAppUpdater/1.0"

    private let session: URLSession

    /// One app-wide session: a session retains its delegate until invalidated.
    public static let defaultSession = makeSession(configuration: .default)

    /// A session whose redirects go through `HTTPRedirectPolicy`.
    public static func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: HTTPRedirectPolicyDelegate(), delegateQueue: nil)
    }

    /// Update packages are downloaded by `ProgressDownloader`, not by this client.
    public init(session: URLSession = URLSessionHTTPClient.defaultSession) {
        self.session = session
    }

    /// Bounded by `HTTPFetchLimit.default`.
    public func data(from url: URL) async throws -> Data {
        try await data(from: url, maxBytes: HTTPFetchLimit.default)
    }

    private static func request(for url: URL, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    private static func validate(_ response: URLResponse, url: URL) throws {
        guard let http = response as? HTTPURLResponse else {
            throw UpdaterError.network("Non-HTTP response from \(url.absoluteString)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdaterError.network("HTTP \(http.statusCode) from \(url.absoluteString)")
        }
    }
}

extension URLSessionHTTPClient: HTTPRequestClient {
    /// Bounded by `HTTPFetchLimit.default`.
    public func data(from url: URL, headers: [String: String]) async throws -> Data {
        try await data(from: url, headers: headers, maxBytes: HTTPFetchLimit.default)
    }
}

extension URLSessionHTTPClient: BoundedHTTPClient {
    public func data(from url: URL, maxBytes: Int) async throws -> Data {
        try await data(from: url, headers: [:], maxBytes: maxBytes)
    }

    /// Streams the body and aborts as soon as it exceeds `maxBytes`; a declared
    /// `Content-Length` above the limit is rejected before reading anything.
    public func data(from url: URL, headers: [String: String], maxBytes: Int) async throws -> Data {
        do {
            let (bytes, response) = try await session.bytes(for: Self.request(for: url, headers: headers))
            do {
                try Self.validate(response, url: url)
                if response.expectedContentLength > Int64(maxBytes) { throw HTTPFetchLimit.tooLarge }
                return try await Self.collect(bytes, maxBytes: maxBytes, expected: response.expectedContentLength)
            } catch {
                bytes.task.cancel()
                throw error
            }
        } catch let error as UpdaterError {
            throw error
        } catch {
            throw UpdaterError.network(error.localizedDescription)
        }
    }

    private static func collect(_ bytes: URLSession.AsyncBytes, maxBytes: Int, expected: Int64) async throws -> Data {
        var buffer: [UInt8] = []
        buffer.reserveCapacity(expected > 0 ? Int(min(expected, Int64(maxBytes))) : 0)
        for try await byte in bytes {
            guard buffer.count < maxBytes else { throw HTTPFetchLimit.tooLarge }
            buffer.append(byte)
        }
        return Data(buffer)
    }
}
