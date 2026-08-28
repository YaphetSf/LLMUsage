import Foundation

/// Shared plumbing for the providers that read newline-delimited JSON session logs.
///
/// These logs are big — hundreds of megabytes across hundreds of files — so the read path matters:
/// files are memory-mapped, scanned for newlines as raw bytes, and a candidate line is only handed
/// to `JSONSerialization` when it contains a cheap marker substring. Parsing every line as JSON
/// would spend most of its time on lines that carry no usage at all.
enum JSONLScanning {
    /// Roots from a comma-separated environment override, falling back to `defaults`. Blank entries
    /// are dropped so a stray comma cannot turn into a scan of `/`.
    static func roots(
        environmentValue: String?,
        defaults: @autoclosure () -> [String]
    ) -> [String] {
        guard let environmentValue else { return defaults() }
        let entries = environmentValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return entries.isEmpty ? defaults() : entries
    }

    /// Every `.jsonl` under `directory`, recursively.
    ///
    /// Files last written before `since` are skipped: a session file's mtime is when it was last
    /// appended to, so one untouched since before the window cannot hold an event inside it. On
    /// these log sizes that skip is most of the speedup for a short window.
    static func logFiles(in directory: String, modifiedSince since: Date) -> [URL] {
        let root = URL(fileURLWithPath: directory)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if let modified = values?.contentModificationDate, modified < since { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Calls `body` for each line of `url` that contains `marker`.
    ///
    /// The line is passed as a `Data` slice of the mapped file, so no per-line copy happens until
    /// `JSONSerialization` actually needs one.
    static func forEachLine(
        in url: URL,
        containing marker: [UInt8],
        _ body: (Data) -> Void
    ) throws {
        _ = try forEachLine(in: url, fromOffset: 0, containing: marker, body)
    }

    /// Scans only bytes appended after `offset` and returns the new end offset. JSONL files used
    /// by the supported CLIs are append-only; retaining the parser state at this cursor turns a
    /// changed multi-hundred-megabyte session into a scan of its newest lines.
    static func forEachLine(
        in url: URL,
        fromOffset offset: Int64,
        containing marker: [UInt8],
        _ body: (Data) -> Void
    ) throws -> Int64 {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let newline = UInt8(ascii: "\n")
        let clampedOffset = min(max(Int(offset), 0), data.count)
        var lineStart = data.index(data.startIndex, offsetBy: clampedOffset)
        while lineStart < data.endIndex {
            guard let lineEnd = data[lineStart...].firstIndex(of: newline) else { break }
            if lineEnd > lineStart {
                let line = data[lineStart..<lineEnd]
                if contains(line, marker) { body(line) }
            }
            lineStart = data.index(after: lineEnd)
        }
        return Int64(data.distance(from: data.startIndex, to: lineStart))
    }

    /// Naive substring search over the line's bytes. The markers are short and distinctive, so this
    /// beats building a `String` per line just to call `contains`.
    private static func contains(_ haystack: Data, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let first = needle[0]
        var index = haystack.startIndex
        let last = haystack.index(haystack.endIndex, offsetBy: -needle.count)
        while index <= last {
            guard let candidate = haystack[index...last].firstIndex(of: first) else { return false }
            var matched = true
            for offset in 1..<needle.count where haystack[haystack.index(candidate, offsetBy: offset)] != needle[offset] {
                matched = false
                break
            }
            if matched { return true }
            index = haystack.index(after: candidate)
        }
        return false
    }

    /// Parses the ISO-8601 timestamps these logs use (`2026-08-27T17:36:27.175Z`).
    ///
    /// Hand-rolled rather than `ISO8601DateFormatter`: the format is fixed and there are tens of
    /// thousands of them per scan, where the formatter's parse cost is the dominant term.
    static func timestamp(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count >= 19 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var result = 0
            for index in range {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                result = result * 10 + digit
            }
            return result
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19)
        else { return nil }

        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar.gregorianUTC.date(from: components)
    }
}

extension Calendar {
    /// A fixed UTC calendar for turning log timestamps into `Date`s. The *bucketing* calendar stays
    /// the user's local one — only this parse step is UTC, because that is what the logs record.
    static let gregorianUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

struct JSONLParseBatch<Entry: Sendable, State: Sendable>: Sendable {
    var entries: [Entry]
    var state: State
    /// Byte offset immediately after the last complete newline. `nil` is useful for simple test
    /// parsers that consume the complete file; production JSONL parsers always provide it.
    var nextOffset: Int64?
    var succeeded: Bool

    init(
        entries: [Entry],
        state: State,
        nextOffset: Int64? = nil,
        succeeded: Bool = true
    ) {
        self.entries = entries
        self.state = state
        self.nextOffset = nextOffset
        self.succeeded = succeeded
    }
}

/// Caches parsed entries and parser state per file, keyed by file identity, size and mtime.
///
/// Session logs are append-only and the newest file is usually the only one that changed between
/// two scans. Entries are persisted in the app-owned SQLite cache, and a growing file resumes at
/// its previous byte cursor. A cold app launch therefore pays only for file metadata and decoding
/// the compact parsed entries, not for parsing the original JSONL again.
actor JSONLParseCache<Entry: Codable & Sendable, State: Codable & Sendable> {
    private struct Record: Codable {
        var resourceID: String
        var size: Int64
        var modifiedMilliseconds: Int64
        var cursor: Int64
        var entries: [Entry]
        var state: State
    }

    private var records: [String: Record] = [:]
    private let namespace: String
    private let database: UsageHistoryCacheDatabase?

    init(namespace: String, databaseURL: URL? = nil) {
        self.namespace = namespace
        let resolvedURL = databaseURL ?? (try? UsageHistoryCacheLocation.defaultDatabaseURL())
        database = resolvedURL.flatMap { try? UsageHistoryCacheDatabase(url: $0) }
    }

    func entries(
        for files: [URL],
        initialState: State,
        parse: @Sendable (URL, Int64, State) -> JSONLParseBatch<Entry, State>
    ) -> [Entry] {
        var result: [Entry] = []
        for url in files {
            let path = url.path
            let metadata = Self.metadata(for: url)
            var record = records[path] ?? persistedRecord(for: path)

            if let existing = record,
               existing.resourceID == metadata.resourceID,
               existing.size == metadata.size,
               existing.modifiedMilliseconds == metadata.modifiedMilliseconds {
                records[path] = existing
                try? database?.touchParsedFile(namespace: namespace, path: path)
                result.append(contentsOf: existing.entries)
                continue
            }

            if let existing = record,
               existing.resourceID == metadata.resourceID,
               metadata.size > existing.size {
                let appended = parse(url, existing.cursor, existing.state)
                guard appended.succeeded else {
                    records[path] = existing
                    result.append(contentsOf: existing.entries)
                    continue
                }
                record = Record(
                    resourceID: metadata.resourceID,
                    size: metadata.size,
                    modifiedMilliseconds: metadata.modifiedMilliseconds,
                    cursor: appended.nextOffset ?? metadata.size,
                    entries: existing.entries + appended.entries,
                    state: appended.state
                )
            } else {
                let parsed = parse(url, 0, initialState)
                guard parsed.succeeded else {
                    if let existing = record {
                        records[path] = existing
                        result.append(contentsOf: existing.entries)
                    }
                    continue
                }
                record = Record(
                    resourceID: metadata.resourceID,
                    size: metadata.size,
                    modifiedMilliseconds: metadata.modifiedMilliseconds,
                    cursor: parsed.nextOffset ?? metadata.size,
                    entries: parsed.entries,
                    state: parsed.state
                )
            }

            guard let record else { continue }
            records[path] = record
            persist(record, for: path)
            result.append(contentsOf: record.entries)
        }

        if let cutoff = Calendar.current.date(byAdding: .day, value: -180, to: Date()) {
            try? database?.pruneParsedFiles(namespace: namespace, unusedSince: cutoff)
        }
        return result
    }

    private func persistedRecord(for path: String) -> Record? {
        guard let database,
              let cached = try? database.parsedFile(namespace: namespace, path: path),
              let payload = try? JSONDecoder().decode(Payload.self, from: cached.payload)
        else { return nil }
        return Record(
            resourceID: cached.resourceID,
            size: cached.size,
            modifiedMilliseconds: cached.modifiedMilliseconds,
            cursor: payload.cursor,
            entries: payload.entries,
            state: payload.state
        )
    }

    private func persist(_ record: Record, for path: String) {
        let payload = Payload(cursor: record.cursor, entries: record.entries, state: record.state)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? database?.storeParsedFile(
            namespace: namespace,
            path: path,
            resourceID: record.resourceID,
            size: record.size,
            modifiedMilliseconds: record.modifiedMilliseconds,
            payload: data
        )
    }

    private struct Payload: Codable {
        var cursor: Int64
        var entries: [Entry]
        var state: State
    }

    private static func metadata(for url: URL) -> (
        resourceID: String, size: Int64, modifiedMilliseconds: Int64
    ) {
        // `URLResourceValues` may retain a recently-read size on the same URL value. FileManager
        // attributes are fetched afresh, which matters when a live session was appended moments
        // before this refresh.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let volume = (attributes?[.systemNumber] as? NSNumber)?.int64Value ?? -1
        let inode = (attributes?[.systemFileNumber] as? NSNumber)?.int64Value ?? -1
        let resourceID = volume >= 0 && inode >= 0 ? "\(volume):\(inode)" : url.path
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
        let modifiedMilliseconds = Int64((modified.timeIntervalSince1970 * 1_000).rounded())
        return (resourceID, size, modifiedMilliseconds)
    }
}
