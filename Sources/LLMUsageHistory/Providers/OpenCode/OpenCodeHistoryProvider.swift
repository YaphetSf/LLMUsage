import Foundation

/// Reads OpenCode's local SQLite log (`<data dir>/opencode*.db`) for per-day token history.
///
/// Every `providerID` is counted, not just OpenCode's own hosted gateways. OpenCode is overwhelmingly
/// used with the user's own keys, and a scanner that filters to its hosted gateways reports nothing
/// at all for a BYO-key user while their tokens sit right there in the same table.
///
/// Unlike the Claude and Codex logs there is no dedup problem here: OpenCode assigns each assistant
/// message one row with a stable id, and does not replay parent history into child sessions.
public struct OpenCodeHistoryProvider: UsageHistoryProvider {
    public let id = "opencode"
    public let displayName = "OpenCode"

    private let databasePaths: @Sendable () throws -> [String]

    public init(databasePaths: (@Sendable () throws -> [String])? = nil) {
        self.databasePaths = databasePaths ?? {
            try OpenCodePaths.databaseFiles(in: OpenCodePaths.dataDirectory())
        }
    }

    public func scanHistory(daysBack: Int = 30, now: Date = Date()) async throws -> UsageHistory? {
        let paths = try databasePaths()
        guard !paths.isEmpty else { return nil }

        let since = DailyUsageAccumulator.sinceDate(daysBack: daysBack, now: now)
        let cutoffMilliseconds = Int64(since.timeIntervalSince1970 * 1000)

        var accumulator = DailyUsageAccumulator()
        var failures: [String] = []
        var readAny = false

        for path in paths {
            do {
                let database = try SQLiteReadOnlyDatabase(path: path)
                guard database.hasTable("message") else { continue }
                try database.query(Self.aggregateSQL, parameters: [cutoffMilliseconds]) { row in
                    guard let hour = row.string(0),
                          let day = row.string(1),
                          let provider = row.string(2),
                          let model = row.string(3)
                    else { return }
                    // OpenCode writes reasoning as a bucket *beside* output, not inside it — its
                    // own `tokens.total` only reconciles when reasoning is added on top. Folding it
                    // into `output` here is what puts this provider on `TokenBreakdown`'s invariant;
                    // without it every reasoning model silently undercounts.
                    let reasoning = row.int(6)
                    let tokens = TokenBreakdown(
                        input: row.int(4),
                        output: row.int(5) + reasoning,
                        cacheRead: row.int(7),
                        cacheWrite: row.int(8),
                        reasoning: reasoning
                    )
                    let requests = row.int(9)
                    accumulator.add(
                        day: day,
                        model: "\(provider)/\(model)",
                        tokens: tokens,
                        requests: requests
                    )
                    accumulator.addHour(hour: hour, tokens: tokens, requests: requests)
                }
                readAny = true
            } catch {
                failures.append("\(path): \(error.localizedDescription)")
            }
        }

        guard readAny else {
            throw UsageHistoryError.logsUnreadable(failures.joined(separator: "; "))
        }
        return accumulator.build(providerID: id)
    }

    /// Aggregated in SQL rather than by pulling every row: the day bucket and the token sums are
    /// both things SQLite does without materialising 100k JSON blobs in memory.
    ///
    /// `'localtime'` matches `DailyUsageAccumulator.dayKey`, so a request at 23:30 lands on the day
    /// the user actually made it. The hour prefix is included in `GROUP BY` so each output row
    /// carries a single, accurate hour — leaving it out would let SQLite pick an arbitrary row's
    /// hour from each (day, provider, model) group.
    public static let aggregateSQL = """
        SELECT strftime('%Y-%m-%dT%H', time_created / 1000, 'unixepoch', 'localtime') AS hour,
               date(time_created / 1000, 'unixepoch', 'localtime') AS day,
               json_extract(data, '$.providerID') AS provider,
               json_extract(data, '$.modelID')    AS model,
               SUM(COALESCE(json_extract(data, '$.tokens.input'), 0)),
               SUM(COALESCE(json_extract(data, '$.tokens.output'), 0)),
               SUM(COALESCE(json_extract(data, '$.tokens.reasoning'), 0)),
               SUM(COALESCE(json_extract(data, '$.tokens.cache.read'), 0)),
               SUM(COALESCE(json_extract(data, '$.tokens.cache.write'), 0)),
               COUNT(*)
        FROM message
        WHERE time_created >= ?
          AND json_valid(data)
          AND json_extract(data, '$.role') = 'assistant'
          AND provider IS NOT NULL
          AND model IS NOT NULL
        GROUP BY hour, day, provider, model;
        """
}
