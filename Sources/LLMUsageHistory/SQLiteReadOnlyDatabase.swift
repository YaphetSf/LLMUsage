import Foundation
import SQLite3

/// A minimal read-only SQLite handle, used to read other tools' live databases.
///
/// Opened `SQLITE_OPEN_READONLY` so a bug here can never damage a user's OpenCode database — the
/// connection is physically incapable of writing. Journal mode is left alone for the same reason
/// (switching a WAL database's mode is a write). A `busy_timeout` covers the common case of the
/// tool holding a write lock while we read.
///
/// A tool that deletes its WAL sidecars on exit (ZCode) leaves a database a plain read-only
/// connection cannot open, because it tries to recreate them. When no `-wal` file exists the
/// handle is reopened with `immutable=1`, which promises the file will not change and needs no
/// sidecars; a live database with a `-wal` keeps the normal connection.
///
/// Not `Sendable`: it wraps a C pointer and must not cross isolation domains. Callers open it,
/// query, and drop it inside one function body.
final class SQLiteReadOnlyDatabase {
    private let handle: OpaquePointer

    init(path: String) throws {
        let primary = try Self.open(path: path, uri: false)
        if let failure = Self.probeFailure(primary) {
            sqlite3_close_v2(primary)
            guard !FileManager.default.fileExists(atPath: path + "-wal") else {
                throw UsageHistoryError.logsUnreadable(failure)
            }
            let immutable = try Self.open(path: Self.immutableURI(for: path), uri: true)
            if let retry = Self.probeFailure(immutable) {
                sqlite3_close_v2(immutable)
                throw UsageHistoryError.logsUnreadable(retry)
            }
            handle = immutable
        } else {
            handle = primary
        }
    }

    deinit { sqlite3_close_v2(handle) }

    /// Runs `sql`, binding `parameters` positionally, and hands each row to `consume`.
    ///
    /// `Row` borrows the statement and is only valid inside the closure, so it must not escape.
    func query(
        _ sql: String,
        parameters: [Int64] = [],
        consume: (Row) -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(statement)
            throw UsageHistoryError.logsUnreadable(message)
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in parameters.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), value)
        }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                consume(Row(statement: statement))
            case SQLITE_DONE:
                return
            default:
                throw UsageHistoryError.logsUnreadable(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    struct Row {
        let statement: OpaquePointer

        func string(_ column: Int32) -> String? {
            guard let text = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: text)
        }

        func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }

        func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    }

    /// Whether a table exists, so a schema change in the other tool surfaces as "no data" rather
    /// than an unreadable-logs error.
    func hasTable(_ name: String) throws -> Bool {
        var names: Set<String> = []
        try query("SELECT name FROM sqlite_master WHERE type='table';") { row in
            if let value = row.string(0) { names.insert(value) }
        }
        return names.contains(name)
    }

    private static func open(path: String, uri: Bool) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = uri ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        let status = sqlite3_open_v2(path, &db, flags, nil)
        guard status == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed (\(status))"
            if let db { sqlite3_close_v2(db) }
            throw UsageHistoryError.logsUnreadable(message)
        }
        sqlite3_busy_timeout(db, 3_000)
        return db
    }

    /// The error message of running `SELECT 1 FROM sqlite_master LIMIT 1`, or `nil` when the
    /// connection can actually read the database — a sidecar-less WAL database fails only here.
    private static func probeFailure(_ db: OpaquePointer) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(statement)
            return message
        }
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        return status == SQLITE_ROW || status == SQLITE_DONE
            ? nil
            : String(cString: sqlite3_errmsg(db))
    }

    /// SQLite URI filenames percent-decode the path, so the characters that carry URI structure
    /// must be escaped.
    private static func immutableURI(for path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%?#")
        return "file:\(path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)?immutable=1"
    }
}
