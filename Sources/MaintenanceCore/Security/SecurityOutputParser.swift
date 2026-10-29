import Foundation

/// Pure parsers for the output of macOS security tools. Each returns `.unknown` for output it
/// doesn't recognize, so a changed tool never reports a false "on".
public enum SecurityOutputParser {
    // MARK: Tools

    /// `fdesetup status`: "FileVault is On." / "FileVault is Off." / "Encryption in progress: …".
    public static func fileVault(_ output: String) -> SecurityCheckStatus {
        let text = output.lowercased()
        if text.contains("filevault is on") || text.contains("encryption in progress") { return .on }
        if text.contains("filevault is off") || text.contains("decryption in progress") { return .off }
        return .unknown
    }

    /// `socketfilterfw --getglobalstate`: "Firewall is enabled. (State = 1)"; state 2 blocks everything.
    public static func firewall(_ output: String) -> SecurityCheckStatus {
        if let state = firstInteger(after: "State = ", in: output) { return state > 0 ? .on : .off }
        let text = output.lowercased()
        if text.contains("firewall is enabled") || text.contains("block all") { return .on }
        if text.contains("firewall is disabled") { return .off }
        return .unknown
    }

    /// `socketfilterfw --getstealthmode`: "Firewall stealth mode is on" (older: "Stealth mode enabled").
    public static func stealthMode(_ output: String) -> SecurityCheckStatus {
        let text = output.lowercased()
        if text.contains("stealth mode is on") || text.contains("stealth mode enabled") { return .on }
        if text.contains("stealth mode is off") || text.contains("stealth mode disabled") { return .off }
        return .unknown
    }

    /// `csrutil status`: "System Integrity Protection status: enabled." A custom configuration counts as off.
    public static func systemIntegrityProtection(_ output: String) -> SecurityCheckStatus {
        let text = output.lowercased()
        guard text.contains("system integrity protection status") else { return .unknown }
        if text.contains("status: enabled") { return .on }
        if text.contains("status: disabled") || text.contains("custom configuration") { return .off }
        return .unknown
    }

    /// `spctl --status`: "assessments enabled" / "assessments disabled".
    public static func gatekeeper(_ output: String) -> SecurityCheckStatus {
        let text = output.lowercased()
        if text.contains("assessments enabled") { return .on }
        if text.contains("assessments disabled") { return .off }
        return .unknown
    }

    /// `sysadminctl -screenLock status`: "screenLock delay is immediate" / "… is 300 seconds" / "screenLock is off".
    /// The detail is the delay in seconds ("0" for immediate).
    public static func screenLock(_ output: String) -> (status: SecurityCheckStatus, delaySeconds: Int?) {
        let text = output.lowercased()
        if text.contains("screenlock is off") { return (.off, nil) }
        if text.contains("delay is immediate") { return (.on, 0) }
        if let seconds = firstInteger(after: "delay is ", in: text) { return (.on, seconds) }
        return (.unknown, nil)
    }

    /// `launchctl print system/com.openssh.sshd`: loaded means Remote Login is on.
    public static func remoteLogin(exitStatus: Int32, output: String) -> SecurityCheckStatus {
        if output.lowercased().contains("could not find service") { return .off }
        if exitStatus == 0, output.contains("com.openssh.sshd") { return .on }
        return .unknown
    }

    // MARK: Preferences

    /// `/Library/Preferences/com.apple.SoftwareUpdate.plist`. Missing keys use the macOS defaults
    /// (checking, downloading and security responses are on unless turned off).
    public static func automaticUpdates(_ preferences: [String: Any]?) -> SecurityCheckStatus {
        guard let preferences else { return .unknown }
        let check = bool(preferences["AutomaticCheckEnabled"]) ?? true
        let download = bool(preferences["AutomaticDownload"]) ?? true
        let critical = bool(preferences["CriticalUpdateInstall"]) ?? true
        return check && download && critical ? .on : .off
    }

    /// Whether macOS updates also install themselves (shown as a detail, not scored).
    public static func installsMacOSUpdates(_ preferences: [String: Any]?) -> Bool? {
        bool(preferences?["AutomaticallyInstallMacOSUpdates"])
    }

    /// XProtect counts as current when its definitions changed within `maxAge`.
    public static func xprotect(updatedAt: Date?, now: Date, maxAge: TimeInterval = 60 * 86_400) -> SecurityCheckStatus {
        guard let updatedAt else { return .unknown }
        return now.timeIntervalSince(updatedAt) <= maxAge ? .on : .off
    }

    // MARK: Helpers

    private static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool: flag
        case let number as NSNumber: number.boolValue
        case let text as String: ["1", "true", "yes"].contains(text.lowercased())
        default: nil
        }
    }

    private static func firstInteger(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}

/// Weighted 0...100 score over the checks whose status is known.
public enum SecurityScore {
    public static func score(for results: [SecurityCheckResult]) -> Int? {
        let known = results.filter { $0.isSecure != nil }
        let total = known.reduce(0) { $0 + $1.kind.weight }
        guard total > 0 else { return nil }
        let earned = known.filter { $0.isSecure == true }.reduce(0) { $0 + $1.kind.weight }
        return Int((Double(earned) / Double(total) * 100).rounded())
    }
}
