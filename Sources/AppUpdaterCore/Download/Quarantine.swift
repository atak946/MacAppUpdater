import Darwin
import Foundation

/// `com.apple.quarantine` handling for downloaded and staged content (M-4).
///
/// URLSession does not quarantine downloads. Without the attribute, Gatekeeper's first-launch
/// assessment and XProtect's quarantine-triggered scan never run. The attribute is written
/// directly (instead of `URLResourceValues.quarantineProperties`) so the agent name is always
/// "MacAppUpdater" and the value is deterministic.
enum Quarantine {
    static let attributeName = "com.apple.quarantine"
    static let agentName = "MacAppUpdater"
    /// 0x0001 = downloaded, 0x0080 = created by a non-sandboxed app. 0x0040 (user approved)
    /// is never set, so Gatekeeper still assesses the item on first open.
    static let flags = "0081"

    static func value(date: Date = Date()) -> String {
        let seconds = UInt32(clamping: max(0, Int(date.timeIntervalSince1970)))
        return "\(flags);\(String(seconds, radix: 16));\(agentName);"
    }

    /// Writes the attribute on `url` itself (symlinks are not followed).
    static func apply(to url: URL, date: Date = Date()) throws {
        let data = Array(value(date: date).utf8)
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return setxattr(path, attributeName, data, data.count, 0, XATTR_NOFOLLOW)
        }
        guard status == 0 else {
            throw UpdaterError.installFailed(
                "Cannot quarantine \(url.lastPathComponent): \(String(cString: strerror(errno)))"
            )
        }
    }

    static func isQuarantined(_ url: URL) -> Bool {
        attribute(of: url) != nil
    }

    static func attribute(of url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let read = getxattr(path, attributeName, &buffer, size, 0, XATTR_NOFOLLOW)
            guard read > 0 else { return nil }
            return String(decoding: buffer.prefix(read), as: UTF8.self)
        }
    }

    /// Removes the attribute from `url` and everything below it. Missing attributes are fine.
    static func removeRecursively(from url: URL, fileManager: FileManager = .default) {
        remove(from: url)
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in enumerator {
            remove(from: item)
        }
    }

    private static func remove(from url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return removexattr(path, attributeName, XATTR_NOFOLLOW)
        }
    }
}
