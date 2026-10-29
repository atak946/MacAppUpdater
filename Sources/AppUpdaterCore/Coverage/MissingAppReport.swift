import Foundation

/// Privacy-safe facts about an untracked app, rendered as a prefilled GitHub issue.
/// Never carries file paths or user names: only bundle id, name, versions and boolean hints.
public struct MissingAppReport: Sendable, Hashable {
    public static let maxFieldLength = 120
    /// GitHub rejects very long "new issue" URLs; stay well below its ~8 KB limit.
    public static let maxURLLength = 4_000

    public let bundleIdentifier: String
    public let name: String
    public let version: String
    public let buildVersion: String?
    public let hasSparkleFeed: Bool
    public let hasElectronUpdateConfig: Bool
    public let teamIdentifier: String?

    /// - Parameters:
    ///   - hasElectronUpdateConfig: whether `Contents/Resources/app-update.yml` exists;
    ///     nil checks the bundle on disk (see `electronConfigExists(in:)`).
    ///   - teamIdentifier: signing Team ID, e.g. from `AppDetails.signature`.
    ///   - homeDirectory / userName: redacted from every field as a defence in depth.
    public init(
        app: InstalledApp,
        hasElectronUpdateConfig: Bool? = nil,
        teamIdentifier: String? = nil,
        homeDirectory: String = NSHomeDirectory(),
        userName: String = NSUserName()
    ) {
        let redactor = Redactor(homeDirectory: homeDirectory, userName: userName)
        bundleIdentifier = redactor.clean(app.bundleIdentifier)
        name = redactor.clean(app.name)
        version = redactor.clean(app.shortVersion)
        buildVersion = app.buildVersion.map(redactor.clean)
        hasSparkleFeed = app.sparkleFeedURL != nil
        self.hasElectronUpdateConfig = hasElectronUpdateConfig ?? Self.electronConfigExists(in: app.url)
        self.teamIdentifier = teamIdentifier.map(redactor.clean).flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func electronConfigExists(in appURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/Resources/app-update.yml").path)
    }

    public var title: String { "Missing app: \(name) (\(bundleIdentifier))" }

    public var body: String {
        [
            "**App:** \(name)",
            "**Bundle ID:** `\(bundleIdentifier)`",
            "**Version:** \(version)" + (buildVersion.map { " (\($0))" } ?? ""),
            "**Sparkle feed (SUFeedURL):** \(hasSparkleFeed ? "yes" : "no")",
            "**electron-builder app-update.yml:** \(hasElectronUpdateConfig ? "yes" : "no")",
            "**Signing Team ID:** \(teamIdentifier ?? "unknown")",
            "",
            "Where can updates for this app be found? (official site, appcast, GitHub repo, Homebrew cask…)",
        ].joined(separator: "\n")
    }

    /// Prefilled `issues/new` URL; the body is truncated so the URL stays under `maxURLLength`.
    public func issueURL(repository: String = CoverageConstants.issueRepository) -> URL? {
        let base = "https://github.com/\(repository)/issues/new"
        let fixed = "?title=\(PercentEncoding.queryValue(title))&labels=\(PercentEncoding.queryValue(CoverageConstants.issueLabel))&body="
        let budget = Self.maxURLLength - base.count - fixed.count
        return URL(string: base + fixed + Self.encodedPrefix(of: body, maxEncodedLength: budget))
    }

    /// Longest prefix of `text` whose encoding fits, cut on a character boundary.
    static func encodedPrefix(of text: String, maxEncodedLength: Int) -> String {
        var encoded = ""
        for character in text {
            let piece = PercentEncoding.queryValue(String(character))
            guard encoded.count + piece.count <= maxEncodedLength else { break }
            encoded += piece
        }
        return encoded
    }
}

/// Strips paths, the home directory, the user name and control characters, and caps length.
struct Redactor: Sendable {
    let homeDirectory: String
    let userName: String

    func clean(_ value: String) -> String {
        var text = value
        if !homeDirectory.isEmpty, homeDirectory != "/" {
            text = text.replacingOccurrences(of: homeDirectory, with: "~")
        }
        text = text.replacingOccurrences(of: #"/Users/[^/\s]+"#, with: "~", options: .regularExpression)
        if userName.count >= 3 {
            let word = #"\b"# + NSRegularExpression.escapedPattern(for: userName) + #"\b"#
            text = text.replacingOccurrences(of: word, with: "<user>", options: [.regularExpression, .caseInsensitive])
        }
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let flattened = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return String(flattened.prefix(MissingAppReport.maxFieldLength))
    }
}
