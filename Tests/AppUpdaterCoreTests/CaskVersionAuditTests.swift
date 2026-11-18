import Foundation
import Testing
@testable import AppUpdaterCore

/// Opt-in audit of every Homebrew cask version against `VersionComparator`
/// (`CASK_VERSION_AUDIT=1 swift test --filter CaskVersionAudit`). It lists version spellings
/// whose extra tokens the comparator would read as pre-release labels or as extra numeric
/// components — the shapes that produce phantom updates like `3.6.11-0102f49a`.
@Suite("CaskVersionAudit", .enabled(if: ProcessInfo.processInfo.environment["CASK_VERSION_AUDIT"] == "1"))
struct CaskVersionAuditTests {
    private struct Cask: Decodable {
        let token: String
        let version: String?
    }

    /// Labels the comparator ranks deliberately; any other letter run is suspicious.
    private static let knownLabels: Set<String> = [
        "dev", "snapshot", "nightly", "a", "alpha", "b", "beta", "pre", "preview", "c", "rc",
    ]

    @Test("lists cask versions with unusual suffixes")
    func audit() async throws {
        let (data, _) = try await URLSession.shared.data(from: HomebrewCaskSource.defaultAPIURL)
        let casks = try JSONDecoder().decode([Cask].self, from: data)
        var findings: [String: [String]] = [:]
        for cask in casks {
            let model = HomebrewCask(token: cask.token, version: cask.version, url: nil, sha256: nil, appNames: [])
            guard let version = model.comparableVersion else { continue }
            if let category = Self.category(of: version) {
                findings[category, default: []].append("\(cask.token): \(cask.version ?? "") → \(version)")
            }
        }
        for (category, items) in findings.sorted(by: { $0.key < $1.key }) {
            print("== \(category) (\(items.count))")
            items.prefix(25).forEach { print("   \($0)") }
        }
        #expect(!casks.isEmpty)
    }

    private static func category(of version: String) -> String? {
        let tokens = VersionComparator.tokenize(version)
        let labels = tokens.compactMap { token -> String? in
            if case .text(let text) = token { return text }
            return nil
        }
        if labels.contains(where: { !knownLabels.contains($0) }) { return "unknown letter labels" }
        let dashSuffix = version.split(separator: "-").dropFirst().last
        if let dashSuffix, dashSuffix.count >= 6, dashSuffix.allSatisfy(\.isHexDigit),
           dashSuffix.contains(where: \.isLetter) {
            return "hash-like suffix kept (uppercase or short)"
        }
        if tokens.count > 5 { return "more than five components" }
        return nil
    }
}
