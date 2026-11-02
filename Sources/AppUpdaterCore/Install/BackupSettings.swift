import Foundation

/// User settings for update backups, stored in `UserDefaults`.
public enum BackupSettings {
    /// Bool, default true: copy the installed app before replacing it, so the update can be undone.
    public static let enabledKey = "backupsEnabled"
    /// Int days, default 14: backups older than this are deleted when pruning.
    public static let retentionDaysKey = "backupRetentionDays"
    /// Choices offered in Settings.
    public static let retentionDayChoices = [3, 7, 14, 30]
    public static let defaultRetentionDays = 14

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Stored days, falling back to the default for a missing or non-positive value.
    public static func retentionDays(in defaults: UserDefaults) -> Int {
        let days = defaults.integer(forKey: retentionDaysKey)
        return days > 0 ? days : defaultRetentionDays
    }

    public static func retention(in defaults: UserDefaults) -> BackupRetentionPolicy {
        BackupRetentionPolicy(maxAge: TimeInterval(retentionDays(in: defaults)) * 24 * 60 * 60)
    }
}
