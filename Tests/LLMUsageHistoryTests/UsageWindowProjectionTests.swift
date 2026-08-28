import Foundation
import Testing
@testable import LLMUsageHistory

@Test func sevenDayProjectionExcludesOlderScannedHistoryEverywhere() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone, year: 2026, month: 8, day: 28, hour: 12
    )))
    let today = DailyUsageAccumulator.dayKey(from: now, calendar: calendar)
    let eightDaysAgoDate = try #require(calendar.date(byAdding: .day, value: -8, to: now))
    let eightDaysAgo = DailyUsageAccumulator.dayKey(from: eightDaysAgoDate, calendar: calendar)
    let history = UsageHistory(providerID: "fixture", days: [
        DayUsage(day: eightDaysAgo, models: [
            ModelDayUsage(model: "old", tokens: TokenBreakdown(input: 900), requests: 9)
        ]),
        DayUsage(day: today, models: [
            ModelDayUsage(model: "current", tokens: TokenBreakdown(input: 100), requests: 1)
        ])
    ])
    let snapshot = UsageHistorySnapshot(
        generatedAt: now,
        daysBack: 90,
        timeZoneIdentifier: calendar.timeZone.identifier,
        results: [ProviderHistory(
            id: "fixture",
            displayName: "Fixture",
            iconName: "fixture",
            outcome: .scanned(history)
        )]
    )

    let projection = UsageWindowProjection(
        snapshot: snapshot,
        window: .recentDays(7),
        now: now,
        calendar: calendar
    )

    #expect(projection.totalTokens.total == 100)
    #expect(projection.totalRequests == 1)
    #expect(projection.results.first?.history?.tokens.total == 100)
    #expect(projection.results.first?.history?.requests == 1)
    #expect(projection.dailySeries.reduce(0) { $0 + $1.tokens } == 100)
}
