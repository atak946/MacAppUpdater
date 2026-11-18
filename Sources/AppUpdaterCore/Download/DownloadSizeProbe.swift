import Foundation

/// Asks the server for an update's size (HEAD → `Content-Length`) before it is downloaded,
/// so the UI can show "1.5 GB" up front. Redirects follow `HTTPRedirectPolicy` (https only).
public protocol DownloadSizeProbing: Sendable {
    /// Bytes, or nil when the server does not say (or the request fails).
    func size(of url: URL) async -> Int64?
    /// Size plus what the server says the download is (file name after redirects /
    /// `Content-Disposition`, MIME type). Nil when the request fails.
    func inspect(_ url: URL) async -> DownloadHint?
}

public extension DownloadSizeProbing {
    func inspect(_ url: URL) async -> DownloadHint? {
        await size(of: url).map { DownloadHint(size: $0, fileName: nil, mimeType: nil) }
    }
}

/// What a HEAD request revealed about a download before fetching it.
public struct DownloadHint: Sendable, Equatable {
    public let size: Int64?
    /// Server-suggested file name (`Content-Disposition`, else the final URL's last component).
    public let fileName: String?
    public let mimeType: String?

    public init(size: Int64?, fileName: String?, mimeType: String?) {
        self.size = size
        self.fileName = fileName
        self.mimeType = mimeType
    }

    /// Format named by the server's file name; `.unknown` when it names none.
    public var format: PackageFormat {
        fileName.map { PackageFormat(fileURL: URL(fileURLWithPath: $0)) } ?? .unknown
    }

    /// True when the server says this is not an installable package: a web page, or a file
    /// name with a known non-package extension. Unclear answers are false (download and sniff).
    public var isKnownNonPackage: Bool {
        if format != .unknown { return false }
        if let mimeType = mimeType?.lowercased(), mimeType.hasPrefix("text/html") || mimeType.hasPrefix("application/xhtml") {
            return true
        }
        guard let fileName else { return false }
        return InstallMethod.isKnownNonPackage(URL(fileURLWithPath: fileName))
    }
}

public struct DownloadSizeProbe: DownloadSizeProbing {
    private static let timeout: TimeInterval = 15

    private let session: URLSession

    public init(session: URLSession = URLSessionHTTPClient.defaultSession) {
        self.session = session
    }

    public func size(of url: URL) async -> Int64? {
        await inspect(url)?.size
    }

    public func inspect(_ url: URL) async -> DownloadHint? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return Self.hint(from: http)
    }

    static func hint(from response: HTTPURLResponse) -> DownloadHint {
        DownloadHint(size: contentLength(of: response), fileName: response.suggestedFilename, mimeType: response.mimeType)
    }

    static func contentLength(of response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Length"),
              let length = Int64(value.trimmingCharacters(in: .whitespaces)), length > 0
        else { return nil }
        return length
    }
}
