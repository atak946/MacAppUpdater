import AppKit
import Foundation

/// Who signed the bundle and whether other bundles claim its identifier.
/// A bundle ID is just an Info.plist string, so a planted look-alike can claim another app's ID.
public struct BundleIntegrity: Sendable, Hashable {
    /// Team ID from a valid code signature; nil when unsigned, ad-hoc signed or invalid.
    public let teamIdentifier: String?
    /// Why the signature could not be validated; nil when it is valid.
    public let signatureProblem: String?
    /// Other bundles on disk with the same bundle identifier.
    public let duplicateBundles: [URL]

    public init(teamIdentifier: String?, signatureProblem: String?, duplicateBundles: [URL]) {
        self.teamIdentifier = teamIdentifier
        self.signatureProblem = signatureProblem
        self.duplicateBundles = duplicateBundles
    }

    /// Not checked (e.g. plans built in tests or by callers without a verifier).
    public static let unverified = BundleIntegrity(teamIdentifier: nil, signatureProblem: nil, duplicateBundles: [])

    public var hasDuplicates: Bool { !duplicateBundles.isEmpty }
}

/// Result of the dry-run scan: the app bundle plus leftovers. Nothing has been touched yet.
public struct UninstallPlan: Sendable, Hashable {
    public let app: InstalledApp
    /// The `.app` bundle itself (kind `.appBundle`, confidence `.exact`).
    public let bundle: LeftoverItem
    public let leftovers: [LeftoverItem]
    public let integrity: BundleIntegrity

    public init(
        app: InstalledApp,
        bundle: LeftoverItem,
        leftovers: [LeftoverItem],
        integrity: BundleIntegrity = .unverified
    ) {
        self.app = app
        self.bundle = bundle
        self.leftovers = leftovers
        self.integrity = integrity
    }

    public var items: [LeftoverItem] { [bundle] + leftovers }

    /// App bundle + exact matches; possible matches start unchecked. When another bundle claims the
    /// same identifier, the leftovers may belong to that other app, so only the bundle is preselected.
    public var defaultSelection: Set<URL> {
        guard !integrity.hasDuplicates else { return [bundle.url] }
        return Set(items.filter { $0.confidence == .exact }.map(\.url))
    }

    public func totalSize(of selection: Set<URL>) -> Int64 {
        let paths = Set(selection.map(\.standardizedFileURL.path))
        return items.filter { paths.contains($0.url.path) }.reduce(0) { $0 + $1.sizeInBytes }
    }
}

/// What actually happened during `uninstall`.
public struct UninstallReport: Sendable, Hashable {
    public struct Trashed: Sendable, Hashable {
        public let item: LeftoverItem
        /// Location inside the Trash, when FileManager reports it.
        public let trashURL: URL?
    }

    public struct Failure: Sendable, Hashable {
        public let url: URL
        public let error: UninstallError
        public var reason: String { error.localizedDescription }
    }

    public let app: InstalledApp
    public let trashed: [Trashed]
    public let failures: [Failure]

    public var reclaimedBytes: Int64 { trashed.reduce(0) { $0 + $1.item.sizeInBytes } }
    public var removedAppBundle: Bool { trashed.contains { $0.item.kind == .appBundle } }
    public var succeeded: Bool { failures.isEmpty }
}

// MARK: - Dependencies

/// Reports whether an app is currently running.
public protocol RunningAppChecking: Sendable {
    func isRunning(bundleIdentifier: String) async -> Bool
}

public struct WorkspaceRunningAppChecker: RunningAppChecking {
    public init() {}

    public func isRunning(bundleIdentifier: String) async -> Bool {
        await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .contains { !$0.isTerminated }
        }
    }
}

/// Moves items to the Trash. Never deletes permanently.
public protocol Trashing: Sendable {
    /// Returns the item's new location in the Trash, if known.
    func trashItem(at url: URL) throws -> URL?
}

public struct FileManagerTrasher: Trashing {
    public init() {}

    public func trashItem(at url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}
