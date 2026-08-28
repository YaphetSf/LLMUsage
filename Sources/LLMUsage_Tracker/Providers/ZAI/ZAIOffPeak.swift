import Foundation

/// Z.ai bills GLM Coding Plan credits at half rate outside peak hours: peak is
/// Monday–Friday 14:00–18:00 Singapore time (UTC+8), everything else — evenings, nights,
/// weekends — is off-peak. The window is always evaluated in Asia/Singapore, never in the
/// Mac's locale, so it stays correct across DST: a UK user sees peak at 07:00–11:00 during
/// BST and 06:00–10:00 during GMT without this type knowing either exists.
enum ZAIOffPeak: Equatable {
    /// Half-rate credits.
    case offPeak(ends: Date)
    /// Full-rate credits.
    case peak(ends: Date)

    static let timeZone = TimeZone(identifier: "Asia/Singapore")!

    static func period(at date: Date, timeZone: TimeZone = Self.timeZone) -> Self {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = { calendar.dateComponents([.weekday, .hour, .minute], from: $0) }

        let now = components(date)
        let isWeekday = (2...6).contains(now.weekday!)
        let minuteOfDay = now.hour! * 60 + now.minute!
        if isWeekday, (14 * 60)..<(18 * 60) ~= minuteOfDay {
            return .peak(ends: wallClock(18, 0, on: date, in: calendar))
        }
        return .offPeak(ends: nextPeakStart(after: date, in: calendar))
    }

    /// 14:00 on the next Mon–Fri, today included when the window has not opened yet.
    private static func nextPeakStart(after date: Date, in calendar: Calendar) -> Date {
        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset,
                                          to: calendar.startOfDay(for: date)),
                  (2...6).contains(calendar.component(.weekday, from: day))
            else { continue }
            let start = wallClock(14, 0, on: day, in: calendar)
            if start > date { return start }
        }
        preconditionFailure("Every 8-day span contains a weekday 14:00")
    }

    private static func wallClock(_ hour: Int, _ minute: Int, on day: Date, in calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }
}
