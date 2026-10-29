import Foundation

/// Heuristic eTLD+1 ("registrable domain") without a full Public Suffix List.
///
/// Takes the last two labels, or three when the last two form a known
/// multi-part public suffix (`co.uk`, `com.au`, …). Known CDN hosts are then
/// folded into a "family" so `github.com` → `release-assets.githubusercontent.com`
/// (the GitHub release download redirect) is not reported as a change.
public enum RegistrableDomain {
    static let multiPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk",
        "com.au", "net.au", "org.au",
        "co.jp", "ne.jp", "or.jp",
        "co.nz", "org.nz", "co.za", "co.kr", "co.in",
        "com.br", "com.cn", "com.tr", "com.tw", "com.hk", "com.mx", "com.sg",
        // User-controlled hosting (Public Suffix List private section): every
        // `<user>.github.io` is its own site, never part of the github.com family.
        "github.io",
        // `raw.`, `gist.`, `user-images.`… serve arbitrary users' content, so each
        // githubusercontent.com host is its own site (also in the PSL private section).
        "githubusercontent.com",
    ]

    /// Registrable domains that belong to the same publisher infrastructure.
    /// `github.io` and `githubusercontent.com` are deliberately absent (user content).
    static let families: [String: String] = [
        "github.com": "github",
        "githubassets.com": "github",
    ]

    /// Exact hosts folded into a family: the CDNs GitHub redirects release-asset downloads
    /// (`github.com/<owner>/<repo>/releases/download/…`) to. `release-assets.` is the current
    /// one (verified 2026-10); `objects.` is the previous one and still appears in older links.
    static let hostFamilies: [String: String] = [
        "release-assets.githubusercontent.com": "github",
        "objects.githubusercontent.com": "github",
    ]

    /// Lowercased host with any leading `www.` removed; `nil` for empty hosts.
    public static func normalizedHost(_ host: String?) -> String? {
        guard var host = host?.lowercased().trimmingCharacters(in: .whitespaces) else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// eTLD+1 of a normalized host. IP addresses and single labels are returned unchanged.
    public static func registrableDomain(of host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2, !isIPAddress(labels) else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let count = multiPartSuffixes.contains(lastTwo) ? 3 : 2
        return labels.suffix(count).joined(separator: ".")
    }

    /// Comparison key: the CDN family name when known, else the registrable domain.
    public static func familyKey(of host: String) -> String {
        if let family = hostFamilies[host] { return family }
        let domain = registrableDomain(of: host)
        return families[domain] ?? domain
    }

    private static func isIPAddress(_ labels: [String]) -> Bool {
        labels.count == 4 && labels.allSatisfy { UInt8($0) != nil }
    }
}
