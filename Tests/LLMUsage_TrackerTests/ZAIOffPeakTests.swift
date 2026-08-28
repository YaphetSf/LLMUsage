import Foundation
import Testing
@testable import LLMUsage_Tracker

private let sgt = TimeZone(identifier: "Asia/Singapore")!
private let london = TimeZone(identifier: "Europe/London")!

private func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int = 0,
    in timeZone: TimeZone
) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.date(from: components)!
}

@Test func weekdayAfternoonIsPeakUntilSixSingaporeTime() {
    let tuesdayAfternoon = date(2026, 8, 25, 15, 30, in: sgt)
    #expect(ZAIOffPeak.period(at: tuesdayAfternoon) == .peak(ends: date(2026, 8, 25, 18, in: sgt)))
}

@Test func peakWindowBoundaries() {
    #expect(ZAIOffPeak.period(at: date(2026, 8, 25, 14, 0, in: sgt))
        == .peak(ends: date(2026, 8, 25, 18, in: sgt)))
    #expect(ZAIOffPeak.period(at: date(2026, 8, 25, 17, 59, in: sgt))
        == .peak(ends: date(2026, 8, 25, 18, in: sgt)))
    #expect(ZAIOffPeak.period(at: date(2026, 8, 25, 13, 59, in: sgt))
        == .offPeak(ends: date(2026, 8, 25, 14, in: sgt)))
    #expect(ZAIOffPeak.period(at: date(2026, 8, 25, 18, 0, in: sgt))
        == .offPeak(ends: date(2026, 8, 26, 14, in: sgt)))
}

@Test func weekendRunsAtHalfRateUntilMondayAfternoon() {
    #expect(ZAIOffPeak.period(at: date(2026, 8, 29, 10, 0, in: sgt))
        == .offPeak(ends: date(2026, 8, 31, 14, in: sgt)))
    #expect(ZAIOffPeak.period(at: date(2026, 8, 30, 23, 30, in: sgt))
        == .offPeak(ends: date(2026, 8, 31, 14, in: sgt)))
}

@Test func fridayEveningOffPeakSpansTheWeekend() {
    #expect(ZAIOffPeak.period(at: date(2026, 8, 28, 19, 0, in: sgt))
        == .offPeak(ends: date(2026, 8, 31, 14, in: sgt)))
}

/// The window is pinned to Singapore regardless of the Mac's locale, so a UK Mac sees the
/// same peak span at 07:00–11:00 during BST and 06:00–10:00 during GMT.
@Test func ukWallClockMapsThroughDaylightSaving() {
    #expect(ZAIOffPeak.period(at: date(2026, 8, 25, 7, 0, in: london))
        == .peak(ends: date(2026, 8, 25, 18, in: sgt)))
    #expect(ZAIOffPeak.period(at: date(2026, 1, 20, 6, 0, in: london))
        == .peak(ends: date(2026, 1, 20, 18, in: sgt)))
}

@Test func ukDiscountEndsAtSevenLocalDuringBSTAndSixDuringGMT() {
    #expect(ZAIOffPeak.period(at: date(2026, 8, 25, 6, 30, in: london))
        == .offPeak(ends: date(2026, 8, 25, 7, 0, in: london)))
    #expect(ZAIOffPeak.period(at: date(2026, 1, 20, 5, 30, in: london))
        == .offPeak(ends: date(2026, 1, 20, 6, 0, in: london)))
}
