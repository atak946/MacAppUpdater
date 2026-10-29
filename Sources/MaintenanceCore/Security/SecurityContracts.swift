import Foundation

// MARK: - System checks

/// A macOS protection the Security screen checks.
public enum SecurityCheckKind: String, CaseIterable, Sendable, Hashable, Identifiable {
    case fileVault
    case firewall
    case firewallStealth
    case systemIntegrityProtection
    case gatekeeper
    case automaticUpdates
    case screenLock
    case remoteLogin
    case xprotect

    public var id: String { rawValue }

    /// How much a weak setting matters.
    public var severity: SecuritySeverity {
        switch self {
        case .fileVault, .systemIntegrityProtection: .critical
        case .gatekeeper, .firewall, .automaticUpdates: .high
        case .screenLock, .remoteLogin: .medium
        case .firewallStealth, .xprotect: .low
        }
    }

    /// Points this check contributes to the 0...100 score; the weights add up to 100.
    public var weight: Int {
        switch self {
        case .fileVault, .systemIntegrityProtection: 20
        case .gatekeeper: 15
        case .firewall: 12
        case .automaticUpdates, .screenLock: 10
        case .remoteLogin, .xprotect: 5
        case .firewallStealth: 3
        }
    }

    /// True when the protection is safe while switched *off* (e.g. Remote Login).
    public var isSafeWhenOff: Bool { self == .remoteLogin }
}

/// Importance of a check, highest last.
public enum SecuritySeverity: Int, Sendable, Comparable, Hashable {
    case low, medium, high, critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Raw state of a setting as read from the system.
public enum SecurityCheckStatus: String, Sendable, Hashable {
    case on
    case off
    /// Couldn't be read (needs admin rights, tool missing, unexpected output).
    case unknown
}

/// Outcome of one check.
public struct SecurityCheckResult: Sendable, Hashable, Identifiable {
    public let kind: SecurityCheckKind
    public let status: SecurityCheckStatus
    /// Extra machine-readable detail, e.g. the XProtect version or "5 seconds" for screen lock.
    public let detail: String?
    /// Relevant date, e.g. when XProtect definitions were last updated.
    public let date: Date?

    public var id: SecurityCheckKind { kind }
    public var severity: SecuritySeverity { kind.severity }

    /// Nil when the status is unknown.
    public var isSecure: Bool? {
        switch status {
        case .unknown: nil
        case .on: !kind.isSafeWhenOff
        case .off: kind.isSafeWhenOff
        }
    }

    public init(kind: SecurityCheckKind, status: SecurityCheckStatus, detail: String? = nil, date: Date? = nil) {
        self.kind = kind
        self.status = status
        self.detail = detail
        self.date = date
    }
}

/// All checks of one run plus the weighted score.
public struct SecurityReport: Sendable, Hashable {
    public let results: [SecurityCheckResult]
    public let checkedAt: Date

    public init(results: [SecurityCheckResult], checkedAt: Date) {
        self.results = results
        self.checkedAt = checkedAt
    }

    /// 0...100, or nil when nothing could be read.
    public var score: Int? { SecurityScore.score(for: results) }

    /// Insecure checks, most severe first.
    public var issues: [SecurityCheckResult] {
        results.filter { $0.isSecure == false }.sorted { $0.severity > $1.severity }
    }
}

/// Runs the system health checks.
public protocol SecurityChecking: Sendable {
    func runChecks() async -> SecurityReport
}

// MARK: - Privacy permissions

/// Privacy services stored in the TCC databases.
public enum PrivacyService: String, CaseIterable, Sendable, Hashable, Identifiable {
    case camera = "kTCCServiceCamera"
    case microphone = "kTCCServiceMicrophone"
    case screenCapture = "kTCCServiceScreenCapture"
    case accessibility = "kTCCServiceAccessibility"
    case fullDiskAccess = "kTCCServiceSystemPolicyAllFiles"
    case inputMonitoring = "kTCCServiceListenEvent"
    case contacts = "kTCCServiceAddressBook"
    case calendar = "kTCCServiceCalendar"
    case photos = "kTCCServicePhotos"
    case automation = "kTCCServiceAppleEvents"

    public var id: String { rawValue }
}

/// Why a granted permission deserves a look.
public enum PermissionFlag: String, Sendable, Hashable, CaseIterable {
    /// The app that holds the permission is no longer on this Mac.
    case notInstalled
    /// The app hasn't been opened for `PermissionFlagger.unusedThreshold`.
    case unused
}

/// One app's permission for one service, merged across TCC databases.
public struct PermissionEntry: Sendable, Hashable, Identifiable {
    public let service: PrivacyService
    /// Bundle identifier or absolute path, as stored in TCC.
    public let client: String
    public let isPath: Bool
    public let isAllowed: Bool
    public let lastModified: Date?
    public let appName: String
    /// Installed location; nil when the app can't be found.
    public let appURL: URL?
    public let lastUsed: Date?
    public let flags: Set<PermissionFlag>

    public var id: String { service.rawValue + "|" + client }

    public init(
        service: PrivacyService, client: String, isPath: Bool, isAllowed: Bool, lastModified: Date?,
        appName: String, appURL: URL?, lastUsed: Date?, flags: Set<PermissionFlag>
    ) {
        self.service = service
        self.client = client
        self.isPath = isPath
        self.isAllowed = isAllowed
        self.lastModified = lastModified
        self.appName = appName
        self.appURL = appURL
        self.lastUsed = lastUsed
        self.flags = flags
    }
}

/// Result of reading the TCC databases.
public enum PermissionAudit: Sendable, Hashable {
    case entries([PermissionEntry])
    /// The user TCC database is unreadable: the app lacks Full Disk Access.
    case needsFullDiskAccess
}

/// Reads privacy permissions.
public protocol PermissionAuditing: Sendable {
    func audit() async -> PermissionAudit
}
