import Foundation
import Testing
@testable import LLMUsage
import LLMUsageHistory

private actor ScanCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

private struct UsageStoreFixtureProvider: UsageHistoryProvider {
    let counter: ScanCount
    let history: UsageHistory

    let id = "fixture"
    let displayName = "Fixture"

    func scanHistory(daysBack: Int, now: Date) async throws -> UsageHistory? {
        await counter.increment()
        return history
    }
}

@Test @MainActor
func rangeAndDaySelectionProjectOneSnapshotWithoutRescanning() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = try #require(calendar.date(from: DateComponents(
        timeZone: calendar.timeZone, year: 2026, month: 8, day: 28, hour: 12
    )))
    let today = DailyUsageAccumulator.dayKey(from: now, calendar: calendar)
    let yesterdayDate = try #require(calendar.date(byAdding: .day, value: -1, to: now))
    let yesterday = DailyUsageAccumulator.dayKey(from: yesterdayDate, calendar: calendar)
    let history = UsageHistory(
        providerID: "fixture",
        days: [
            DayUsage(day: yesterday, models: [
                ModelDayUsage(model: "fixture/model", tokens: TokenBreakdown(input: 300), requests: 1)
            ]),
            DayUsage(day: today, models: [
                ModelDayUsage(model: "fixture/model", tokens: TokenBreakdown(input: 700), requests: 2)
            ])
        ],
        hours: [
            HourUsage(hour: yesterday + "T10", tokens: TokenBreakdown(input: 300), requests: 1),
            HourUsage(hour: today + "T10", tokens: TokenBreakdown(input: 700), requests: 2)
        ]
    )
    let count = ScanCount()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = UsageHistoryRepository(
        providers: [UsageStoreFixtureProvider(counter: count, history: history)],
        databaseURL: directory.appendingPathComponent("cache.sqlite3")
    )
    let store = UsageStore(repository: repository, now: { now }, calendar: calendar)

    await store.refresh()
    #expect(store.totalTokens.total == 1_000)
    #expect(store.totalRequests == 3)
    #expect(await count.value == 1)

    store.range = .day
    #expect(store.totalTokens.total == 700)
    #expect(store.totalRequests == 2)
    #expect(store.results.first?.history?.tokens.total == 700)
    #expect(store.hourlySeries.reduce(0) { $0 + $1.tokens } == 700)
    #expect(await count.value == 1)

    store.stepDayBackward()
    #expect(store.totalTokens.total == 300)
    #expect(store.totalRequests == 1)
    #expect(store.results.first?.history?.tokens.total == 300)
    #expect(store.hourlySeries.reduce(0) { $0 + $1.tokens } == 300)
    #expect(await count.value == 1)
}
