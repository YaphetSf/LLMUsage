import Foundation

public enum UsageHistoryWindow: Equatable, Sendable {
    case day(String)
    case recentDays(Int)
}

/// One authoritative projection of a repository snapshot. Totals, provider cards and chart data
/// all consume this value, so no UI surface can accidentally aggregate a wider scan window.
public struct UsageWindowProjection: Equatable, Sendable {
    public let results: [ProviderHistory]
    public let totalTokens: TokenBreakdown
    public let totalRequests: Int
    public let dailySeries: [UsageDayPoint]
    public let hourlySeries: [UsageHourPoint]

    public init(
        snapshot: UsageHistorySnapshot,
        window: UsageHistoryWindow,
        now: Date,
        calendar: Calendar = .current
    ) {
        let dayKeys: Set<String>
        let dailyWindow: Int?
        let selectedDay: String?
        switch window {
        case .day(let key):
            dayKeys = [key]
            dailyWindow = nil
            selectedDay = key
        case .recentDays(let requestedDays):
            let days = max(requestedDays, 1)
            dayKeys = Set((0..<days).compactMap { offset in
                calendar.date(byAdding: .day, value: -offset, to: now)
                    .map { DailyUsageAccumulator.dayKey(from: $0, calendar: calendar) }
            })
            dailyWindow = days
            selectedDay = nil
        }

        results = snapshot.results.map { result in
            guard let history = result.history else { return result }
            let filtered = UsageHistory(
                providerID: history.providerID,
                days: history.days.filter { dayKeys.contains($0.day) },
                hours: history.hours.filter { dayKeys.contains($0.day) }
            )
            return ProviderHistory(
                id: result.id,
                displayName: result.displayName,
                iconName: result.iconName,
                outcome: .scanned(filtered)
            )
        }

        let histories = results.compactMap(\.history)
        totalTokens = histories.reduce(into: TokenBreakdown()) { $0 += $1.tokens }
        totalRequests = histories.reduce(0) { $0 + $1.requests }
        if let dailyWindow {
            dailySeries = UsageSeries.daily(
                for: histories,
                daysBack: dailyWindow,
                now: now,
                calendar: calendar
            )
        } else {
            dailySeries = []
        }
        if let selectedDay {
            hourlySeries = UsageSeries.hourly(
                for: histories,
                day: selectedDay,
                calendar: calendar
            )
        } else {
            hourlySeries = []
        }
    }
}
