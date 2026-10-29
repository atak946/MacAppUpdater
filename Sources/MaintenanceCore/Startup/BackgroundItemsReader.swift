import Foundation

/// Reads the legacy `backgrounditems.btm` (macOS 12 and earlier) when it exists and is readable.
///
/// The file is a keyed archive of private classes; instead of decoding them, every bookmark blob in
/// `$objects` is resolved to a path. Newer macOS keeps login items in a root-only database.
public enum BackgroundItemsReader {
    public static func loginItems(at url: URL) -> [BackgroundLoginItem]? {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> [BackgroundLoginItem]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return nil }
        var seen = Set<String>()
        var items: [BackgroundLoginItem] = []
        for case let blob as Data in objects {
            guard let values = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: blob),
                  let path = values.path, seen.insert(path).inserted else { continue }
            let url = URL(fileURLWithPath: path)
            items.append(BackgroundLoginItem(name: url.deletingPathExtension().lastPathComponent, url: url))
        }
        return items
    }
}
