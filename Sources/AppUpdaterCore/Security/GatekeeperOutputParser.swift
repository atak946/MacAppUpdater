import Foundation

/// Pure parser for `spctl --assess -vv` and `stapler validate` output.
///
/// `spctl` writes its verdict to stderr, e.g.:
/// ```
/// /Applications/Foo.app: accepted
/// source=Notarized Developer ID
/// origin=Developer ID Application: Foo Inc (ABCDE12345)
/// ```
/// `ProcessCommandRunner` merges stderr into the returned output, and a
/// rejection exits with status 3, so callers must parse the output carried by
/// `UpdaterError.commandFailed` too.
public enum GatekeeperOutputParser {
    private static let appleSources = ["apple system", "mac app store", "apple"]

    public static func parseAssessment(_ output: String) -> GatekeeperVerdict {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let source = value(for: "source", in: lines)

        if lines.contains(where: { $0.hasSuffix(": rejected") }) {
            return .rejected(reason: source ?? "rejected")
        }
        guard lines.contains(where: { $0.hasSuffix(": accepted") }) else {
            let firstLine = lines.first ?? "no output"
            return .unknown(reason: firstLine.isEmpty ? "no output" : firstLine)
        }
        return acceptedVerdict(source: source)
    }

    /// True when `stapler validate` confirmed a stapled, valid notarization ticket.
    public static func staplerConfirmsTicket(_ output: String) -> Bool {
        output.contains("The validate action worked")
    }

    private static func acceptedVerdict(source: String?) -> GatekeeperVerdict {
        guard let source else { return .unknown(reason: "accepted without source") }
        let lowered = source.lowercased()
        if lowered.contains("unnotarized") { return .developerIDNotNotarized }
        if lowered.contains("notarized developer id") { return .notarized }
        if lowered.contains("developer id") { return .developerIDNotNotarized }
        if appleSources.contains(lowered) { return .notarized }
        return .unknown(reason: "unrecognized source: \(source)")
    }

    private static func value(for key: String, in lines: [String]) -> String? {
        let prefix = "\(key)="
        return lines
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
    }
}
