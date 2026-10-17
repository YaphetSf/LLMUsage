import Foundation

/// Reads ZCode's local SQLite store (`~/.zcode/cli/db/db.sqlite`) for per-day token history.
///
/// ZCode keeps a purpose-built `model_usage` row per request — one row per `logical_request_id`,
/// with `attempt_index` distinguishing retries — so unlike the Claude and Codex logs there is
/// nothing to deduplicate and nothing to parse out of a JSON blob.
///
/// It wears the Z.ai mark rather than one of its own: every ZCode request bills to the same Z.ai
/// account the GLM quota card reports, and inventing a separate wordmark for the client would
/// claim a brand that is not published as one.
public struct ZCodeHistoryProvider: UsageHistoryProvider {
    public let id = "zcode"
    public let displayName = "ZCode"
    public var iconName: String { "zai" }

    private let databasePaths: @Sendable () -> [String]

    public init(databasePaths: (@Sendable () -> [String])? = nil) {
        self.databasePaths = databasePaths ?? {
            ZCodePaths.databaseFiles(path: ZCodePaths.databaseFile())
        }
    }

    public func scanHistory(daysBack: Int = 30, now: Date = Date()) async throws -> UsageHistory? {
        let paths = databasePaths()
        guard !paths.isEmpty else { return nil }

        let since = DailyUsageAccumulator.sinceDate(daysBack: daysBack, now: now)
        let cutoffMilliseconds = Int64(since.timeIntervalSince1970 * 1000)

        var accumulator = DailyUsageAccumulator()
        var failures: [String] = []
        var readAny = false

        for path in paths {
            do {
                let database = try SQLiteReadOnlyDatabase(path: path)
                guard try database.hasTable("model_usage") else { continue }
                try database.query(Self.aggregateSQL, parameters: [cutoffMilliseconds]) { row in
                    guard let hour = row.string(0),
                          let day = row.string(1),
                          let provider = row.string(2),
                          let model = row.string(3)
                    else { return }
                    // ZCode's own `computed_total_tokens` is `input_tokens + output_tokens` and
                    // excludes reasoning, so reasoning is carried as detail rather than added to
                    // output — the opposite of OpenCode, which reports it as a sibling bucket.
                    let tokens = TokenBreakdown(
                        input: row.int(4),
                        output: row.int(5),
                        cacheRead: row.int(7),
                        cacheWrite: row.int(8),
                        reasoning: row.int(6)
                    )
                    let requests = row.int(9)
                    accumulator.add(day: day, model: Self.label(provider: provider, model: model),
                                    tokens: tokens, requests: requests)
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

    /// `builtin:zai-coding-plan` and `builtin:zai-start-plan` are separate plans with separate
    /// quota, so the plan stays in the label; only ZCode's internal `builtin:` marker is dropped.
    static func label(provider: String, model: String) -> String {
        let plan = provider.hasPrefix("builtin:") ? String(provider.dropFirst("builtin:".count)) : provider
        return "\(plan)/\(model)"
    }

    /// Aggregated in SQL so a 100k-row table never lands in memory.
    ///
    /// `input_tokens` is inclusive of the cached prefix: every row satisfies
    /// `input_tokens >= cache_read_input_tokens`, and `computed_total_tokens` is exactly
    /// `input_tokens + output_tokens`. Reporting `input` and `cacheRead` straight from those
    /// columns would therefore count the cached prefix twice, because `TokenBreakdown.total`
    /// sums all four buckets. Splitting the cached part out of `input` per row keeps the four
    /// buckets adding back up to ZCode's own total whatever the cache columns mean.
    ///
    /// Only `completed` rows count: `error` and `cancelled` rows carry no tokens and would
    /// inflate the request count, and `running` rows are still in flight.
    ///
    /// `'localtime'` matches `DailyUsageAccumulator.dayKey`, and the hour prefix is in `GROUP BY`
    /// so each row carries one accurate hour rather than an arbitrary member of the group.
    public static let aggregateSQL = """
        SELECT strftime('%Y-%m-%dT%H', started_at / 1000, 'unixepoch', 'localtime') AS hour,
               date(started_at / 1000, 'unixepoch', 'localtime') AS day,
               provider_id AS provider,
               model_id    AS model,
               SUM(MAX(input_tokens - cache_read_input_tokens - cache_creation_input_tokens, 0)),
               SUM(output_tokens),
               SUM(reasoning_tokens),
               SUM(MIN(cache_read_input_tokens, input_tokens)),
               SUM(MIN(cache_creation_input_tokens, MAX(input_tokens - cache_read_input_tokens, 0))),
               COUNT(*)
        FROM model_usage
        WHERE started_at >= ?
          AND status = 'completed'
        GROUP BY hour, day, provider, model;
        """
}
