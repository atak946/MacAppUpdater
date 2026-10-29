import Foundation

// MARK: - Kind

/// Where a launchd job lives, which decides its launchd domain and who may change it.
public enum StartupItemKind: String, Sendable, CaseIterable, Codable {
    /// `~/Library/LaunchAgents`: runs as the user, changeable without admin rights.
    case userAgent
    /// `/Library/LaunchAgents`: runs in every user session, owned by root.
    case globalAgent
    /// `/Library/LaunchDaemons`: runs as root in the system domain.
    case daemon

    /// True for the job types that run in a user's GUI session.
    public var isAgent: Bool { self != .daemon }
}

// MARK: - Schedule

/// When launchd starts a job besides `RunAtLoad` / `KeepAlive`.
public enum StartupSchedule: Sendable, Equatable {
    /// `StartInterval`, in seconds.
    case interval(seconds: Int)
    /// `StartCalendarInterval`; each entry maps keys such as `Hour` or `Weekday` to values.
    case calendar([[String: Int]])
}

// MARK: - Signature

/// Code signature of a job's executable.
public struct StartupSignature: Sendable, Equatable {
    /// Common name of the leaf signing certificate, e.g. "Developer ID Application: Google LLC (EQHXZ8M8AV)".
    public let signerName: String?
    public let teamID: String?
    /// Satisfies `anchor apple`: shipped by Apple itself.
    public let isApple: Bool
    /// Signed with a certificate identity (ad-hoc and missing signatures are not).
    public let isSigned: Bool

    public init(signerName: String?, teamID: String?, isApple: Bool, isSigned: Bool) {
        self.signerName = signerName
        self.teamID = teamID
        self.isApple = isApple
        self.isSigned = isSigned
    }

    public static let unsigned = StartupSignature(signerName: nil, teamID: nil, isApple: false, isSigned: false)
}

// MARK: - Item

/// One launchd job found on disk, with its resolved executable, owner, signature and state.
public struct StartupItem: Sendable, Identifiable, Equatable {
    /// The plist path.
    public let id: String
    public let plistURL: URL
    public let label: String
    public let kind: StartupItemKind
    public let executableURL: URL?
    public let arguments: [String]
    /// Owning app, when one could be found.
    public let appName: String?
    public let appBundleURL: URL?
    /// Nil when the executable is missing or could not be inspected.
    public let signature: StartupSignature?
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let schedule: StartupSchedule?
    /// Effective state: launchctl's override when present, otherwise the plist's `Disabled` key.
    public let isEnabled: Bool
    /// Bootstrapped into its launchd domain right now.
    public let isLoaded: Bool

    public init(
        plistURL: URL, label: String, kind: StartupItemKind, executableURL: URL?, arguments: [String],
        appName: String?, appBundleURL: URL?, signature: StartupSignature?, runAtLoad: Bool,
        keepAlive: Bool, schedule: StartupSchedule?, isEnabled: Bool, isLoaded: Bool
    ) {
        self.id = plistURL.path
        self.plistURL = plistURL
        self.label = label
        self.kind = kind
        self.executableURL = executableURL
        self.arguments = arguments
        self.appName = appName
        self.appBundleURL = appBundleURL
        self.signature = signature
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.schedule = schedule
        self.isEnabled = isEnabled
        self.isLoaded = isLoaded
    }

    /// Apple's own jobs are listed read-only and never changed.
    public var isAppleItem: Bool { Self.isAppleLabel(label) }
    public var isAppleSigned: Bool { signature?.isApple ?? false }
    /// No developer identity: unsigned or ad-hoc signed. Missing executables are not counted.
    public var isUnsigned: Bool { signature.map { !$0.isSigned } ?? false }
    /// Daemons run in the system domain, so changing them asks for an administrator password.
    /// Global agents (`/Library/LaunchAgents`) run in the user's session and don't.
    public var requiresAdmin: Bool { kind == .daemon }
    /// The user can enable or disable this job from the app (daemons after authenticating).
    public var isControllable: Bool { !isAppleItem }

    /// Copy with a new launchd state.
    public func with(isEnabled: Bool, isLoaded: Bool) -> StartupItem {
        StartupItem(
            plistURL: plistURL, label: label, kind: kind, executableURL: executableURL, arguments: arguments,
            appName: appName, appBundleURL: appBundleURL, signature: signature, runAtLoad: runAtLoad,
            keepAlive: keepAlive, schedule: schedule, isEnabled: isEnabled, isLoaded: isLoaded
        )
    }

    static func isAppleLabel(_ label: String) -> Bool {
        label.lowercased().hasPrefix("com.apple.")
    }
}

// MARK: - Background items

/// An app registered as a legacy "Open at Login" item.
public struct BackgroundLoginItem: Sendable, Equatable, Identifiable {
    public var id: String { url.path }
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

/// Result of a startup scan.
public struct StartupScanResult: Sendable, Equatable {
    public let items: [StartupItem]
    /// Login items from the legacy background-items file; nil when that file is absent or unreadable.
    public let loginItems: [BackgroundLoginItem]?

    public init(items: [StartupItem], loginItems: [BackgroundLoginItem]?) {
        self.items = items
        self.loginItems = loginItems
    }
}
