import Foundation
import os

/// Per-app outcome of a detailed check.
public struct UpdateCheckResult: Sendable, Hashable, Identifiable {
    public var id: String { app.bundleIdentifier }

    public let app: InstalledApp
    /// The source that recognised the app (the one reporting the update, otherwise the
    /// highest-priority source that matched). Nil when no source knows the app.
    public let matchedSource: UpdateSourceKind?
    /// Latest version reported by `matchedSource`, when known.
    public let latestVersion: String?
    public let update: AvailableUpdate?
    /// "<source>: <message>" for each source that failed.
    public let errors: [String]

    public init(
        app: InstalledApp,
        matchedSource: UpdateSourceKind?,
        latestVersion: String? = nil,
        update: AvailableUpdate?,
        errors: [String] = []
    ) {
        self.app = app
        self.matchedSource = matchedSource
        self.latestVersion = latestVersion
        self.update = update
        self.errors = errors
    }

    public var isUpToDate: Bool { matchedSource != nil && update == nil }
}

/// Runs all update sources against installed apps with bounded concurrency.
public struct UpdateChecker: Sendable {
    /// Sources are consulted in this order; the first one reporting an update wins.
    public static let sourcePriority: [UpdateSourceKind] = [.appStore, .sparkle, .electron, .vendor, .github, .homebrew]
    public static let defaultMaxConcurrency = 8

    private static let logger = Logger(subsystem: "com.macappupdater", category: "UpdateChecker")

    private let sources: [any UpdateSource]
    private let maxConcurrency: Int

    public init(sources: [any UpdateSource], maxConcurrency: Int = UpdateChecker.defaultMaxConcurrency) {
        self.sources = sources.enumerated()
            .sorted { lhs, rhs in
                let left = Self.priority(of: lhs.element.kind)
                let right = Self.priority(of: rhs.element.kind)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// Returns updates in the same order as `apps`.
    public func checkAll(_ apps: [InstalledApp]) async -> [AvailableUpdate] {
        await checkAllDetailed(apps).compactMap(\.update)
    }

    /// Returns one result per app, in the same order as `apps`.
    public func checkAllDetailed(_ apps: [InstalledApp]) async -> [UpdateCheckResult] {
        await withTaskGroup(of: (Int, UpdateCheckResult).self) { group in
            var pending = apps.enumerated().makeIterator()
            for _ in 0..<maxConcurrency {
                guard let (index, app) = pending.next() else { break }
                group.addTask { (index, await checkDetailed(app)) }
            }
            var results: [(Int, UpdateCheckResult)] = []
            while let next = await group.next() {
                results.append(next)
                if let (nextIndex, nextApp) = pending.next() {
                    group.addTask { (nextIndex, await checkDetailed(nextApp)) }
                }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Tries applicable sources in priority order; errors are logged and the next source is tried.
    public func check(_ app: InstalledApp) async -> AvailableUpdate? {
        await checkDetailed(app).update
    }

    /// Like `check`, but also reports which source recognised the app and any errors.
    public func checkDetailed(_ app: InstalledApp) async -> UpdateCheckResult {
        var firstMatch: (kind: UpdateSourceKind, latest: String?)?
        var errors: [String] = []
        for source in sources where source.canHandle(app) {
            if Task.isCancelled { break }
            do {
                switch try await Self.lookup(app, in: source) {
                case .update(let update):
                    return UpdateCheckResult(
                        app: app, matchedSource: source.kind, latestVersion: update.newVersion,
                        update: update, errors: errors
                    )
                case .upToDate(let latest):
                    firstMatch = firstMatch ?? (source.kind, latest)
                case .notFound:
                    break
                }
            } catch {
                errors.append("\(source.kind.rawValue): \(error.localizedDescription)")
                Self.logger.error(
                    "\(source.kind.rawValue, privacy: .public) check failed for \(app.bundleIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return UpdateCheckResult(
            app: app, matchedSource: firstMatch?.kind, latestVersion: firstMatch?.latest,
            update: nil, errors: errors
        )
    }

    /// Legacy sources without `SourceMatching` can only report "update" or "unknown".
    private static func lookup(_ app: InstalledApp, in source: any UpdateSource) async throws -> SourceLookup {
        if let matching = source as? any SourceMatching {
            return try await matching.lookup(app)
        }
        return try await source.checkForUpdate(app).map(SourceLookup.update) ?? .notFound
    }

    private static func priority(of kind: UpdateSourceKind) -> Int {
        sourcePriority.firstIndex(of: kind) ?? sourcePriority.count
    }
}
