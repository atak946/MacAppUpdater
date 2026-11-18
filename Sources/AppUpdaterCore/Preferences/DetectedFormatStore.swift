import Foundation

/// Remembers which package format an extension-less download turned out to be, per app and
/// download host (`com.foo.app|downloads.foo.com` → `dmg`). Once a format is known, the next
/// update from the same host can take the regular path: shown as "Update", included in
/// "Update All" and, for dmg/zip/tar, eligible for unattended installs. Every download is
/// still identified by its bytes before anything is installed (`PackageSniffer`).
public protocol DetectedFormatStoring: Sendable {
    func format(for update: AvailableUpdate) -> PackageFormat?
    func record(_ format: PackageFormat, for update: AvailableUpdate)
}

public final class UserDefaultsDetectedFormatStore: DetectedFormatStoring, @unchecked Sendable {
    public static let defaultKey = "install.detectedFormats"

    // UserDefaults is thread-safe; the lock only makes read-modify-write atomic.
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsDetectedFormatStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func format(for update: AvailableUpdate) -> PackageFormat? {
        guard let entryKey = Self.entryKey(for: update) else { return nil }
        let raw = lock.withLock { storedMap()[entryKey] }
        return raw.flatMap(PackageFormat.init(rawValue:)).flatMap { $0 == .unknown ? nil : $0 }
    }

    public func record(_ format: PackageFormat, for update: AvailableUpdate) {
        guard format != .unknown, let entryKey = Self.entryKey(for: update) else { return }
        lock.withLock {
            defaults.set(storedMap().merging([entryKey: format.rawValue]) { _, new in new }, forKey: key)
        }
    }

    /// Nil without a host: the format is only trusted for the same server.
    static func entryKey(for update: AvailableUpdate) -> String? {
        guard let host = update.downloadURL.host?.lowercased(), !host.isEmpty else { return nil }
        return "\(update.app.bundleIdentifier)|\(host)"
    }

    private func storedMap() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
