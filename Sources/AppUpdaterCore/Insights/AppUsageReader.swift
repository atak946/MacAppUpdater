import CoreServices
import Foundation

/// Reads usage facts for an app bundle: last launch date and on-disk size.
public protocol AppUsageReading: Sendable {
    func lastUsedDate(of appURL: URL) -> Date?
    func bundleSize(of appURL: URL) -> Int64?
}

/// Spotlight-backed reader. Blocking file-system work; call it off the main actor.
public struct AppUsageReader: AppUsageReading {
    public init() {}

    /// `kMDItemLastUsedDate` from Spotlight, falling back to the bundle's content access date.
    public func lastUsedDate(of appURL: URL) -> Date? {
        spotlightLastUsedDate(of: appURL) ?? contentAccessDate(of: appURL)
    }

    public func bundleSize(of appURL: URL) -> Int64? {
        AppDetailsReader.directorySize(appURL)
    }

    private func spotlightLastUsedDate(of appURL: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, appURL as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    private func contentAccessDate(of appURL: URL) -> Date? {
        try? appURL.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
    }
}
