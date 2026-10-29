import Foundation

/// The parts of a launchd job plist this app cares about.
public struct LaunchdJobDefinition: Sendable, Equatable {
    public let label: String
    public let program: String?
    public let programArguments: [String]
    public let runAtLoad: Bool
    /// `KeepAlive` is true, or a dictionary of conditions (treated as "kept alive").
    public let keepAlive: Bool
    public let schedule: StartupSchedule?
    /// The plist's own `Disabled` key; launchctl overrides win over it.
    public let isDisabled: Bool
    /// `AssociatedBundleIdentifiers`: apps that declare ownership of the job.
    public let associatedBundleIdentifiers: [String]

    public enum ParseError: Error, Equatable {
        case notADictionary
        case missingLabel
    }

    /// Parses plist data (XML or binary).
    public static func parse(_ data: Data) throws -> LaunchdJobDefinition {
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = object as? [String: Any] else { throw ParseError.notADictionary }
        return try parse(dictionary)
    }

    static func parse(_ plist: [String: Any]) throws -> LaunchdJobDefinition {
        guard let label = plist["Label"] as? String, !label.isEmpty else { throw ParseError.missingLabel }
        return LaunchdJobDefinition(
            label: label,
            program: plist["Program"] as? String,
            programArguments: plist["ProgramArguments"] as? [String] ?? [],
            runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
            keepAlive: parseKeepAlive(plist["KeepAlive"]),
            schedule: parseSchedule(plist),
            isDisabled: plist["Disabled"] as? Bool ?? false,
            associatedBundleIdentifiers: parseStrings(plist["AssociatedBundleIdentifiers"])
        )
    }

    /// `Program` wins; otherwise the first `ProgramArguments` entry.
    public var executablePath: String? {
        if let program, !program.isEmpty { return program }
        return programArguments.first.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Helpers

    private static func parseKeepAlive(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: flag
        case let conditions as [String: Any]: !conditions.isEmpty
        default: false
        }
    }

    private static func parseSchedule(_ plist: [String: Any]) -> StartupSchedule? {
        if let seconds = plist["StartInterval"] as? Int, seconds > 0 {
            return .interval(seconds: seconds)
        }
        switch plist["StartCalendarInterval"] {
        case let entry as [String: Int]:
            return .calendar([entry])
        case let entries as [[String: Int]] where !entries.isEmpty:
            return .calendar(entries)
        default:
            return nil
        }
    }

    private static func parseStrings(_ value: Any?) -> [String] {
        switch value {
        case let single as String: [single]
        case let many as [String]: many
        default: []
        }
    }
}
