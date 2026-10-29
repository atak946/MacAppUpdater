import Foundation

// Public contract shared by the cleanup engine and the Cleanup screen.
// Change only additively: the UI is built against these shapes.

/// A kind of reclaimable space. Titles and descriptions are localized in the app target.
public enum CleanupCategory: String, CaseIterable, Sendable, Codable, Hashable {
    /// `~/Library/Caches` of apps (not system or this app's own cache).
    case userCaches
    /// `~/Library/Logs` and app crash/diagnostic logs older than a few days.
    case logs
    /// Xcode `DerivedData`.
    case xcodeDerivedData
    /// Xcode `Archives` (only listed, never auto-selected).
    case xcodeArchives
    /// `~/Library/Developer/Xcode/iOS DeviceSupport` (and watchOS/tvOS) entries.
    case deviceSupport
    /// CoreSimulator caches and unavailable simulator devices.
    case simulatorCaches
    /// npm, yarn, pnpm, Gradle, NuGet, CocoaPods, SwiftPM and Homebrew download caches.
    case packageManagerCaches
    /// Items in the user's Trash.
    case trash
    /// `.dmg` / `.pkg` / `.zip` installers in Downloads older than the age threshold.
    case oldInstallers
    /// Files above the size threshold not opened for a long time (home folder, outside Library).
    case largeOldFiles

    /// Whether the category's items start out selected after a scan. Risky ones are opt-in.
    public var isSelectedByDefault: Bool {
        switch self {
        case .userCaches, .logs, .xcodeDerivedData, .simulatorCaches, .packageManagerCaches, .trash: true
        case .xcodeArchives, .deviceSupport, .oldInstallers, .largeOldFiles: false
        }
    }
}

/// One removable file or folder found by a scan.
public struct CleanupItem: Identifiable, Sendable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let category: CleanupCategory
    /// File name, or a friendlier label such as "Xcode — DerivedData/MyApp-abc".
    public let displayName: String
    /// Allocated size on disk, including folder contents.
    public let sizeInBytes: Int64
    public let lastAccessed: Date?
    /// Bundle identifier of the app owning a cache, when known (used for icons).
    public let ownerBundleIdentifier: String?

    public init(
        url: URL,
        category: CleanupCategory,
        displayName: String,
        sizeInBytes: Int64,
        lastAccessed: Date? = nil,
        ownerBundleIdentifier: String? = nil
    ) {
        self.url = url
        self.category = category
        self.displayName = displayName
        self.sizeInBytes = sizeInBytes
        self.lastAccessed = lastAccessed
        self.ownerBundleIdentifier = ownerBundleIdentifier
    }
}

/// All items of one category, largest first.
public struct CleanupGroup: Identifiable, Sendable, Hashable {
    public var id: CleanupCategory { category }
    public let category: CleanupCategory
    public let items: [CleanupItem]
    public var totalSize: Int64 { items.reduce(0) { $0 + $1.sizeInBytes } }

    public init(category: CleanupCategory, items: [CleanupItem]) {
        self.category = category
        self.items = items
    }
}

/// Result of a scan; groups are ordered by total size, empty categories omitted.
public struct CleanupScanReport: Sendable, Hashable {
    public let groups: [CleanupGroup]
    public let scannedAt: Date
    public var totalSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }

    public init(groups: [CleanupGroup], scannedAt: Date) {
        self.groups = groups
        self.scannedAt = scannedAt
    }
}

/// Reported while scanning, one category at a time.
public struct CleanupScanProgress: Sendable, Hashable {
    public let category: CleanupCategory
    /// 0...1 over all requested categories.
    public let fractionCompleted: Double

    public init(category: CleanupCategory, fractionCompleted: Double) {
        self.category = category
        self.fractionCompleted = fractionCompleted
    }
}

public protocol CleanupScanning: Sendable {
    func scan(
        categories: Set<CleanupCategory>,
        progress: @escaping @Sendable (CleanupScanProgress) -> Void
    ) async throws -> CleanupScanReport
}

/// An item that could not be removed and why.
public struct CleanupFailure: Sendable, Hashable {
    public let item: CleanupItem
    public let reason: String

    public init(item: CleanupItem, reason: String) {
        self.item = item
        self.reason = reason
    }
}

public struct CleanupResult: Sendable, Hashable {
    public let removed: [CleanupItem]
    public let failed: [CleanupFailure]
    public var reclaimedBytes: Int64 { removed.reduce(0) { $0 + $1.sizeInBytes } }

    public init(removed: [CleanupItem], failed: [CleanupFailure]) {
        self.removed = removed
        self.failed = failed
    }
}

/// Removes items. Implementations move to the Trash (recoverable) except for the Trash category itself.
public protocol CleanupPerforming: Sendable {
    func clean(_ items: [CleanupItem]) async -> CleanupResult
}
