import Foundation

/// One entry of `files:` in `latest-mac.yml`.
struct ElectronFeedFile: Sendable, Equatable {
    /// Absolute or feed-relative URL string.
    let url: String
    /// Base64 SHA-512 of the file.
    let sha512: String?
    let size: Int64?
}

/// Parsed `latest-mac.yml`.
struct ElectronFeed: Sendable, Equatable {
    let version: String
    let files: [ElectronFeedFile]
    /// Legacy single-file fields (older electron-builder releases).
    let path: String?
    let sha512: String?
    let releaseDate: Date?
    let releaseNotes: String?
    let minimumSystemVersion: String?

    /// `files`, plus the legacy `path` when it is not already listed.
    var allFiles: [ElectronFeedFile] {
        guard let path, !files.contains(where: { $0.url == path }) else { return files }
        return files + [ElectronFeedFile(url: path, sha512: sha512, size: nil)]
    }
}

/// Parses electron-builder metadata: `app-update.yml` (provider) and `latest-mac.yml` (feed).
enum ElectronFeedParser {
    private static let identifierCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))

    // MARK: latest-mac.yml

    static func parseFeed(_ data: Data) throws -> ElectronFeed {
        let root = try ElectronYAMLParser.parse(data)
        guard let version = root["version"]?.string else {
            throw UpdaterError.parsing("latest-mac.yml has no version")
        }
        let files = (root["files"]?.list ?? []).compactMap { item -> ElectronFeedFile? in
            guard let url = item["url"]?.string else { return nil }
            return ElectronFeedFile(url: url, sha512: item["sha512"]?.string, size: item["size"]?.string.flatMap { Int64($0) })
        }
        return ElectronFeed(
            version: GitHubReleasesSource.normalizedVersion(version),
            files: files,
            path: root["path"]?.string,
            sha512: root["sha512"]?.string,
            releaseDate: ReleaseDateParser.iso8601(root["releaseDate"]?.string),
            releaseNotes: releaseNotes(root["releaseNotes"]),
            minimumSystemVersion: root["minimumSystemVersion"]?.string
        )
    }

    /// `releaseNotes` is a string, or a list of `{version, note}` when `fullChangelog` is enabled.
    private static func releaseNotes(_ value: ElectronYAMLValue?) -> String? {
        if let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        let notes = (value?.list ?? []).compactMap { $0["note"]?.string }
        return notes.isEmpty ? nil : notes.joined(separator: "\n\n")
    }

    // MARK: app-update.yml

    /// The `latest-mac.yml` URL described by `app-update.yml`, or nil for unsupported providers.
    static func feedURL(fromUpdateConfig data: Data) throws -> URL? {
        let config = try ElectronYAMLParser.parse(data)
        let channel = config["channel"]?.string.flatMap { isIdentifier($0) ? $0 : nil } ?? "latest"
        guard let base = baseURL(for: config) else { return nil }
        let feedURL = base.appendingPathComponent("\(channel)-mac.yml")
        return feedURL.scheme?.lowercased() == "https" ? feedURL : nil
    }

    private static func baseURL(for config: ElectronYAMLValue) -> URL? {
        switch config["provider"]?.string?.lowercased() {
        case "github": githubBaseURL(config)
        case "generic": config["url"]?.string.flatMap(httpsURL)
        case "s3": s3BaseURL(config)
        case "spaces": spacesBaseURL(config)
        default: nil
        }
    }

    private static func githubBaseURL(_ config: ElectronYAMLValue) -> URL? {
        guard let owner = config["owner"]?.string, let repo = config["repo"]?.string,
              GitHubReleasesSource.isValidRepository("\(owner)/\(repo)")
        else { return nil }
        let host = config["host"]?.string ?? "github.com"
        guard isHostName(host) else { return nil }
        return URL(string: "https://\(host)/\(owner)/\(repo)/releases/latest/download")
    }

    /// Mirrors electron-builder's `s3Url` (accelerate, endpoint, dotted buckets, cn-north-1).
    private static func s3BaseURL(_ config: ElectronYAMLValue) -> URL? {
        guard let bucket = config["bucket"]?.string, isHostName(bucket) else { return nil }
        let region = config["region"]?.string.flatMap { isIdentifier($0) ? $0 : nil }
        let base: String
        if config["accelerate"]?.string == "true" {
            base = "https://\(bucket).s3-accelerate.amazonaws.com"
        } else if let endpoint = config["endpoint"]?.string {
            guard let endpointURL = httpsURL(endpoint) else { return nil }
            base = endpointURL.appendingPathComponent(bucket).absoluteString
        } else if bucket.contains(".") {
            guard let region else { return nil }
            base = region == "us-east-1"
                ? "https://s3.amazonaws.com/\(bucket)"
                : "https://s3-\(region).amazonaws.com/\(bucket)"
        } else if region == "cn-north-1" {
            base = "https://\(bucket).s3.cn-north-1.amazonaws.com.cn"
        } else {
            base = "https://\(bucket).s3.amazonaws.com"
        }
        return appendingPath(config["path"]?.string, to: base)
    }

    private static func spacesBaseURL(_ config: ElectronYAMLValue) -> URL? {
        guard let name = config["name"]?.string, isHostName(name),
              let region = config["region"]?.string, isIdentifier(region)
        else { return nil }
        return appendingPath(config["path"]?.string, to: "https://\(name).\(region).digitaloceanspaces.com")
    }

    private static func appendingPath(_ path: String?, to base: String) -> URL? {
        guard let path, !path.isEmpty else { return URL(string: base) }
        let segments = path.split(separator: "/")
        guard segments.allSatisfy({ $0 != ".." && $0 != "." }),
              let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: base + (encoded.hasPrefix("/") ? "" : "/") + encoded)
    }

    /// Rejects unexpanded `${…}` template markers on top of the shared https rule.
    private static func httpsURL(_ string: String) -> URL? {
        guard !string.contains("$") else { return nil }
        return URLValidation.httpsURL(string)
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { $0.isASCII && identifierCharacters.contains($0) }
    }

    private static func isHostName(_ value: String) -> Bool {
        isIdentifier(value) && !value.hasPrefix(".") && !value.hasPrefix("-") && !value.contains("..")
    }
}
