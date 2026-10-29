import Foundation
import os

/// Persists usage minutes as compact JSON: app ids and names are stored once in a table and each
/// minute is `[epochSeconds, seconds, [[appIndex, cpuTenths, memoryKiB], …]]`. 24 hours of top-10
/// minutes come to roughly 200 KB.
///
/// Writes are atomic (temp file + rename). A corrupt file is moved aside to `<name>.corrupt`.
public struct UsageHistoryStore: Sendable {
    private static let logger = Logger(subsystem: "com.macappupdater", category: "UsageHistory")
    static let formatVersion = 1

    public let fileURL: URL

    /// `~/Library/Application Support/MacAppUpdater/UsageHistory.json`
    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("MacAppUpdater", isDirectory: true)
            .appendingPathComponent("UsageHistory.json")
    }

    public init(fileURL: URL = UsageHistoryStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// Stored minutes, oldest first; empty when the file is missing or unreadable.
    public func load() -> [UsageMinute] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try Self.decode(data)
        } catch {
            Self.logger.error("Usage history is corrupt, moving aside: \(error.localizedDescription, privacy: .public)")
            let aside = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return []
        }
    }

    public func save(_ minutes: [UsageMinute]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encode(minutes).write(to: fileURL, options: .atomic)
    }

    // MARK: - Format

    static func encode(_ minutes: [UsageMinute]) throws -> Data {
        var indexByID: [String: Int] = [:]
        var apps: [StoredApp] = []
        let stored = minutes.map { minute in
            StoredMinute(
                timestamp: Int64(minute.timestamp.timeIntervalSince1970.rounded()),
                seconds: Int64(minute.seconds.rounded()),
                apps: minute.apps.map { app in
                    let index = indexByID[app.id] ?? {
                        apps.append(StoredApp(id: app.id, name: app.name, bundlePath: app.bundlePath))
                        indexByID[app.id] = apps.count - 1
                        return apps.count - 1
                    }()
                    return [Int64(index), Int64((app.cpuPercent * 10).rounded()), Int64(app.memoryBytes / 1024)]
                }
            )
        }
        return try JSONEncoder().encode(StoredHistory(version: formatVersion, apps: apps, minutes: stored))
    }

    static func decode(_ data: Data) throws -> [UsageMinute] {
        let history = try JSONDecoder().decode(StoredHistory.self, from: data)
        guard history.version == formatVersion else { return [] }
        return history.minutes.map { minute in
            UsageMinute(
                timestamp: Date(timeIntervalSince1970: TimeInterval(minute.timestamp)),
                seconds: TimeInterval(minute.seconds),
                apps: minute.apps.compactMap { values in
                    guard values.count == 3, history.apps.indices.contains(Int(values[0])) else { return nil }
                    let app = history.apps[Int(values[0])]
                    return AppUsageSample(id: app.id, name: app.name, bundlePath: app.bundlePath,
                                          cpuPercent: Double(values[1]) / 10, memoryBytes: UInt64(max(0, values[2])) * 1024)
                }
            )
        }
    }

    private struct StoredHistory: Codable {
        let version: Int
        let apps: [StoredApp]
        let minutes: [StoredMinute]

        enum CodingKeys: String, CodingKey {
            case version = "v", apps, minutes = "m"
        }
    }

    /// `[id, name, bundlePath?]`
    private struct StoredApp: Codable {
        let id: String
        let name: String
        let bundlePath: String?

        init(id: String, name: String, bundlePath: String?) {
            self.id = id
            self.name = name
            self.bundlePath = bundlePath
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            id = try container.decode(String.self)
            name = try container.decode(String.self)
            bundlePath = try container.decodeIfPresent(String.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(id)
            try container.encode(name)
            if let bundlePath { try container.encode(bundlePath) }
        }
    }

    /// `[timestamp, seconds, [[appIndex, cpuTenths, memoryKiB], …]]`
    private struct StoredMinute: Codable {
        let timestamp: Int64
        let seconds: Int64
        let apps: [[Int64]]

        init(timestamp: Int64, seconds: Int64, apps: [[Int64]]) {
            self.timestamp = timestamp
            self.seconds = seconds
            self.apps = apps
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            timestamp = try container.decode(Int64.self)
            seconds = try container.decode(Int64.self)
            apps = try container.decode([[Int64]].self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(timestamp)
            try container.encode(seconds)
            try container.encode(apps)
        }
    }
}
