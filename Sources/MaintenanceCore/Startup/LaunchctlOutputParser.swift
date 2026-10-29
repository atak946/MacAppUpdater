import Foundation

/// Pure parsers for `launchctl` text output.
public enum LaunchctlOutputParser {
    /// Parses `launchctl print-disabled <domain>` into label → isEnabled.
    ///
    /// Modern macOS prints `"label" => enabled|disabled`; older releases print
    /// `"label" => true|false` where `true` means disabled.
    public static func parseDisabledOverrides(_ output: String) -> [String: Bool] {
        var overrides: [String: Bool] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !label.isEmpty else { continue }
            switch parts[1].trimmingCharacters(in: .whitespaces).lowercased() {
            case "enabled", "false": overrides[label] = true
            case "disabled", "true": overrides[label] = false
            default: continue
            }
        }
        return overrides
    }

    /// Top-level `key = value` pairs of `launchctl print <domain>/<label>` (nested blocks are skipped).
    public static func parseServiceProperties(_ output: String) -> [String: String] {
        var properties: [String: String] = [:]
        var depth = 0
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("{") {
                depth += 1
                continue
            }
            if line == "}" {
                depth = max(0, depth - 1)
                continue
            }
            // Depth 1 is inside the service's own block.
            guard depth == 1, let range = line.range(of: " = ") else { continue }
            let key = String(line[..<range.lowerBound])
            let value = String(line[range.upperBound...])
            properties[key] = value
        }
        return properties
    }

    /// True when a `launchctl print` service block reports `state = running`.
    public static func isRunning(_ output: String) -> Bool {
        parseServiceProperties(output)["state"] == "running"
    }
}
