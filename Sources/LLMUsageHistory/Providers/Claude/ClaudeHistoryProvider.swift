import Foundation

/// Reads Claude Code's session logs (`<config dir>/projects/**/*.jsonl`) for per-day token history.
///
/// Two things about this format decide whether the numbers are right, and both were verified
/// against a real 72-file log rather than assumed:
///
/// **Deduplication is not optional.** 48% of the usage lines on the machine this was written
/// against are repeats of a line already present — Claude Code rewrites a message's record as the
/// turn progresses. Summing the file as-is inflates the total by **1.84x**. Lines are therefore
/// collapsed on `(message.id, requestId)`.
///
/// **`usage.iterations` must be ignored.** It reads like a list of sub-requests to add up, and it is
/// not: `sum(iterations) == the parent usage` on all 11,724 rows that carry one, with zero
/// exceptions. It is a breakdown of the parent, so counting it as well doubles every such row.
public struct ClaudeHistoryProvider: UsageHistoryProvider {
    public let id = "claude"
    public let displayName = "Claude Code"
    public let iconName = "claudecode-color"

    private let environment: [String: String]
    private let homeDirectory: URL
    private static let cache = JSONLParseCache<Entry, ParserState>(namespace: "claude-v1")

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    /// One parsed usage line, carrying the fields the dedup pass needs alongside the tokens.
    struct Entry: Codable, Sendable {
        var timestamp: Date
        var model: String
        var tokens: TokenBreakdown
        var messageID: String?
        var requestID: String?
        var isSidechain: Bool
    }

    private struct ParserState: Codable, Sendable {}

    public func scanHistory(daysBack: Int = 30, now: Date = Date()) async throws -> UsageHistory? {
        let projectDirectories = self.projectDirectories()
        guard !projectDirectories.isEmpty else { return nil }

        let since = DailyUsageAccumulator.sinceDate(daysBack: daysBack, now: now)
        let files = projectDirectories.flatMap { JSONLScanning.logFiles(in: $0, modifiedSince: since) }
        let entries = await Self.cache.entries(
            for: files,
            initialState: ParserState(),
            parse: Self.parse(file:fromOffset:state:)
        )

        // `(message.id, requestId)` identifies one assistant response. Within a group the row with
        // the most tokens is the finished one — the earlier repeats are mid-turn snapshots that
        // report zero or partial output. A non-sidechain row outranks a sidechain one carrying the
        // same id, so a subagent replaying its parent's message cannot displace the original.
        var best: [DedupKey: Entry] = [:]
        for entry in entries where entry.timestamp >= since {
            let key = DedupKey(messageID: entry.messageID, requestID: entry.requestID)
            guard let existing = best[key] else { best[key] = entry; continue }
            if rank(entry) > rank(existing) { best[key] = entry }
        }

        var accumulator = DailyUsageAccumulator()
        for entry in best.values {
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

    private struct DedupKey: Hashable {
        var messageID: String?
        var requestID: String?
    }

    private func rank(_ entry: Entry) -> (Int, Int) {
        (entry.isSidechain ? 0 : 1, entry.tokens.total)
    }

    // MARK: - Roots

    /// `CLAUDE_CONFIG_DIR` (comma-separated) wins, else `$XDG_CONFIG_HOME/claude` and `~/.claude`.
    /// An entry may name either the config dir or the `projects/` dir inside it.
    func projectDirectories() -> [String] {
        let roots = JSONLScanning.roots(
            environmentValue: environment["CLAUDE_CONFIG_DIR"],
            defaults: {
                var defaults: [String] = []
                if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
                    defaults.append(xdg + "/claude")
                }
                defaults.append(homeDirectory.appendingPathComponent(".claude").path)
                return defaults
            }()
        )

        var directories: [String] = []
        for root in roots {
            let candidate = root.hasSuffix("/projects") ? root : root + "/projects"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue {
                directories.append(candidate)
            }
        }
        return directories
    }

    // MARK: - Parsing

    private static let marker = Array(#""usage""#.utf8)

    static func parse(file url: URL) -> [Entry] {
        parse(file: url, fromOffset: 0, state: ParserState()).entries
    }

    private static func parse(
        file url: URL,
        fromOffset offset: Int64,
        state: ParserState
    ) -> JSONLParseBatch<Entry, ParserState> {
        var entries: [Entry] = []
        do {
            let nextOffset = try JSONLScanning.forEachLine(
                in: url,
                fromOffset: offset,
                containing: marker
            ) { line in
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let timestampText = object["timestamp"] as? String,
                      let timestamp = JSONLScanning.timestamp(timestampText)
                else { return }

                func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
                // `output_tokens` already contains the thinking tokens — verified: thinking never
                // exceeds output on any of the 7,033 rows that report both. `reasoning` rides along for
                // display only and is never added into the total again.
                let thinking = (usage["output_tokens_details"] as? [String: Any])
                    .flatMap { ($0["thinking_tokens"] as? NSNumber)?.intValue } ?? 0

                entries.append(
                    Entry(
                        timestamp: timestamp,
                        model: (message["model"] as? String) ?? "unknown",
                        tokens: TokenBreakdown(
                            input: count("input_tokens"),
                            output: count("output_tokens"),
                            cacheRead: count("cache_read_input_tokens"),
                            cacheWrite: count("cache_creation_input_tokens"),
                            reasoning: thinking
                        ),
                        messageID: message["id"] as? String,
                        requestID: object["requestId"] as? String,
                        isSidechain: (object["isSidechain"] as? Bool) ?? false
                    )
                )
            }
            return JSONLParseBatch(entries: entries, state: state, nextOffset: nextOffset)
        } catch {
            return JSONLParseBatch(
                entries: [], state: state, nextOffset: offset, succeeded: false
            )
        }
    }
}
