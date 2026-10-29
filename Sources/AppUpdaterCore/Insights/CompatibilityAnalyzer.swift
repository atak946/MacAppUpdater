import Foundation

/// Everything the analyzer needs to know about one app, as plain values.
public struct AppAnalysisInput: Sendable {
    public let app: InstalledApp
    public let details: AppDetails?
    public let update: AvailableUpdate?
    public let lastUsedDate: Date?
    /// Team Identifier persisted from a previous scan (see `TeamIdentifierStoring`).
    public let previousTeamIdentifier: String?
    /// Gatekeeper verdict for the installed bundle (GatekeeperAssessor), if assessed.
    public let installedGatekeeperVerdict: GatekeeperVerdict?
    /// Gatekeeper verdict for the update's downloaded bundle, if assessed.
    public let updateGatekeeperVerdict: GatekeeperVerdict?
    /// Download host change reported by DownloadHostStore, if any.
    public let downloadHostChange: HostChange?
    /// Vendor updater owning the app (VendorManagementDetector), if any.
    public let vendorManagement: VendorManagement?

    public init(
        app: InstalledApp,
        details: AppDetails?,
        update: AvailableUpdate? = nil,
        lastUsedDate: Date? = nil,
        previousTeamIdentifier: String? = nil,
        installedGatekeeperVerdict: GatekeeperVerdict? = nil,
        updateGatekeeperVerdict: GatekeeperVerdict? = nil,
        downloadHostChange: HostChange? = nil,
        vendorManagement: VendorManagement? = nil
    ) {
        self.app = app
        self.details = details
        self.update = update
        self.lastUsedDate = lastUsedDate
        self.previousTeamIdentifier = previousTeamIdentifier
        self.installedGatekeeperVerdict = installedGatekeeperVerdict
        self.updateGatekeeperVerdict = updateGatekeeperVerdict
        self.downloadHostChange = downloadHostChange
        self.vendorManagement = vendorManagement
    }
}

/// Pure rules that turn app facts into `[AppWarning]`. No I/O; every dependency is injected.
public struct CompatibilityAnalyzer: Sendable {
    public static let defaultUnusedThresholdDays = 90

    public let currentSystemVersion: String
    public let unusedThresholdDays: Int
    private let comparator: VersionComparator

    public init(
        currentSystemVersion: String = CompatibilityAnalyzer.runningSystemVersion(),
        unusedThresholdDays: Int = CompatibilityAnalyzer.defaultUnusedThresholdDays,
        comparator: VersionComparator = VersionComparator()
    ) {
        self.currentSystemVersion = currentSystemVersion
        self.unusedThresholdDays = unusedThresholdDays
        self.comparator = comparator
    }

    /// "15.1.0" style version of the running macOS.
    public static func runningSystemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// All warnings for one app, most severe first.
    public func warnings(for input: AppAnalysisInput, now: Date = Date()) -> [AppWarning] {
        let candidates: [AppWarning.Kind?] = [
            input.details.flatMap(architectureWarning),
            input.update.flatMap(updateCompatibilityKind),
            input.details?.minimumSystemVersion.flatMap(appRequirementKind),
            input.details.flatMap { signatureKind($0.signature, previous: input.previousTeamIdentifier) },
            input.lastUsedDate.flatMap { usageKind(lastUsed: $0, now: now) },
            input.updateGatekeeperVerdict.flatMap { Self.notarizationKind($0, scope: .update) },
            input.installedGatekeeperVerdict.flatMap { Self.notarizationKind($0, scope: .installedApp) },
            input.downloadHostChange.map { .downloadHostChanged(previous: $0.previous, current: $0.current) },
            input.vendorManagement.map { .managedByVendor(updaterName: $0.updaterName) },
        ]
        return candidates
            .compactMap { $0.map(AppWarning.init) }
            .sorted { $0.severity > $1.severity }
    }

    /// Use before installing: non-nil means the update will not run on this Mac.
    public func updateCompatibilityWarning(for update: AvailableUpdate) -> AppWarning? {
        updateCompatibilityKind(update).map(AppWarning.init)
    }

    /// Use in the install pipeline after GatekeeperAssessor: non-nil (critical for `.update`) means
    /// the bundle is rejected or not notarized. `.notarized` and `.unknown` produce no warning.
    public func notarizationWarning(for verdict: GatekeeperVerdict, scope: GatekeeperScope) -> AppWarning? {
        Self.notarizationKind(verdict, scope: scope).map(AppWarning.init)
    }

    /// Informational warning for a host change reported by `DownloadHostStoring.check`.
    public func downloadHostWarning(for change: HostChange) -> AppWarning {
        AppWarning(.downloadHostChanged(previous: change.previous, current: change.current))
    }

    /// True when `required` is a strictly newer macOS than the running one.
    public func requiresNewerSystem(_ required: String) -> Bool {
        let trimmed = required.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return comparator.isNewer(trimmed, than: currentSystemVersion)
    }

    // MARK: Rules

    private func architectureWarning(_ details: AppDetails) -> AppWarning.Kind? {
        Self.isIntelOnly(details.executableArchitectures) ? .intelOnly : nil
    }

    /// Intel-only means an Intel slice exists and no arm64 slice does. Unknown (empty) is not flagged.
    public static func isIntelOnly(_ architectures: [String]) -> Bool {
        let normalized = Set(architectures.map { $0.lowercased() })
        let hasIntel = !normalized.isDisjoint(with: ["intel", "x86_64"])
        let hasARM = !normalized.isDisjoint(with: ["apple silicon", "arm64", "arm64e"])
        return hasIntel && !hasARM
    }

    private func updateCompatibilityKind(_ update: AvailableUpdate) -> AppWarning.Kind? {
        guard let required = update.minimumSystemVersion, requiresNewerSystem(required) else { return nil }
        return .updateRequiresNewerMacOS(required: required)
    }

    private func appRequirementKind(_ required: String) -> AppWarning.Kind? {
        requiresNewerSystem(required) ? .appRequiresNewerMacOS(required: required) : nil
    }

    private func signatureKind(_ signature: AppDetails.Signature, previous: String?) -> AppWarning.Kind? {
        switch signature {
        case .signed(let teamIdentifier):
            guard let previous, !previous.isEmpty, previous != teamIdentifier else { return nil }
            return .teamIdentifierChanged(old: previous, new: teamIdentifier)
        case .unsigned(let reason):
            return Self.isMissingSignature(reason) ? .unsigned : .signatureInvalid(reason: reason)
        }
    }

    /// `AppDetails` folds "no signature" and "broken signature" into one case; tell them apart by reason.
    static func isMissingSignature(_ reason: String) -> Bool {
        let lowered = reason.lowercased()
        let markers = ["not signed", "unsigned", "no team identifier", "ad-hoc", "adhoc"]
        return markers.contains { lowered.contains($0) }
    }

    static func notarizationKind(_ verdict: GatekeeperVerdict, scope: GatekeeperScope) -> AppWarning.Kind? {
        verdict.notNotarizedReason.map { .notNotarized(reason: $0, scope: scope) }
    }

    private func usageKind(lastUsed: Date, now: Date) -> AppWarning.Kind? {
        let days = Calendar(identifier: .gregorian).dateComponents([.day], from: lastUsed, to: now).day ?? 0
        return days > unusedThresholdDays ? .notOpenedInLongTime(days: days) : nil
    }
}
