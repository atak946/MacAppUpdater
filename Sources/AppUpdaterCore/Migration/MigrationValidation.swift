import Foundation

/// Checks applied to everything read from a migration file before it is shown or put
/// into a command the user can copy.
public enum MigrationValidation {
    private static let maxTokenLength = 128
    private static let maxTextLength = 256
    /// App Store IDs are positive integers; anything past 12 digits is not a real ID.
    private static let maxAppStoreID = 999_999_999_999

    /// Cask tokens: lowercase `google-chrome`, `visual-studio-code@insiders`, `1password`,
    /// optionally tap-qualified (`user/tap/token`). Each component starts with a letter or digit,
    /// so nothing can look like an option, and no whitespace, quotes or shell metacharacters pass.
    public static func isValidCaskToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= maxTokenLength else { return false }
        let pattern = #/([a-z0-9][a-z0-9_\-]*/[a-z0-9][a-z0-9_\-]*/)?[a-z0-9][a-z0-9.+@_\-]*/#
        guard token.wholeMatch(of: pattern) != nil else { return false }
        return !token.contains("..")
    }

    public static func isValidAppStoreID(_ id: Int) -> Bool {
        id > 0 && id <= maxAppStoreID
    }

    /// Display text from a file: control characters (newlines included) become spaces and the
    /// result is trimmed and capped, so a name can never break out of a Brewfile comment line.
    public static func sanitizedText(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }
        var cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        if cleaned.count > maxTextLength { cleaned = String(cleaned.prefix(maxTextLength)) }
        return cleaned
    }
}

public enum MigrationFileError: Error, Sendable, Equatable, LocalizedError {
    case tooLarge
    case unreadable
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .tooLarge: String(coreLocalized: "The file is too large to be an app list")
        case .unreadable: String(coreLocalized: "The file is not an App Updater JSON export or a Brewfile")
        case .unsupportedVersion(let version):
            String(coreLocalized: "The app list was exported by a newer App Updater (format \(version))")
        }
    }
}

/// Reads and writes migration files. JSON and Brewfile are told apart by content, not by
/// extension, since Brewfiles usually have none.
public enum MigrationFile {
    /// Real exports are a few hundred KB at most.
    public static let maxBytes = 2 * 1024 * 1024

    public static func encodeJSON(_ manifest: MigrationManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    public static func decodeJSON(_ data: Data) throws -> MigrationManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: MigrationManifest
        do {
            manifest = try decoder.decode(MigrationManifest.self, from: data)
        } catch {
            throw MigrationFileError.unreadable
        }
        guard manifest.formatVersion <= MigrationManifest.currentFormatVersion else {
            throw MigrationFileError.unsupportedVersion(manifest.formatVersion)
        }
        let usable = manifest.apps.filter { !$0.name.isEmpty || $0.bundleIdentifier != nil }
        return MigrationManifest(
            apps: usable, formulae: manifest.formulae,
            exportedAt: manifest.exportedAt, formatVersion: manifest.formatVersion
        )
    }

    /// Decodes either format: a document starting with `{` is JSON, anything else a Brewfile.
    public static func decode(_ data: Data) throws -> MigrationManifest {
        guard data.count <= maxBytes else { throw MigrationFileError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw MigrationFileError.unreadable }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            return try decodeJSON(data)
        }
        let manifest = Brewfile.parse(text)
        guard !manifest.apps.isEmpty || !manifest.formulae.isEmpty else { throw MigrationFileError.unreadable }
        return manifest
    }
}
