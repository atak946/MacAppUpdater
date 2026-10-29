import CoreFoundation
import Foundation
import os

extension ManagedConfiguration {
    /// Accepted range for `CheckIntervalHours` (1 hour … 1 week).
    public static let checkIntervalRange: ClosedRange<Double> = 1...168
    /// Accepted range for `DeferralDays` (matches `UpdatePolicies.maxDeferralDays`).
    public static let deferralDaysRange: ClosedRange<Int> = 0...UpdatePolicies.maxDeferralDays

    /// Reads and validates every `ManagedKey`; invalid values are logged and ignored.
    public init(reader: any ManagedPreferencesReading) {
        let parser = ManagedValueParser(reader: reader)
        self.init(
            checkIntervalHours: parser.number(.checkIntervalHours, in: Self.checkIntervalRange),
            autoInstallEnabled: parser.bool(.autoInstallEnabled),
            defaultPolicy: parser.policy(.defaultPolicy),
            perAppPolicies: parser.policyMap(.perAppPolicies) ?? [:],
            ignoredBundleIdentifiers: parser.bundleIdentifiers(.ignoredBundleIdentifiers) ?? [],
            deferralDays: parser.integer(.deferralDays, in: Self.deferralDaysRange),
            requireACPower: parser.bool(.requireACPower),
            avoidExpensiveNetwork: parser.bool(.avoidExpensiveNetwork),
            disableUninstaller: parser.bool(.disableUninstaller),
            disableBetaChannels: parser.bool(.disableBetaChannels),
            allowedSources: parser.sourceKinds(.allowedSources),
            hideMenuBarIcon: parser.bool(.hideMenuBarIcon),
            requireNotarization: parser.bool(.requireNotarization),
            reportWebhookURL: parser.httpsURL(.reportWebhookURL)
        )
    }
}

/// Typed, validating accessors over a `ManagedPreferencesReading`.
struct ManagedValueParser {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "Managed")
    private static let maxBundleIdentifierLength = 255
    private static let bundleIdentifierCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"
    )

    let reader: any ManagedPreferencesReading

    func bool(_ key: ManagedKey) -> Bool? {
        guard let raw = reader.forcedValue(forKey: key.rawValue) else { return nil }
        if let number = raw as? NSNumber, Self.isBoolean(number) { return number.boolValue }
        return reject(key, raw, reason: "expected a boolean")
    }

    func number(_ key: ManagedKey, in range: ClosedRange<Double>) -> Double? {
        guard let raw = reader.forcedValue(forKey: key.rawValue) else { return nil }
        guard let number = raw as? NSNumber, !Self.isBoolean(number) else {
            return reject(key, raw, reason: "expected a number")
        }
        let value = number.doubleValue
        guard value.isFinite, range.contains(value) else {
            return reject(key, raw, reason: "out of range \(range)")
        }
        return value
    }

    func integer(_ key: ManagedKey, in range: ClosedRange<Int>) -> Int? {
        let bounds = Double(range.lowerBound)...Double(range.upperBound)
        guard let value = number(key, in: bounds) else { return nil }
        guard value.rounded() == value else { return reject(key, value, reason: "expected an integer") }
        return Int(value)
    }

    func policy(_ key: ManagedKey) -> UpdatePolicy? {
        guard let raw = reader.forcedValue(forKey: key.rawValue) else { return nil }
        guard let string = raw as? String, let policy = UpdatePolicy(rawValue: string) else {
            return reject(key, raw, reason: "expected one of \(UpdatePolicy.allCases.map(\.rawValue))")
        }
        return policy
    }

    /// Invalid entries are dropped individually; a dictionary with no valid entry is ignored.
    func policyMap(_ key: ManagedKey) -> [String: UpdatePolicy]? {
        guard let raw = reader.forcedValue(forKey: key.rawValue) else { return nil }
        guard let dictionary = raw as? [String: Any] else {
            return reject(key, raw, reason: "expected a dictionary")
        }
        let valid = dictionary.compactMapValues { ($0 as? String).flatMap(UpdatePolicy.init(rawValue:)) }
            .filter { Self.isValidBundleIdentifier($0.key) }
        if valid.count != dictionary.count {
            warn(key, reason: "dropped \(dictionary.count - valid.count) invalid entries")
        }
        return valid.isEmpty ? reject(key, raw, reason: "no valid entries") : valid
    }

    func bundleIdentifiers(_ key: ManagedKey) -> Set<String>? {
        guard let strings = stringArray(key) else { return nil }
        let valid = strings.filter(Self.isValidBundleIdentifier)
        if valid.count != strings.count {
            warn(key, reason: "dropped \(strings.count - valid.count) invalid bundle identifiers")
        }
        return valid.isEmpty ? reject(key, strings, reason: "no valid entries") : Set(valid)
    }

    /// Fails open: a list without any known source kind is ignored rather than
    /// blocking every source because of a typo.
    func sourceKinds(_ key: ManagedKey) -> Set<UpdateSourceKind>? {
        guard let strings = stringArray(key) else { return nil }
        let valid = strings.compactMap(UpdateSourceKind.init(rawValue:))
        if valid.count != strings.count {
            warn(key, reason: "dropped \(strings.count - valid.count) unknown source kinds")
        }
        return valid.isEmpty ? reject(key, strings, reason: "no valid source kinds") : Set(valid)
    }

    func httpsURL(_ key: ManagedKey) -> URL? {
        guard let raw = reader.forcedValue(forKey: key.rawValue) else { return nil }
        guard let string = raw as? String, let url = URLValidation.httpsURL(string) else { return reject(key, "<redacted>", reason: "expected an https URL without credentials") }
        return url
    }

    // MARK: Helpers

    private func stringArray(_ key: ManagedKey) -> [String]? {
        guard let raw = reader.forcedValue(forKey: key.rawValue) else { return nil }
        guard let array = raw as? [Any] else { return reject(key, raw, reason: "expected an array") }
        return array.compactMap { $0 as? String }
    }

    private func reject<T>(_ key: ManagedKey, _ value: Any, reason: String) -> T? {
        Self.logger.warning(
            "Ignoring managed \(key.rawValue, privacy: .public): \(reason, privacy: .public) (got \(String(describing: value), privacy: .private))"
        )
        return nil
    }

    private func warn(_ key: ManagedKey, reason: String) {
        Self.logger.warning("Managed \(key.rawValue, privacy: .public): \(reason, privacy: .public)")
    }

    /// Distinguishes `<true/>` from `<integer>1</integer>` (both bridge to NSNumber).
    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func isValidBundleIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= maxBundleIdentifierLength
            && value.unicodeScalars.allSatisfy(bundleIdentifierCharacters.contains)
    }
}
