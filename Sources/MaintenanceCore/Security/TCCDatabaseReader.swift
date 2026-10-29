import Foundation
import SQLite3
import os

/// One row of a TCC `access` table.
public struct TCCRecord: Sendable, Hashable {
    public let service: String
    public let client: String
    /// 0 = bundle identifier, 1 = absolute path.
    public let clientType: Int
    public let isAllowed: Bool
    public let lastModified: Date?

    public init(service: String, client: String, clientType: Int, isAllowed: Bool, lastModified: Date?) {
        self.service = service
        self.client = client
        self.clientType = clientType
        self.isAllowed = isAllowed
        self.lastModified = lastModified
    }
}

/// Read-only access to a TCC database with the SQLite C API. Blocking: call off the main actor.
public enum TCCDatabaseReader {
    public enum ReadError: Error, Equatable {
        /// Missing or not readable (no Full Disk Access).
        case unreadable
        case unexpectedSchema
    }

    private static let logger = Logger(subsystem: "com.macappupdater", category: "TCCDatabase")

    public static func read(_ url: URL) throws(ReadError) -> [TCCRecord] {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw .unreadable }
        guard let db = open(url) else { throw .unreadable }
        defer { sqlite3_close(db) }

        let columns = columnNames(db)
        guard columns.isSuperset(of: ["service", "client", "client_type"]) else { throw .unexpectedSchema }
        // macOS 11+ stores `auth_value` (0 denied, 2 allowed, 3 limited); older versions `allowed`.
        let allowedExpression: String
        if columns.contains("auth_value") {
            allowedExpression = "auth_value IN (2, 3)"
        } else if columns.contains("allowed") {
            allowedExpression = "allowed = 1"
        } else {
            throw .unexpectedSchema
        }
        let modified = columns.contains("last_modified") ? "last_modified" : "NULL"
        let sql = "SELECT service, client, client_type, \(allowedExpression), \(modified) FROM access"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            logger.error("Preparing TCC query failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            throw .unexpectedSchema
        }
        defer { sqlite3_finalize(statement) }

        var records: [TCCRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let service = text(statement, 0), let client = text(statement, 1) else { continue }
            let date = sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4)))
            records.append(TCCRecord(
                service: service,
                client: client,
                clientType: Int(sqlite3_column_int(statement, 2)),
                isAllowed: sqlite3_column_int(statement, 3) != 0,
                lastModified: date
            ))
        }
        return records
    }

    // MARK: SQLite helpers

    /// Read-only first; `immutable=1` as a fallback when the WAL index can't be opened.
    private static func open(_ url: URL) -> OpaquePointer? {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        for query in ["mode=ro", "immutable=1"] {
            var db: OpaquePointer?
            let uri = "file:\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)?\(query)"
            if sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db, !columnNames(db).isEmpty {
                return db
            }
            sqlite3_close(db)
        }
        logger.notice("TCC database at \(url.path, privacy: .public) could not be opened")
        return nil
    }

    private static func columnNames(_ db: OpaquePointer) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(access)", -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 1) { names.insert(name) }
        }
        return names
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
