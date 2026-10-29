import Foundation

/// Asks the server for an update's size (HEAD → `Content-Length`) before it is downloaded,
/// so the UI can show "1.5 GB" up front. Redirects follow `HTTPRedirectPolicy` (https only).
public protocol DownloadSizeProbing: Sendable {
    /// Bytes, or nil when the server does not say (or the request fails).
    func size(of url: URL) async -> Int64?
}

public struct DownloadSizeProbe: DownloadSizeProbing {
    private static let timeout: TimeInterval = 15

    private let session: URLSession

    public init(session: URLSession = URLSessionHTTPClient.defaultSession) {
        self.session = session
    }

    public func size(of url: URL) async -> Int64? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return Self.contentLength(of: http)
    }

    static func contentLength(of response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Length"),
              let length = Int64(value.trimmingCharacters(in: .whitespaces)), length > 0
        else { return nil }
        return length
    }
}
