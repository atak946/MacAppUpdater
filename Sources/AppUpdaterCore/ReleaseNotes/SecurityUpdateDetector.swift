import Foundation

/// Evidence that an update's release notes mention security fixes.
public struct SecurityUpdateInfo: Sendable, Hashable {
    /// Upper-cased CVE identifiers in order of first appearance, without duplicates.
    public let cveIDs: [String]

    public init(cveIDs: [String] = []) {
        self.cveIDs = cveIDs
    }
}

/// Flags release notes that mention security fixes, using only text the source already delivered.
///
/// Remote notes (`ReleaseNotes.remote`) are never fetched here, so those updates simply aren't flagged.
public enum SecurityUpdateDetector {
    /// Word-bounded so words like "insecure" or "securityd" don't match.
    private static let keywordPattern =
        #"\b(?:security|vulnerabilit(?:y|ies)|vulnerable|exploits?|exploited|exploitable|zero-day|0-day)\b"#
    private static let cvePattern = #"\bCVE-\d{4}-\d{4,}\b"#
    /// Tags are dropped so attribute values (`class="security-icon"`) can't trigger a match.
    private static let tagPattern = #"<[^>]*>"#

    public static func detect(in notes: ReleaseNotes?) -> SecurityUpdateInfo? {
        switch notes {
        case .html(let html): detect(inText: stripTags(html))
        case .markdown(let text): detect(inText: text)
        case .remote, nil: nil
        }
    }

    /// Nil when the text has neither a security keyword nor a CVE identifier.
    public static func detect(inText text: String) -> SecurityUpdateInfo? {
        let cves = cveIDs(in: text)
        if !cves.isEmpty { return SecurityUpdateInfo(cveIDs: cves) }
        guard text.range(of: keywordPattern, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return SecurityUpdateInfo()
    }

    static func cveIDs(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: cvePattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            let id = text[swiftRange].uppercased()
            return seen.insert(id).inserted ? id : nil
        }
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: tagPattern, with: " ", options: .regularExpression)
    }
}
