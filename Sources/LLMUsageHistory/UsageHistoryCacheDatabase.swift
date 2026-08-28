import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct CachedParsedFile {
    var resourceID: String
    var size: Int64
    var modifiedMilliseconds: Int64
    var payload: Data
}

enum UsageHistoryCacheLocation {
    static func defaultDatabaseURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("LLMUsage", isDirectory: true)
            .appendingPathComponent("usage-history-cache.sqlite3")
    }
}

/// The writable cache owned by LLMUsage itself. This is deliberately separate from
/// `SQLiteReadOnlyDatabase`, whose read-only connection is the safety seam around OpenCode's
/// database. Mixing the two would make it possible for cache code to write to a tool-owned file.
final class UsageHistoryCacheDatabase {
    private let handle: OpaquePointer

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var database: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "open failed (\(status))"
            if let database { sqlite3_close_v2(database) }
            throw CacheError.sqlite(message)
        }
        handle = database
        sqlite3_busy_timeout(database, 3_000)

        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("""
            CREATE TABLE IF NOT EXISTS parsed_files (
                namespace TEXT NOT NULL,
                path TEXT NOT NULL,
                resource_id TEXT NOT NULL,
                size INTEGER NOT NULL,
                modified_ms INTEGER NOT NULL,
                payload BLOB NOT NULL,
                last_seen_ms INTEGER NOT NULL,
                PRIMARY KEY (namespace, path)
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS snapshots (
                snapshot_key TEXT PRIMARY KEY,
                payload BLOB NOT NULL
            );
            """)
    }

    deinit { sqlite3_close_v2(handle) }

    func parsedFile(namespace: String, path: String) throws -> CachedParsedFile? {
        let statement = try prepare("""
            SELECT resource_id, size, modified_ms, payload
            FROM parsed_files
            WHERE namespace = ? AND path = ?;
            """)
        defer { sqlite3_finalize(statement) }
        bind(namespace, to: 1, in: statement)
        bind(path, to: 2, in: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let resourceID = string(at: 0, in: statement),
                  let payload = data(at: 3, in: statement)
            else { return nil }
            return CachedParsedFile(
                resourceID: resourceID,
                size: sqlite3_column_int64(statement, 1),
                modifiedMilliseconds: sqlite3_column_int64(statement, 2),
                payload: payload
            )
        case SQLITE_DONE:
            return nil
        default:
            throw CacheError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func storeParsedFile(
        namespace: String,
        path: String,
        resourceID: String,
        size: Int64,
        modifiedMilliseconds: Int64,
        payload: Data,
        now: Date = Date()
    ) throws {
        let statement = try prepare("""
            INSERT INTO parsed_files
                (namespace, path, resource_id, size, modified_ms, payload, last_seen_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(namespace, path) DO UPDATE SET
                resource_id = excluded.resource_id,
                size = excluded.size,
                modified_ms = excluded.modified_ms,
                payload = excluded.payload,
                last_seen_ms = excluded.last_seen_ms;
            """)
        defer { sqlite3_finalize(statement) }
        bind(namespace, to: 1, in: statement)
        bind(path, to: 2, in: statement)
        bind(resourceID, to: 3, in: statement)
        sqlite3_bind_int64(statement, 4, size)
        sqlite3_bind_int64(statement, 5, modifiedMilliseconds)
        bind(payload, to: 6, in: statement)
        sqlite3_bind_int64(statement, 7, Self.milliseconds(now))
        try stepToCompletion(statement)
    }

    func touchParsedFile(namespace: String, path: String, now: Date = Date()) throws {
        let statement = try prepare("""
            UPDATE parsed_files SET last_seen_ms = ? WHERE namespace = ? AND path = ?;
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Self.milliseconds(now))
        bind(namespace, to: 2, in: statement)
        bind(path, to: 3, in: statement)
        try stepToCompletion(statement)
    }

    func pruneParsedFiles(namespace: String, unusedSince cutoff: Date) throws {
        let statement = try prepare("""
            DELETE FROM parsed_files WHERE namespace = ? AND last_seen_ms < ?;
            """)
        defer { sqlite3_finalize(statement) }
        bind(namespace, to: 1, in: statement)
        sqlite3_bind_int64(statement, 2, Self.milliseconds(cutoff))
        try stepToCompletion(statement)
    }

    func snapshotData(for key: String) throws -> Data? {
        let statement = try prepare(
            "SELECT payload FROM snapshots WHERE snapshot_key = ?;"
        )
        defer { sqlite3_finalize(statement) }
        bind(key, to: 1, in: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return data(at: 0, in: statement)
        case SQLITE_DONE:
            return nil
        default:
            throw CacheError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func storeSnapshot(_ payload: Data, for key: String) throws {
        let statement = try prepare("""
            INSERT INTO snapshots (snapshot_key, payload) VALUES (?, ?)
            ON CONFLICT(snapshot_key) DO UPDATE SET payload = excluded.payload;
            """)
        defer { sqlite3_finalize(statement) }
        bind(key, to: 1, in: statement)
        bind(payload, to: 2, in: statement)
        try stepToCompletion(statement)
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(error)
            throw CacheError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            sqlite3_finalize(statement)
            throw CacheError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        return statement
    }

    private func stepToCompletion(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CacheError.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bind(_ value: Data, to index: Int32, in statement: OpaquePointer) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
    }

    private func string(at column: Int32, in statement: OpaquePointer) -> String? {
        guard let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }

    private func data(at column: Int32, in statement: OpaquePointer) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private enum CacheError: Error {
        case sqlite(String)
    }
}
