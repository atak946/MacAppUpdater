import Foundation

/// Renders and parses the subset of the `brew bundle` Brewfile format the migration uses:
/// `brew`, `cask` and `mas` lines, plus comment lines for apps that need a manual install.
///
/// A Brewfile is Ruby evaluated by `brew bundle`, so rendered strings escape `\`, `"` and `#`
/// (no `#{}` interpolation) and every value is validated or sanitized first.
public enum Brewfile {
    static let manualCaskNote = "no Homebrew cask, install manually"
    static let manualStoreNote = "no App Store ID, install from the App Store"

    public static func render(_ manifest: MigrationManifest) -> String {
        let casks = unique(manifest.apps.compactMap(\.caskToken).filter(MigrationValidation.isValidCaskToken))
        let storeApps = manifest.apps.filter { $0.caskToken == nil && $0.appStoreID != nil }
        let manual = manifest.apps.filter { $0.caskToken == nil && $0.appStoreID == nil }
        var formulae = unique(manifest.formulae.filter(HomebrewCLI.isValidFormulaName))
        // `mas` lines need the mas CLI, which `brew bundle` installs when it is listed.
        if !storeApps.isEmpty, !formulae.contains("mas") { formulae.insert("mas", at: 0) }

        var sections: [[String]] = [[
            "# App list exported by App Updater.",
            "# Install everything with: brew bundle --file=<path to this file>",
        ]]
        sections.append(formulae.map { "brew \(quoted($0))" })
        sections.append(casks.map { "cask \(quoted($0))" })
        sections.append(storeApps.compactMap { entry in
            entry.appStoreID.map { "mas \(quoted(entry.name)), id: \($0)" }
        })
        sections.append(manual.map(manualComment))
        return sections.filter { !$0.isEmpty }.map { $0.joined(separator: "\n") }.joined(separator: "\n\n") + "\n"
    }

    /// Lines that are not recognised (taps, `whalebrew`, options, invalid tokens) are skipped.
    public static func parse(_ text: String) -> MigrationManifest {
        let caskPattern = #/cask\s+["']([^"']+)["']\s*(?:[,#].*)?/#
        let brewPattern = #/brew\s+["']([^"']+)["']\s*(?:[,#].*)?/#
        let masPattern = #/mas\s+"((?:[^"\\]|\\.)*)"\s*,\s*id:\s*(\d{1,12})\s*(?:#.*)?/#
        let manualPattern =
            #/#\s*(.+?)\s+\(([^()\s]+)\):\s*(no Homebrew cask, install manually|no App Store ID, install from the App Store)\s*/#
        var apps: [MigrationEntry] = []
        var formulae: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let match = line.wholeMatch(of: caskPattern) {
                let token = String(match.1)
                guard MigrationValidation.isValidCaskToken(token) else { continue }
                apps.append(MigrationEntry(
                    bundleIdentifier: nil, name: token, version: nil, source: .homebrew, caskToken: token
                ))
            } else if let match = line.wholeMatch(of: brewPattern) {
                let name = String(match.1)
                if HomebrewCLI.isValidFormulaName(name) { formulae.append(name) }
            } else if let match = line.wholeMatch(of: masPattern) {
                guard let id = Int(match.2), MigrationValidation.isValidAppStoreID(id) else { continue }
                let name = MigrationValidation.sanitizedText(unescaped(String(match.1)))
                apps.append(MigrationEntry(
                    bundleIdentifier: nil, name: name, version: nil, source: .appStore, appStoreID: id
                ))
            } else if let match = line.wholeMatch(of: manualPattern) {
                let isStore = match.3 == manualStoreNote
                apps.append(MigrationEntry(
                    bundleIdentifier: MigrationValidation.sanitizedText(String(match.2)),
                    name: MigrationValidation.sanitizedText(String(match.1)),
                    version: nil, source: isStore ? .appStore : .manual
                ))
            }
        }
        return MigrationManifest(apps: apps, formulae: unique(formulae))
    }

    // MARK: - Helpers

    private static func manualComment(_ entry: MigrationEntry) -> String {
        let name = MigrationValidation.sanitizedText(entry.name)
        let bundleID = MigrationValidation.sanitizedText(entry.bundleIdentifier ?? "unknown")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: " ", with: "")
        let note = entry.source == .appStore ? manualStoreNote : manualCaskNote
        return "# \(name.isEmpty ? bundleID : name) (\(bundleID.isEmpty ? "unknown" : bundleID)): \(note)"
    }

    /// A Ruby double-quoted literal with no escapes or interpolation left active.
    static func quoted(_ value: String) -> String {
        let escaped = MigrationValidation.sanitizedText(value)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "#", with: "\\#")
        return "\"\(escaped)\""
    }

    private static func unescaped(_ value: String) -> String {
        var result = ""
        var isEscaping = false
        for character in value {
            if isEscaping {
                result.append(character)
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
