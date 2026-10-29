import Foundation

/// How urgently a warning deserves the user's attention. Ordered from least to most severe.
public enum WarningSeverity: Int, Sendable, Hashable, Comparable, CaseIterable {
    case info = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: WarningSeverity, rhs: WarningSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .info: String(coreLocalized: "Info")
        case .warning: String(coreLocalized: "Warning")
        case .critical: String(coreLocalized: "Critical")
        }
    }
}

/// A compatibility, security or hygiene issue detected for one installed app.
public struct AppWarning: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// The executable has no arm64 slice and runs through Rosetta 2.
        case intelOnly
        /// The available update needs a newer macOS than the one running.
        case updateRequiresNewerMacOS(required: String)
        /// The installed app itself declares a newer LSMinimumSystemVersion than the running macOS.
        case appRequiresNewerMacOS(required: String)
        /// No usable code signature (ad-hoc or not signed at all).
        case unsigned
        /// A signature exists but fails validation.
        case signatureInvalid(reason: String)
        /// The signing team differs from the last one seen for this bundle identifier.
        case teamIdentifierChanged(old: String, new: String)
        /// The app has not been launched for `days` days.
        case notOpenedInLongTime(days: Int)
        /// Gatekeeper (`spctl --assess`) rejected the bundle. Critical for an update's new
        /// bundle (do not install), informational for an already-installed app.
        case notNotarized(reason: String, scope: GatekeeperScope)
        /// The download host differs from the one used by earlier updates (possible hijacked feed).
        case downloadHostChanged(previous: String, current: String)
        /// A vendor tool (Setapp, Creative Cloud, MAU, …) owns this app's updates.
        case managedByVendor(updaterName: String)
    }

    public let kind: Kind
    public let severity: WarningSeverity
    public let title: String
    public let explanation: String
    public let suggestedAction: String

    public var id: String { String(describing: kind) }

    public init(kind: Kind, severity: WarningSeverity, title: String, explanation: String, suggestedAction: String) {
        self.kind = kind
        self.severity = severity
        self.title = title
        self.explanation = explanation
        self.suggestedAction = suggestedAction
    }

    /// Builds the warning with its canonical severity and copy.
    public init(_ kind: Kind) {
        let copy = Self.copy(for: kind)
        self.init(
            kind: kind,
            severity: copy.severity,
            title: copy.title,
            explanation: copy.explanation,
            suggestedAction: copy.action
        )
    }

    /// SF Symbol suitable for list rows and badges.
    public var symbolName: String {
        switch kind {
        case .intelOnly: "cpu"
        case .updateRequiresNewerMacOS, .appRequiresNewerMacOS: "macwindow.badge.plus"
        case .unsigned: "seal"
        case .signatureInvalid: "xmark.seal.fill"
        case .teamIdentifierChanged: "person.badge.shield.exclamationmark"
        case .notOpenedInLongTime: "moon.zzz"
        case .notNotarized: "checkmark.shield"
        case .downloadHostChanged: "network.badge.shield.half.filled"
        case .managedByVendor: "arrow.triangle.2.circlepath.circle"
        }
    }
}

// MARK: - Copy

extension AppWarning {
    private struct Copy {
        let severity: WarningSeverity
        let title: String
        let explanation: String
        let action: String
    }

    private static func copy(for kind: Kind) -> Copy {
        switch kind {
        case .intelOnly:
            Copy(
                severity: .warning,
                title: String(coreLocalized: "Intel-only app"),
                explanation: String(coreLocalized: "Needs Rosetta 2; Apple is phasing out Rosetta."),
                action: String(coreLocalized: "Check whether the developer offers an Apple Silicon or Universal build.")
            )
        case .updateRequiresNewerMacOS(let required):
            Copy(
                severity: .critical,
                title: String(coreLocalized: "Update requires macOS \(required)"),
                explanation: String(coreLocalized: "The new version will not launch on the macOS version you are running."),
                action: String(coreLocalized: "Upgrade macOS before installing, or keep the current version.")
            )
        case .appRequiresNewerMacOS(let required):
            Copy(
                severity: .warning,
                title: String(coreLocalized: "Requires macOS \(required)"),
                explanation: String(coreLocalized: "This app declares a newer minimum macOS than the one running and may fail to launch."),
                action: String(coreLocalized: "Upgrade macOS or install an older release of the app.")
            )
        case .unsigned:
            Copy(
                severity: .warning,
                title: String(coreLocalized: "Not signed"),
                explanation: String(coreLocalized: "The app has no developer signature, so its origin cannot be verified."),
                action: String(coreLocalized: "Only keep it if you trust where it came from; prefer an official signed download.")
            )
        case .signatureInvalid(let reason):
            Copy(
                severity: .critical,
                title: String(coreLocalized: "Invalid signature"),
                explanation: String(coreLocalized: "The code signature failed validation: \(reason)"),
                action: String(coreLocalized: "The bundle may be damaged or modified. Reinstall it from the developer's site.")
            )
        case .teamIdentifierChanged(let old, let new):
            Copy(
                severity: .critical,
                title: String(coreLocalized: "Developer changed"),
                explanation: String(coreLocalized: "Signed by team \(new), but was previously signed by \(old)."),
                action: String(coreLocalized: "Confirm the developer legitimately changed before trusting this build.")
            )
        case .notOpenedInLongTime(let days):
            Copy(
                severity: .info,
                title: String(coreLocalized: "Unused for \(days) days"),
                explanation: String(coreLocalized: "You have not opened this app in \(days) days."),
                action: String(coreLocalized: "Consider removing it to free disk space and reduce update work.")
            )
        case .notNotarized(let reason, let scope):
            notarizationCopy(reason: reason, scope: scope)
        case .downloadHostChanged(let previous, let current):
            Copy(
                severity: .info,
                title: String(coreLocalized: "Download host changed"),
                explanation: String(coreLocalized: "This update downloads from \(current); earlier updates came from \(previous)."),
                action: String(coreLocalized: "Usually a CDN move. If the host looks unfamiliar, verify the release on the developer's site.")
            )
        case .managedByVendor(let updaterName):
            Copy(
                severity: .info,
                title: String(coreLocalized: "Managed by \(updaterName)"),
                explanation: String(coreLocalized: "\(updaterName) installs updates for this app; updating it here could break licensing or conflict."),
                action: String(coreLocalized: "Open \(updaterName) to update this app.")
            )
        }
    }

    private static func notarizationCopy(reason: String, scope: GatekeeperScope) -> Copy {
        switch scope {
        case .update:
            Copy(
                severity: .critical,
                title: String(coreLocalized: "Update not notarized"),
                explanation: String(coreLocalized: "Gatekeeper rejected the downloaded update: \(reason)"),
                action: String(coreLocalized: "Do not install it unless you trust the source; check the developer's site for a notarized build.")
            )
        case .installedApp:
            Copy(
                severity: .info,
                title: String(coreLocalized: "Not notarized"),
                explanation: String(coreLocalized: "Gatekeeper does not accept this app: \(reason)"),
                action: String(coreLocalized: "Common for older or hobby apps. Prefer a notarized release when one exists.")
            )
        }
    }
}
