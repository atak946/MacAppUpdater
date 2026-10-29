import Foundation

/// Reads an application bundle's Info.plist directly from disk (bypassing `Bundle` caching,
/// so freshly updated apps report their new version).
public struct BundleInfoReader: Sendable {
    public init() {}

    /// Builds an `InstalledApp` from the bundle at `appURL`.
    /// - Throws: `UpdaterError.invalidBundle` when the plist is unreadable or lacks an id/version.
    public func read(appAt appURL: URL) throws -> InstalledApp {
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let info = try readInfoPlist(at: contentsURL.appendingPathComponent("Info.plist"), appURL: appURL)

        guard let bundleIdentifier = Self.string(info["CFBundleIdentifier"]),
              let shortVersion = Self.string(info["CFBundleShortVersionString"])
                ?? Self.string(info["CFBundleVersion"])
        else {
            throw UpdaterError.invalidBundle(appURL)
        }

        let name = Self.string(info["CFBundleDisplayName"])
            ?? Self.string(info["CFBundleName"])
            ?? appURL.deletingPathExtension().lastPathComponent
        let receiptPath = contentsURL.appendingPathComponent("_MASReceipt/receipt").path

        return InstalledApp(
            bundleIdentifier: bundleIdentifier,
            name: name,
            url: appURL,
            shortVersion: shortVersion,
            buildVersion: Self.string(info["CFBundleVersion"]),
            sparkleFeedURL: Self.feedURL(info["SUFeedURL"]),
            isFromAppStore: FileManager.default.fileExists(atPath: receiptPath)
        )
    }

    private func readInfoPlist(at plistURL: URL, appURL: URL) throws -> [String: Any] {
        do {
            let data = try Data(contentsOf: plistURL)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let info = plist as? [String: Any] else { throw UpdaterError.invalidBundle(appURL) }
            return info
        } catch let error as UpdaterError {
            throw error
        } catch {
            throw UpdaterError.invalidBundle(appURL)
        }
    }

    /// Non-empty trimmed string; tolerates numeric plist values (some apps store versions as numbers).
    private static func string(_ value: Any?) -> String? {
        let raw: String? = switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func feedURL(_ value: Any?) -> URL? {
        guard let string = string(value), let url = URL(string: string), url.scheme != nil else { return nil }
        return url
    }
}
