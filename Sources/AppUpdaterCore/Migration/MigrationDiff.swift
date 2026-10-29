import Foundation

/// Compares an imported list with the apps on this Mac.
public enum MigrationDiff {
    /// Entries with no matching installed app. An entry counts as installed when its bundle ID,
    /// its cask token (via `installedCaskTokens`) or, failing both, its name matches.
    public static func missing(
        _ entries: [MigrationEntry],
        installed: [InstalledApp],
        installedCaskTokens: Set<String> = []
    ) -> [MigrationEntry] {
        let bundleIDs = Set(installed.map { $0.bundleIdentifier.lowercased() })
        let names = Set(installed.map { $0.name.lowercased() })
        let tokens = Set(installedCaskTokens.map(bareToken))
        var seen: Set<String> = []
        return entries.filter { entry in
            guard seen.insert(entry.id).inserted else { return false }
            if let bundleID = entry.bundleIdentifier, bundleIDs.contains(bundleID.lowercased()) { return false }
            if let token = entry.caskToken, tokens.contains(bareToken(token)) { return false }
            return !names.contains(entry.name.lowercased())
        }
    }

    /// `user/tap/token` and `token` name the same app for matching.
    private static func bareToken(_ token: String) -> String {
        String(token.split(separator: "/").last ?? Substring(token)).lowercased()
    }
}

/// Commands the user can copy into Terminal. Nothing here is executed by the app.
public enum MigrationCommands {
    /// `brew install --cask a b c` for the entries with a valid cask token, or nil when none.
    /// Tokens are re-validated so the command never carries anything but token characters.
    public static func caskInstallCommand(for entries: [MigrationEntry]) -> String? {
        var seen: Set<String> = []
        let tokens = entries.compactMap(\.caskToken)
            .filter { MigrationValidation.isValidCaskToken($0) && seen.insert($0).inserted }
        guard !tokens.isEmpty else { return nil }
        return "brew install --cask " + tokens.joined(separator: " ")
    }

    /// `brew bundle --file='<path>'`, the path single-quoted for the shell.
    public static func bundleCommand(fileURL: URL) -> String {
        "brew bundle --file=" + shellQuoted(fileURL.path)
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Opens the store page; only a validated numeric ID ever ends up in the URL.
    public static func appStoreURL(for entry: MigrationEntry) -> URL? {
        guard let id = entry.appStoreID, MigrationValidation.isValidAppStoreID(id) else { return nil }
        return URL(string: "macappstore://apps.apple.com/app/id\(id)")
    }
}
