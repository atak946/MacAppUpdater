import Foundation
import os

/// Extra information about an installed app, shown in the detail window.
public struct AppDetails: Sendable, Equatable {
    public enum Signature: Sendable, Equatable {
        case signed(teamIdentifier: String)
        case unsigned(reason: String)
    }

    public let sizeInBytes: Int64?
    public let modifiedAt: Date?
    public let minimumSystemVersion: String?
    public let copyright: String?
    public let category: String?
    public let executableArchitectures: [String]
    public let signature: Signature

    public init(
        sizeInBytes: Int64?,
        modifiedAt: Date?,
        minimumSystemVersion: String?,
        copyright: String?,
        category: String?,
        executableArchitectures: [String],
        signature: Signature
    ) {
        self.sizeInBytes = sizeInBytes
        self.modifiedAt = modifiedAt
        self.minimumSystemVersion = minimumSystemVersion
        self.copyright = copyright
        self.category = category
        self.executableArchitectures = executableArchitectures
        self.signature = signature
    }
}

/// Reads `AppDetails` off the main actor: Info.plist extras, bundle size and code signature.
public struct AppDetailsReader: Sendable {
    private let verifier: any SignatureVerifying
    private let logger = Logger(subsystem: "com.macappupdater", category: "AppDetailsReader")

    public init(verifier: any SignatureVerifying = CodeSignatureVerifier()) {
        self.verifier = verifier
    }

    public func details(for app: InstalledApp) async -> AppDetails {
        let url = app.url
        let info = await Task.detached(priority: .utility) { Self.readStaticInfo(appURL: url) }.value
        return AppDetails(
            sizeInBytes: info.size,
            modifiedAt: info.modifiedAt,
            minimumSystemVersion: info.plist["LSMinimumSystemVersion"] as? String,
            copyright: info.plist["NSHumanReadableCopyright"] as? String,
            category: (info.plist["LSApplicationCategoryType"] as? String).map(Self.categoryName),
            executableArchitectures: Self.architectures(appURL: url),
            signature: await signature(of: url)
        )
    }

    private func signature(of url: URL) async -> AppDetails.Signature {
        do {
            return .signed(teamIdentifier: try await verifier.teamIdentifier(of: url))
        } catch {
            logger.info(
                """
                No valid signature for \(url.lastPathComponent, privacy: .public) \
                (\(url.path, privacy: .private)): \(error.localizedDescription, privacy: .private)
                """
            )
            return .unsigned(reason: error.localizedDescription)
        }
    }

    // MARK: Static helpers

    private struct StaticInfo: @unchecked Sendable {
        let plist: [String: Any]
        let size: Int64?
        let modifiedAt: Date?
    }

    private static func readStaticInfo(appURL: URL) -> StaticInfo {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let plist = (try? Data(contentsOf: plistURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let modifiedAt = try? appURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return StaticInfo(plist: plist, size: directorySize(appURL), modifiedAt: modifiedAt)
    }

    /// Sum of allocated sizes of every file in the bundle.
    static func directorySize(_ url: URL) -> Int64? {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return nil
        }
        return enumerator.compactMap { $0 as? URL }.reduce(Int64(0)) { total, fileURL in
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return total }
            return total + Int64(values?.totalFileAllocatedSize ?? 0)
        }
    }

    static func architectures(appURL: URL) -> [String] {
        guard let types = Bundle(url: appURL)?.executableArchitectures else { return [] }
        return types.compactMap { type in
            switch type.intValue {
            case NSBundleExecutableArchitectureARM64: "Apple Silicon"
            case NSBundleExecutableArchitectureX86_64: "Intel"
            default: nil
            }
        }
    }

    /// "public.app-category.developer-tools" → "Developer Tools"
    static func categoryName(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "public.app-category.", with: "")
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}
