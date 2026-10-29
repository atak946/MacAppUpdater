import Foundation

/// Thresholds and limits used by `FileSystemCleanupScanner`. Defaults match the product rules.
public struct CleanupScanConfiguration: Sendable, Hashable {
    // MARK: Constants

    /// One mebibyte in bytes.
    public static let megabyte: Int64 = 1_024 * 1_024
    /// One day in seconds.
    public static let day: TimeInterval = 86_400

    // MARK: Thresholds

    /// Cache folders smaller than this are not worth listing.
    public var minimumCacheSize: Int64
    /// Diagnostic reports must be at least this old.
    public var diagnosticReportMinimumAge: TimeInterval
    /// Installers in Downloads must be at least this old.
    public var installerMinimumAge: TimeInterval
    /// Minimum size of a "large" file.
    public var largeFileMinimumSize: Int64
    /// A large file must not have been opened for at least this long.
    public var largeFileMinimumIdleAge: TimeInterval

    // MARK: Limits

    /// Maximum folder depth below home explored for large files.
    public var largeFileMaximumDepth: Int
    /// Maximum number of entries visited while looking for large files.
    public var largeFileMaximumVisitedEntries: Int

    /// Creates a configuration; every parameter has the production default.
    public init(
        minimumCacheSize: Int64 = 1 * megabyte,
        diagnosticReportMinimumAge: TimeInterval = 7 * day,
        installerMinimumAge: TimeInterval = 30 * day,
        largeFileMinimumSize: Int64 = 500 * megabyte,
        largeFileMinimumIdleAge: TimeInterval = 180 * day,
        largeFileMaximumDepth: Int = 12,
        largeFileMaximumVisitedEntries: Int = 250_000
    ) {
        self.minimumCacheSize = minimumCacheSize
        self.diagnosticReportMinimumAge = diagnosticReportMinimumAge
        self.installerMinimumAge = installerMinimumAge
        self.largeFileMinimumSize = largeFileMinimumSize
        self.largeFileMinimumIdleAge = largeFileMinimumIdleAge
        self.largeFileMaximumDepth = largeFileMaximumDepth
        self.largeFileMaximumVisitedEntries = largeFileMaximumVisitedEntries
    }
}
