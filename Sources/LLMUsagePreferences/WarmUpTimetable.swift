import Foundation

/// Wall-clock scheduling in the machine's current time zone. A time that does not exist on a
/// day — the hour skipped by daylight saving — is skipped; a repeated hour resolves to its
/// first instant, and the coordinator's handled-occurrence watermark keeps it to one run.
public struct WarmUpTimetable: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    public func nextOccurrence(of schedule: WarmUpSchedule, after date: Date) -> Date? {
        occurrences(of: schedule, from: date, direction: .forward).min()
    }

    public func latestOccurrence(of schedule: WarmUpSchedule, through date: Date) -> Date? {
        guard schedule.isActive else { return nil }
        var candidates = occurrences(of: schedule, from: date, direction: .backward)
        // Include an occurrence exactly at `date` without extending the due window.
        if schedule.weekdays.contains(calendar.component(.weekday, from: date)),
           let today = firstOccurrence(of: schedule, on: date) {
            candidates.append(today)
        }
        return candidates.filter { $0 <= date }.max()
    }

    public func nextRun(for client: WarmUpClient, in configuration: WarmUpConfiguration,
                        after date: Date) -> Date? {
        configuration.schedules(for: client).compactMap { nextOccurrence(of: $0, after: date) }.min()
    }

    /// The most recent occurrence a client owes, across every schedule that selects it.
    public func dueRun(for client: WarmUpClient, in configuration: WarmUpConfiguration,
                       through date: Date) -> Date? {
        configuration.schedules(for: client).compactMap { latestOccurrence(of: $0, through: date) }.max()
    }

    private func occurrences(of schedule: WarmUpSchedule, from date: Date,
                             direction: Calendar.SearchDirection) -> [Date] {
        guard schedule.isActive else { return [] }
        return schedule.weekdays.compactMap { weekday in
            var cursor = date
            while let candidate = calendar.nextDate(
                after: cursor,
                matching: DateComponents(hour: schedule.hour, minute: schedule.minute, weekday: weekday),
                matchingPolicy: .strict, repeatedTimePolicy: .first, direction: direction
            ) {
                // Calendar searches in either direction can return the second instant
                // of a repeated hour. Always resolve forwards from that day's start.
                if let first = firstOccurrence(of: schedule, on: candidate),
                   direction == .backward || first > date {
                    return first
                }
                // The first instant already passed: search the next matching weekday,
                // rather than offering the repeated instant as another scheduled run.
                cursor = candidate
            }
            return nil
        }
    }

    private func firstOccurrence(of schedule: WarmUpSchedule, on day: Date) -> Date? {
        let start = calendar.startOfDay(for: day)
        guard let occurrence = calendar.nextDate(
            after: start.addingTimeInterval(-1),
            matching: DateComponents(hour: schedule.hour, minute: schedule.minute, second: 0),
            matchingPolicy: .strict, repeatedTimePolicy: .first, direction: .forward
        ), calendar.isDate(occurrence, inSameDayAs: day) else { return nil }
        return occurrence
    }
}
