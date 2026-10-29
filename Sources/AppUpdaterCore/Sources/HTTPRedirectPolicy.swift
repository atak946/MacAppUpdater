import Foundation
import os

/// Redirect rules for feed/API requests (mirrors the download delegate's policy):
/// - only `https` redirects are followed; anything else stops at the 3xx response,
///   which the client then rejects as a non-2xx status;
/// - `Authorization` (the GitHub token) is dropped when the redirect leaves the original host.
enum HTTPRedirectPolicy {
    static let authorizationHeader = "Authorization"

    /// The request to follow, or nil to refuse the redirect.
    static func redirectedRequest(_ proposed: URLRequest, originalURL: URL?) -> URLRequest? {
        guard let url = proposed.url, url.scheme?.lowercased() == "https" else { return nil }
        guard proposed.value(forHTTPHeaderField: authorizationHeader) != nil,
              !isSameHost(url, originalURL)
        else { return proposed }
        var stripped = proposed
        stripped.setValue(nil, forHTTPHeaderField: authorizationHeader)
        return stripped
    }

    static func isSameHost(_ lhs: URL, _ rhs: URL?) -> Bool {
        guard let left = lhs.host?.lowercased(), let right = rhs?.host?.lowercased() else { return false }
        return left == right
    }
}

/// Session delegate applying `HTTPRedirectPolicy`. Stateless, hence `Sendable`.
final class HTTPRedirectPolicyDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "HTTP")

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let decision = HTTPRedirectPolicy.redirectedRequest(request, originalURL: task.originalRequest?.url)
        if decision == nil {
            Self.logger.error("Refused non-https redirect to \(request.url?.host ?? "?", privacy: .public)")
        }
        completionHandler(decision)
    }
}
