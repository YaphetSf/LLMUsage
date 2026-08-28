import Foundation

/// One day on the usage chart. Days with no activity are carried with zeroes rather than dropped,
/// so the axis stays a real calendar — a gap has to read as a quiet day, not collapse the days
/// around it together.
public struct UsageDayPoint: Identifiable, Equatable, Sendable {
    public let date: Date
    public let tokens: Int
    public let requests: Int

    public var id: Date { date }

    public init(date: Date, tokens: Int, requests: Int) {
        self.date = date
        self.tokens = tokens
        self.requests = requests
    }
}

/// One hour on the usage chart. Quiet hours are carried with zeroes so the axis stays a real
/// timeline — a session that ran 14:00–15:00 must leave 15:00 as a quiet hour, not collapse the
/// neighbours into it.
public struct UsageHourPoint: Identifiable, Equatable, Sendable {
    public let date: Date
    public let tokens: Int
    public let requests: Int

    public var id: Date { date }

    public init(date: Date, tokens: Int, requests: Int) {
        self.date = date
        self.tokens = tokens
        self.requests = requests
    }
}

public enum UsageSeries {
    /// Every local day in the window, ascending, totalled across the given histories.
    public static func daily(
        for histories: [UsageHistory],
        daysBack: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> [UsageDayPoint] {
        var tokensByDay: [String: Int] = [:]
        var requestsByDay: [String: Int] = [:]
        for history in histories {
            for day in history.days {
                tokensByDay[day.day, default: 0] += day.tokens.total
                requestsByDay[day.day, default: 0] += day.requests
            }
        }

        let start = DailyUsageAccumulator.sinceDate(daysBack: daysBack, now: now, calendar: calendar)
        return (0..<max(daysBack, 1)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = DailyUsageAccumulator.dayKey(from: date, calendar: calendar)
            return UsageDayPoint(
                date: date, tokens: tokensByDay[key] ?? 0, requests: requestsByDay[key] ?? 0
            )
        }
    }

    /// The 24 hour-buckets of `dayKey`, ascending, totalled across the given histories.
    ///
    /// Hours with no activity are carried as zeroes — same reasoning as `daily`: the chart must
    /// show a real clock face, not a series of varying gaps.
    public static func hourly(
        for histories: [UsageHistory],
        day dayKey: String,
        calendar: Calendar = .current
    ) -> [UsageHourPoint] {
        var tokensByHour: [String: Int] = [:]
        var requestsByHour: [String: Int] = [:]
        for history in histories {
            for hour in history.hours where hour.day == dayKey {
                tokensByHour[hour.hour, default: 0] += hour.tokens.total
                requestsByHour[hour.hour, default: 0] += hour.requests
            }
        }

        guard let dayStart = DailyUsageAccumulator.date(fromDayKey: dayKey, calendar: calendar) else {
            return []
        }
        return (0..<24).compactMap { hour in
            guard let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dayStart)
            else { return nil }
            let key = DailyUsageAccumulator.hourKey(from: date, calendar: calendar)
            return UsageHourPoint(
                date: date, tokens: tokensByHour[key] ?? 0, requests: requestsByHour[key] ?? 0
            )
        }
    }
}

/// Human-facing number formatting for usage figures.
public enum UsageFormat {
    /// Token counts run to hundreds of millions; the exact digit is never the point, the order of
    /// magnitude is. Below 10k the raw grouped number is still readable, so it stays.
    public static func tokens(_ value: Int) -> String {
        switch abs(value) {
        case 1_000_000_000...:
            String(format: "%.2fB", Double(value) / 1_000_000_000)
        case 1_000_000...:
            String(format: "%.1fM", Double(value) / 1_000_000)
        case 10_000...:
            String(format: "%.0fK", Double(value) / 1_000)
        default:
            value.formatted(.number.grouping(.automatic))
        }
    }

    public static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}
