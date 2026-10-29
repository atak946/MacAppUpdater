import AppKit
import CoreServices
import Foundation
import os

/// Finds apps and when they were last opened; injectable so the auditor is testable.
public protocol AppLocating: Sendable {
    func applicationURL(forBundleIdentifier identifier: String) -> URL?
    func lastUsedDate(of url: URL) -> Date?
}

/// Launch Services + Spotlight (`kMDItemLastUsedDate`, falling back to the bundle's access date).
public struct WorkspaceAppLocator: AppLocating {
    public init() {}

    public func applicationURL(forBundleIdentifier identifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }

    public func lastUsedDate(of url: URL) -> Date? {
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
            return date
        }
        return try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
    }
}

/// Pure flag rules for a granted permission.
public enum PermissionFlagger {
    public static let unusedThreshold: TimeInterval = 90 * 86_400

    public static func flags(isAllowed: Bool, isInstalled: Bool, lastUsed: Date?, now: Date) -> Set<PermissionFlag> {
        guard isAllowed else { return [] }
        guard isInstalled else { return [.notInstalled] }
        if let lastUsed, now.timeIntervalSince(lastUsed) > unusedThreshold { return [.unused] }
        return []
    }
}

/// Reads the user and system TCC databases and turns their rows into per-app permission entries.
public struct TCCPermissionAuditor: PermissionAuditing {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "PermissionAuditor")

    private let userDatabase: URL
    private let systemDatabase: URL
    private let locator: any AppLocating
    private let now: @Sendable () -> Date

    public init(
        userDatabase: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.TCC/TCC.db"),
        systemDatabase: URL = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db"),
        locator: any AppLocating = WorkspaceAppLocator(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.userDatabase = userDatabase
        self.systemDatabase = systemDatabase
        self.locator = locator
        self.now = now
    }

    public func audit() async -> PermissionAudit {
        let records: [TCCRecord]
        do {
            records = try TCCDatabaseReader.read(userDatabase)
        } catch {
            Self.logger.notice("User TCC database unreadable: \(String(describing: error), privacy: .public)")
            return .needsFullDiskAccess
        }
        // Screen Recording, Accessibility and Full Disk Access live in the system database.
        let systemRecords = (try? TCCDatabaseReader.read(systemDatabase)) ?? []
        return .entries(entries(from: records + systemRecords))
    }

    /// Merges duplicate rows (Automation has one per target app) and resolves apps.
    func entries(from records: [TCCRecord]) -> [PermissionEntry] {
        var merged: [String: TCCRecord] = [:]
        for record in records where PrivacyService(rawValue: record.service) != nil {
            let key = record.service + "|" + record.client
            guard let existing = merged[key] else {
                merged[key] = record
                continue
            }
            merged[key] = TCCRecord(
                service: record.service, client: record.client, clientType: record.clientType,
                isAllowed: existing.isAllowed || record.isAllowed,
                lastModified: [existing.lastModified, record.lastModified].compactMap { $0 }.max()
            )
        }
        let date = now()
        return merged.values
            .compactMap { entry(for: $0, now: date) }
            .sorted { ($0.service.rawValue, $0.appName.lowercased()) < ($1.service.rawValue, $1.appName.lowercased()) }
    }

    private func entry(for record: TCCRecord, now: Date) -> PermissionEntry? {
        guard let service = PrivacyService(rawValue: record.service) else { return nil }
        let isPath = record.clientType == 1
        let url: URL? = isPath
            ? (FileManager.default.fileExists(atPath: record.client) ? URL(fileURLWithPath: record.client) : nil)
            : locator.applicationURL(forBundleIdentifier: record.client)
        // Only app bundles have a meaningful "last opened" date.
        let lastUsed = url.flatMap { $0.pathExtension == "app" ? locator.lastUsedDate(of: $0) : nil }
        return PermissionEntry(
            service: service,
            client: record.client,
            isPath: isPath,
            isAllowed: record.isAllowed,
            lastModified: record.lastModified,
            appName: Self.displayName(client: record.client, isPath: isPath, url: url),
            appURL: url,
            lastUsed: lastUsed,
            flags: PermissionFlagger.flags(isAllowed: record.isAllowed, isInstalled: url != nil, lastUsed: lastUsed, now: now)
        )
    }

    static func displayName(client: String, isPath: Bool, url: URL?) -> String {
        if let url {
            let bundle = Bundle(url: url)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            return name ?? url.deletingPathExtension().lastPathComponent
        }
        return isPath ? URL(fileURLWithPath: client).lastPathComponent : client
    }
}
