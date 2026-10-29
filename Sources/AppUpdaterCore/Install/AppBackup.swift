import Foundation

/// A copy of a previously installed app bundle, kept so an update can be rolled back.
public struct AppBackup: Sendable, Hashable, Identifiable, Codable {
    public var id: String { bundleURL.path }

    public let bundleIdentifier: String
    public let appName: String
    /// CFBundleShortVersionString of the backed-up bundle.
    public let version: String
    public let createdAt: Date
    /// Location of the backed-up `.app` bundle.
    public let bundleURL: URL

    public init(bundleIdentifier: String, appName: String, version: String, createdAt: Date, bundleURL: URL) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.version = version
        self.createdAt = createdAt
        self.bundleURL = bundleURL
    }
}

/// How many backups are kept and for how long.
public struct BackupRetentionPolicy: Sendable, Equatable {
    public static let defaultMaxAge: TimeInterval = 14 * 24 * 60 * 60
    public static let `default` = BackupRetentionPolicy()

    /// Newest backups kept per bundle identifier (at least 1).
    public let maxBackupsPerApp: Int
    /// Backups older than this are deleted when pruning.
    public let maxAge: TimeInterval

    public init(maxBackupsPerApp: Int = 1, maxAge: TimeInterval = BackupRetentionPolicy.defaultMaxAge) {
        self.maxBackupsPerApp = max(1, maxBackupsPerApp)
        self.maxAge = maxAge
    }
}

/// Creates, lists, restores and deletes app backups.
public protocol AppBackupStoring: Sendable {
    /// Copies the installed bundle into the backup area and applies retention for that app.
    @discardableResult
    func backUp(_ app: InstalledApp) async throws -> AppBackup
    /// Backups for `bundleIdentifier`, newest first.
    func backups(for bundleIdentifier: String) async throws -> [AppBackup]
    /// Verifies the backup, quits the running app, atomically swaps the backup in place of
    /// `app.url`, relaunches when configured, and removes the consumed backup.
    func restore(_ backup: AppBackup, over app: InstalledApp) async throws
    func delete(_ backup: AppBackup) async throws
    /// Applies the retention policy to every app (call at launch).
    func pruneAll() async throws
}
