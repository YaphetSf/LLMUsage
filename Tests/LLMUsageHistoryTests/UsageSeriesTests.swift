import Foundation
import Testing
@testable import LLMUsageHistory

private func history(_ days: [(day: String, tokens: Int)]) -> UsageHistory {
    UsageHistory(
        providerID: "test",
        days: days.map { entry in
            DayUsage(day: entry.day, models: [
                ModelDayUsage(model: "p/m", tokens: TokenBreakdown(input: entry.tokens), requests: 1)
            ])
        }
    )
}

@Test func seriesCarriesQuietDaysAsZeroSoTheAxisStaysACalendar() {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let calendar = Calendar.current
    let today = DailyUsageAccumulator.dayKey(from: now, calendar: calendar)
    let twoDaysAgo = DailyUsageAccumulator.dayKey(
        from: calendar.date(byAdding: .day, value: -2, to: now)!, calendar: calendar
    )

    let series = UsageSeries.daily(
        for: [history([(today, 500), (twoDaysAgo, 100)])],
        daysBack: 3, now: now, calendar: calendar
    )

    #expect(series.count == 3)
    #expect(series.map(\.tokens) == [100, 0, 500])
    #expect(series[1].requests == 0)
    #expect(series.map(\.date) == series.map(\.date).sorted())
}

@Test func seriesSumsAcrossProviders() {
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let today = DailyUsageAccumulator.dayKey(from: now)

    let series = UsageSeries.daily(
        for: [history([(today, 300)]), history([(today, 700)])],
        daysBack: 1, now: now
    )

    #expect(series.count == 1)
    #expect(series[0].tokens == 1_000)
    #expect(series[0].requests == 2)
}

@Test func emptyHistoriesStillProduceAFullWindowOfZeroes() {
    let series = UsageSeries.daily(for: [], daysBack: 7, now: Date())
    #expect(series.count == 7)
    #expect(series.allSatisfy { $0.tokens == 0 && $0.requests == 0 })
}

@Test func dayKeyRoundTripsThroughItsInverse() {
    let calendar = Calendar.current
    let date = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000))
    let key = DailyUsageAccumulator.dayKey(from: date, calendar: calendar)

    #expect(DailyUsageAccumulator.date(fromDayKey: key, calendar: calendar) == date)
    #expect(DailyUsageAccumulator.date(fromDayKey: "not-a-day") == nil)
}

@Test func hourKeyRoundTripsThroughItsInverse() {
    let calendar = Calendar.current
    let date = calendar.date(bySettingHour: 14, minute: 0, second: 0,
                             of: Date(timeIntervalSince1970: 1_780_000_000))!
    let key = DailyUsageAccumulator.hourKey(from: date, calendar: calendar)

    #expect(DailyUsageAccumulator.date(fromHourKey: key, calendar: calendar) == date)
    #expect(DailyUsageAccumulator.date(fromHourKey: "not-an-hour") == nil)
}

@Test func hourlySeriesFillsTwentyFourSlotsAndSumsAcrossProviders() {
    let calendar = Calendar.current
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let today = DailyUsageAccumulator.dayKey(from: now, calendar: calendar)
    let fourteen = DailyUsageAccumulator.hourKey(
        from: calendar.date(bySettingHour: 14, minute: 0, second: 0, of: now)!,
        calendar: calendar
    )

    let histories: [UsageHistory] = [
        UsageHistory(providerID: "a", days: [], hours: [
            HourUsage(hour: fourteen, tokens: TokenBreakdown(input: 300), requests: 1)
        ]),
        UsageHistory(providerID: "b", days: [], hours: [
            HourUsage(hour: fourteen, tokens: TokenBreakdown(input: 700), requests: 2)
        ])
    ]

    let series = UsageSeries.hourly(for: histories, day: today, calendar: calendar)

    #expect(series.count == 24)
    #expect(series.allSatisfy { $0.tokens == 0 && $0.requests == 0 } == false)
    let fourteenIndex = 14
    #expect(series[fourteenIndex].tokens == 1_000)
    #expect(series[fourteenIndex].requests == 3)
}

@Test func hourlySeriesIgnoresHoursFromOtherDays() {
    let calendar = Calendar.current
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let today = DailyUsageAccumulator.dayKey(from: now, calendar: calendar)
    let yesterday = DailyUsageAccumulator.dayKey(
        from: calendar.date(byAdding: .day, value: -1, to: now)!, calendar: calendar
    )
    let yesterdayTen = yesterday + "T10"

    let history = UsageHistory(providerID: "p", days: [], hours: [
        HourUsage(hour: yesterdayTen, tokens: TokenBreakdown(input: 999), requests: 1)
    ])

    let series = UsageSeries.hourly(for: [history], day: today, calendar: calendar)

    #expect(series.count == 24)
    #expect(series.allSatisfy { $0.tokens == 0 && $0.requests == 0 })
}

@Test func hourlySeriesReturnsEmptyForAnUnknownDay() {
    let series = UsageSeries.hourly(for: [], day: "not-a-day")
    #expect(series.isEmpty)
}

@Test func tokenAbbreviationSwitchesUnitAtEachThreshold() {
    #expect(UsageFormat.tokens(0) == "0")
    #expect(UsageFormat.tokens(9_999) == "9,999")
    #expect(UsageFormat.tokens(10_000) == "10K")
    #expect(UsageFormat.tokens(999_999) == "1000K")
    #expect(UsageFormat.tokens(1_500_000) == "1.5M")
    #expect(UsageFormat.tokens(274_103_534) == "274.1M")
    #expect(UsageFormat.tokens(2_398_211_447) == "2.40B")
}

@Test func sinceDateRespectsTheLocalCalendar() {
    let calendar = Calendar.current
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let startOfToday = calendar.startOfDay(for: now)

    #expect(DailyUsageAccumulator.sinceDate(daysBack: 1, now: now, calendar: calendar)
            == startOfToday)
    #expect(DailyUsageAccumulator.sinceDate(daysBack: 7, now: now, calendar: calendar)
            == calendar.date(byAdding: .day, value: -6, to: startOfToday))
}

@Test func dayAndHourStreamsProduceMatchingTotals() {
    // Adding the same request through both `add(day:)` and `addHour(...)` is the contract the
    // chart depends on — if they drift, the daily total stops matching the hourly one.
    var acc = DailyUsageAccumulator()
    let day = "2026-08-28"
    let hour = "2026-08-28T10"

    acc.add(day: day, model: "p/m", tokens: TokenBreakdown(input: 600, output: 100))
    acc.addHour(hour: hour, tokens: TokenBreakdown(input: 600, output: 100))

    let history = acc.build(providerID: "p")

    #expect(history.days.count == 1)
    #expect(history.hours.count == 1)
    #expect(history.days[0].tokens.input == history.hours[0].tokens.input)
    #expect(history.days[0].tokens.output == history.hours[0].tokens.output)
}

@Test func emptyAccumulatorBuildsAnEmptyHistory() {
    let history = DailyUsageAccumulator().build(providerID: "p")
    #expect(history.days.isEmpty)
    #expect(history.hours.isEmpty)
    #expect(history.tokens == TokenBreakdown())
    #expect(history.requests == 0)
}

@Test func hourKeyRejectsOverlongKeysWithoutCrashing() {
    #expect(DailyUsageAccumulator.date(fromHourKey: "2026-08-28") == nil)
    #expect(DailyUsageAccumulator.date(fromHourKey: "2026-08-28T10:30:00") == nil)
    // The hour suffix is silently fixed-width: a bad hour falls back to nil rather than
    // returning a bogus `Date`.
    #expect(DailyUsageAccumulator.date(fromHourKey: "2026-08-28Tabc") == nil)
}

