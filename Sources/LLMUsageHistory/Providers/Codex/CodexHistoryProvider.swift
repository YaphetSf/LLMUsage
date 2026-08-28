import Foundation

/// Reads the Codex CLI's session rollouts (`$CODEX_HOME/sessions/**/*.jsonl` and
/// `archived_sessions/`) for per-day token history.
///
/// The format's two traps, both verified against a real 303-file log:
///
/// **`input_tokens` already contains `cached_input_tokens`** (cached never exceeds input on any
/// event, and `total_tokens == input + output` holds). So the uncached portion is the difference —
/// treating `input_tokens` as fresh input would count the cached bulk twice, and on this data the
/// cache is 95% of all input.
///
/// **Forked sessions replay their parent's turns with rewritten timestamps.** A child session's
/// replayed events all carry the fork instant as their timestamp, so nothing keyed on time can tell
/// them from real turns — deduplicating by timestamp catches zero of them. They are identical in
/// *value* though, so events are collapsed on their token counts plus the session-cumulative total
/// they were emitted at. That same key also absorbs the stale snapshots Codex re-emits when a turn
/// ends without new usage: an unchanged cumulative total means no new tokens by definition.
public struct CodexHistoryProvider: UsageHistoryProvider {
    public let id = "codex"
    public let displayName = "Codex"
    public let iconName = "openai"

    private let environment: [String: String]
    private let homeDirectory: URL
    private static let cache = JSONLParseCache<Entry, ParserState>(namespace: "codex-v1")

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    struct Entry: Codable, Sendable {
        var timestamp: Date
        var model: String
        var tokens: TokenBreakdown
        /// The session-cumulative `total_token_usage` this turn was reported at. Part of the
        /// identity that survives a fork's timestamp rewrite.
        var cumulativeTotal: Int
    }

    private struct ParserState: Codable, Sendable {
        var model: String
    }

    public func scanHistory(daysBack: Int = 30, now: Date = Date()) async throws -> UsageHistory? {
        let sessionDirectories = self.sessionDirectories()
        guard !sessionDirectories.isEmpty else { return nil }

        let since = DailyUsageAccumulator.sinceDate(daysBack: daysBack, now: now)
        let files = sessionDirectories.flatMap { JSONLScanning.logFiles(in: $0, modifiedSince: since) }
        let entries = await Self.cache.entries(
            for: files,
            initialState: ParserState(model: Self.fallbackModel),
            parse: Self.parse(file:fromOffset:state:)
        )

        var seen: Set<Fingerprint> = []
        var accumulator = DailyUsageAccumulator()
        for entry in entries where entry.timestamp >= since {
            let fingerprint = Fingerprint(tokens: entry.tokens, cumulativeTotal: entry.cumulativeTotal)
            guard seen.insert(fingerprint).inserted else { continue }
            accumulator.add(
                day: DailyUsageAccumulator.dayKey(from: entry.timestamp),
                model: entry.model,
                tokens: entry.tokens
            )
            accumulator.addHour(
                hour: DailyUsageAccumulator.hourKey(from: entry.timestamp),
                tokens: entry.tokens
            )
        }
        return accumulator.build(providerID: id)
    }

    private struct Fingerprint: Hashable {
        var tokens: TokenBreakdown
        var cumulativeTotal: Int
    }

    // MARK: - Roots

    /// `CODEX_HOME` (comma-separated) wins, else `~/.codex`. Each home contributes both its live
    /// `sessions/` directory and `archived_sessions/`.
    func sessionDirectories() -> [String] {
        let homes = JSONLScanning.roots(
            environmentValue: environment["CODEX_HOME"],
            defaults: [homeDirectory.appendingPathComponent(".codex").path]
        )
        var directories: [String] = []
        for home in homes {
            for name in ["sessions", "archived_sessions"] {
                let candidate = home + "/" + name
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    directories.append(candidate)
                }
            }
        }
        return directories
    }

    // MARK: - Parsing

    /// Matches both record kinds this parse needs: the `token_count` events and the `turn_context`
    /// records that name the model they ran under.
    private static let marker = Array(#""t"#.utf8)
    private static let fallbackModel = "unknown"

    static func parse(file url: URL) -> [Entry] {
        parse(
            file: url,
            fromOffset: 0,
            state: ParserState(model: fallbackModel)
        ).entries
    }

    private static func parse(
        file url: URL,
        fromOffset offset: Int64,
        state: ParserState
    ) -> JSONLParseBatch<Entry, ParserState> {
        var entries: [Entry] = []
        var model = state.model

        do {
            let nextOffset = try JSONLScanning.forEachLine(
                in: url,
                fromOffset: offset,
                containing: marker
            ) { line in
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = object["payload"] as? [String: Any]
                else { return }

                // `turn_context` is a top-level record type, not a payload type. It carries the model
                // every following turn ran under until the next one appears.
                if object["type"] as? String == "turn_context" {
                    if let named = payload["model"] as? String, !named.isEmpty { model = named }
                    return
                }

                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any],
                      let timestampText = object["timestamp"] as? String,
                      let timestamp = JSONLScanning.timestamp(timestampText)
                else { return }

                func count(_ source: [String: Any], _ key: String) -> Int {
                    (source[key] as? NSNumber)?.intValue ?? 0
                }
                let cached = count(last, "cached_input_tokens")
                let cumulative = (info["total_token_usage"] as? [String: Any])
                    .map { count($0, "total_tokens") } ?? 0

                entries.append(
                    Entry(
                        timestamp: timestamp,
                        model: model,
                        tokens: TokenBreakdown(
                            // Cached input is reported inside `input_tokens`, so the fresh portion is
                            // the difference. Clamped: a malformed line must not produce negative input.
                            input: max(0, count(last, "input_tokens") - cached),
                            output: count(last, "output_tokens"),
                            cacheRead: cached,
                            cacheWrite: count(last, "cache_write_input_tokens"),
                            reasoning: count(last, "reasoning_output_tokens")
                        ),
                        cumulativeTotal: cumulative
                    )
                )
            }
            return JSONLParseBatch(
                entries: entries,
                state: ParserState(model: model),
                nextOffset: nextOffset
            )
        } catch {
            return JSONLParseBatch(
                entries: [], state: state, nextOffset: offset, succeeded: false
            )
        }
    }
}
