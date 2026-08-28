import Foundation

/// Token counts for one request, one model-day, or one day. Buckets are kept separate because they
/// behave differently everywhere: cached input is the bulk of agent traffic and says something very
/// different about a session than fresh input does.
///
/// **Invariant, and the one every adapter must normalize to: `output` always INCLUDES reasoning,
/// and `reasoning` is a display-only subset of it.** Tools disagree about this and the disagreement
/// is silent — Claude's `thinking_tokens` and Codex's `reasoning_output_tokens` are already inside
/// their `output_tokens`, while OpenCode writes reasoning as a *sibling* bucket (verified: its own
/// `tokens.total` equals `input + output + cache.read + cache.write + reasoning` on every row that
/// carries one). Taking each tool's fields at face value silently undercounts the reasoning-heavy
/// ones and makes cross-provider totals incomparable, so each adapter folds reasoning into `output`
/// on the way in and `total` never adds it again.
///
/// `input` is always the uncached portion.
public struct TokenBreakdown: Hashable, Sendable, Codable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var reasoning: Int

    public init(
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoning: Int = 0
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    public var total: Int { input + output + cacheRead + cacheWrite }

    public static func + (lhs: Self, rhs: Self) -> Self {
        TokenBreakdown(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }

    public static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
}

/// One model's usage within one day.
public struct ModelDayUsage: Equatable, Sendable, Codable {
    /// Qualified as `providerID/modelID` so the same model reached through two gateways
    /// (e.g. `glm/glm-5.3` direct vs `vectide/glm-5.3`) stays distinguishable.
    public var model: String
    public var tokens: TokenBreakdown
    public var requests: Int

    public init(model: String, tokens: TokenBreakdown, requests: Int) {
        self.model = model
        self.tokens = tokens
        self.requests = requests
    }
}

/// One local calendar day, aggregated.
public struct DayUsage: Equatable, Sendable, Codable {
    /// `yyyy-MM-dd` in the machine's local time zone.
    public var day: String
    public var models: [ModelDayUsage]

    public init(day: String, models: [ModelDayUsage]) {
        self.day = day
        self.models = models
    }

    public var tokens: TokenBreakdown { models.reduce(into: TokenBreakdown()) { $0 += $1.tokens } }
    public var requests: Int { models.reduce(0) { $0 + $1.requests } }
}

/// One local hour-bucket of usage, totalled across models. Carries no model breakdown because the
/// hourly chart only renders one bar per hour — per-model splits are kept on `DayUsage` where the
/// Provider card surfaces them.
public struct HourUsage: Equatable, Sendable, Codable {
    /// `yyyy-MM-ddTHH` in the machine's local time zone.
    public var hour: String
    public var tokens: TokenBreakdown
    public var requests: Int

    public init(hour: String, tokens: TokenBreakdown, requests: Int) {
        self.hour = hour
        self.tokens = tokens
        self.requests = requests
    }

    public var day: String { String(hour.prefix(10)) }
}

/// A provider's local usage history, days ascending.
///
/// `hours` covers the same window as `days`, hour-aligned. It is always populated alongside the
/// day buckets so the chart can switch between day and hour granularity without re-scanning.
public struct UsageHistory: Equatable, Sendable, Codable {
    public var providerID: String
    public var days: [DayUsage]
    public var hours: [HourUsage]

    public init(providerID: String, days: [DayUsage], hours: [HourUsage] = []) {
        self.providerID = providerID
        self.days = days
        self.hours = hours
    }

    public var tokens: TokenBreakdown { days.reduce(into: TokenBreakdown()) { $0 += $1.tokens } }
    public var requests: Int { days.reduce(0) { $0 + $1.requests } }
}

/// A source of *historical* token data, read from what a CLI already wrote to disk.
///
/// Deliberately separate from `UsageProvider`: that one polls a vendor endpoint for live quota
/// percentages on a 1-minute timer, this one scans local logs on change. Different shapes, different
/// costs, different failure modes — one protocol covering both would serve neither.
public protocol UsageHistoryProvider: Sendable {
    var id: String { get }
    var displayName: String { get }

    /// Name of the artwork that stands for this tool, defaulting to `id`.
    ///
    /// Separate from `id` because the tool and the account it bills to are not the same thing and
    /// do not share a mark: the quota cards elsewhere in the app speak about *Claude the plan* and
    /// wear the Anthropic starburst, while this module speaks about *Claude Code the CLI*, which
    /// has its own logo. Overriding here keeps that distinction with the provider rather than in a
    /// lookup table in the view.
    var iconName: String { get }

    /// `nil` means the tool leaves no footprint on this machine (never installed) — distinct from a
    /// present-but-empty history, which returns a `UsageHistory` with no days.
    func scanHistory(daysBack: Int, now: Date) async throws -> UsageHistory?
}

public extension UsageHistoryProvider {
    var iconName: String { id }
}

public enum UsageHistoryError: Error, Equatable, Sendable {
    /// Data files exist but none could be opened (permissions, corruption, an exclusive lock).
    case logsUnreadable(String)
}

extension UsageHistoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .logsUnreadable(let detail): "Usage logs unreadable: \(detail)"
        }
    }
}

/// Buckets usage into local calendar days keyed by `provider/model`.
///
/// Shared by every history provider so "what day is this request on" is answered once. Uses the
/// local calendar, not a rolling `now - 86400×n` window: a wall-clock cutoff lands mid-morning and
/// would silently drop the earliest day's early requests.
public struct DailyUsageAccumulator {
    private struct Key: Hashable {
        var day: String
        var model: String
    }

    private struct Bucket {
        var tokens = TokenBreakdown()
        var requests = 0
    }

    private var buckets: [Key: Bucket] = [:]
    private var hourBuckets: [String: Bucket] = [:]

    public init() {}

    public static func dayKey(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Inverse of `dayKey(from:)`: back to a `Date` at the start of that local day. Charts need a
    /// real `Date` for a time axis, and reparsing the key is what keeps the axis aligned with the
    /// buckets instead of drifting through a second formatter with its own calendar assumptions.
    public static func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Hour-aligned bucket key in the local calendar: `yyyy-MM-ddTHH`. The `T` separator follows
    /// ISO-8601 and keeps the day prefix greppable when matching against `dayKey` output.
    public static func hourKey(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return String(format: "%04d-%02d-%02dT%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0)
    }

    /// Inverse of `hourKey(from:)` — returns the start of that local hour. Returns `nil` for keys
    /// that do not parse, so callers can filter bad data without crashing.
    public static func date(fromHourKey key: String, calendar: Calendar = .current) -> Date? {
        guard key.count == 13 else { return nil }
        let dayString = String(key.prefix(10))
        let hourString = String(key.suffix(2))
        guard let day = date(fromDayKey: dayString, calendar: calendar),
              let hour = Int(hourString)
        else { return nil }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
    }

    /// Start of the oldest local day included in a `daysBack`-day window ending today.
    public static func sinceDate(daysBack: Int, now: Date, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(max(daysBack, 1) - 1), to: startOfToday) ?? startOfToday
    }

    public mutating func add(day: String, model: String, tokens: TokenBreakdown, requests: Int = 1) {
        var bucket = buckets[Key(day: day, model: model)] ?? Bucket()
        bucket.tokens += tokens
        bucket.requests += requests
        buckets[Key(day: day, model: model)] = bucket
    }

    /// Hour-bucket add. The hour key carries its own day prefix so this is independent of
    /// `add(day:model:)` and the two streams cannot get out of sync — every entry adds to both.
    public mutating func addHour(hour: String, tokens: TokenBreakdown, requests: Int = 1) {
        var existing = hourBuckets[hour] ?? Bucket()
        existing.tokens += tokens
        existing.requests += requests
        hourBuckets[hour] = existing
    }

    public func build(providerID: String) -> UsageHistory {
        var byDay: [String: [ModelDayUsage]] = [:]
        for (key, bucket) in buckets {
            byDay[key.day, default: []].append(
                ModelDayUsage(model: key.model, tokens: bucket.tokens, requests: bucket.requests)
            )
        }

        let days = byDay
            .map { DayUsage(day: $0.key, models: $0.value.sorted { $0.model < $1.model }) }
            .sorted { $0.day < $1.day }
        let hours = hourBuckets
            .map { HourUsage(hour: $0.key, tokens: $0.value.tokens, requests: $0.value.requests) }
            .sorted { $0.hour < $1.hour }
        return UsageHistory(providerID: providerID, days: days, hours: hours)
    }
}
