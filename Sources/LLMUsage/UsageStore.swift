import Combine
import Foundation
import LLMUsageHistory
import SwiftUI

/// How granular each bar on the chart represents time.
enum UsageGranularity: Sendable {
    case hour, day
}

/// How far back the Usage page looks.
///
/// `.day` switches the chart to hourly bars — a single calendar day needs sub-day granularity
/// to be useful, and the day-navigator steps through past days within the scanned window.
enum UsageRange: Int, CaseIterable, Identifiable {
    case day = 1
    case week = 7
    case month = 30
    case quarter = 90

    var id: Int { rawValue }
    var daysBack: Int { rawValue }

    var label: String {
        switch self {
        case .day: "1 day"
        case .week: "7 days"
        case .month: "30 days"
        case .quarter: "90 days"
        }
    }

    var granularity: UsageGranularity {
        switch self {
        case .day: .hour
        case .week, .month, .quarter: .day
        }
    }
}

/// SwiftUI adapter for the Usage repository. The repository owns IO and persistence; this store
/// owns only page selection and one coherent projection of the cached 90-day snapshot.
@MainActor
final class UsageStore: ObservableObject {
    static let historyWindow = 90
    static let navigationScanWindow = 14

    @Published private(set) var results: [ProviderHistory] = []
    @Published private(set) var isScanning = false
    @Published private(set) var totalTokens = TokenBreakdown()
    @Published private(set) var totalRequests = 0
    @Published private(set) var dailySeries: [UsageDayPoint] = []
    @Published private(set) var hourlySeries: [UsageHourPoint] = []
    @Published var range: UsageRange = .month {
        didSet { if range != oldValue { rebuildProjection() } }
    }
    @Published var dayOffset = 0 {
        didSet { if dayOffset != oldValue { rebuildProjection() } }
    }

    private let repository: UsageHistoryRepository
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private var snapshot: UsageHistorySnapshot?
    private var hasStartedLoading = false
    private var refreshTask: Task<Void, Never>?

    init(
        repository: UsageHistoryRepository = UsageHistoryRepository(),
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.repository = repository
        self.now = now
        self.calendar = calendar
    }

    deinit { refreshTask?.cancel() }

    /// Starts stale-while-revalidate once for this app-owned store. Re-entering Usage calls this
    /// again, but the existing snapshot and refresh task remain untouched.
    func loadIfNeeded() {
        guard !hasStartedLoading else { return }
        hasStartedLoading = true
        isScanning = true
        let repository = self.repository
        let currentDate = now()
        let timeZone = calendar.timeZone
        refreshTask = Task { [weak self] in
            if let cached = await repository.cachedSnapshot(timeZone: timeZone) {
                guard !Task.isCancelled else { return }
                self?.apply(cached)
            }
            let fresh = await repository.refresh(
                daysBack: Self.historyWindow,
                now: currentDate,
                timeZone: timeZone
            )
            guard !Task.isCancelled else { return }
            self?.apply(fresh)
            self?.isScanning = false
        }
    }

    /// Deterministic test seam and an explicit future refresh entry point.
    func refresh() async {
        isScanning = true
        let fresh = await repository.refresh(
            daysBack: Self.historyWindow,
            now: now(),
            timeZone: calendar.timeZone
        )
        apply(fresh)
        hasStartedLoading = true
        isScanning = false
    }

    var hasAnyUsage: Bool { results.contains { $0.history?.days.isEmpty == false } }

    var everythingUninstalled: Bool {
        !results.isEmpty && results.allSatisfy {
            if case .notInstalled = $0.outcome { return true }
            return false
        }
    }

    // MARK: - Day navigation (only meaningful when range == .day)

    /// Days the scanner pulled data for, ascending. Wider than the visible window so the
    /// navigator can step back beyond today — `.day` displays a single day but the scan keeps
    /// `navigationScanWindow` of history so the chevrons have somewhere to go.
    var availableDayKeys: [String] {
        var seen: Set<String> = []
        let depth = Self.navigationScanWindow
        for offset in 0..<depth {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now())
            else { continue }
            seen.insert(DailyUsageAccumulator.dayKey(from: date, calendar: calendar))
        }
        return seen.sorted()
    }

    var availableDayCount: Int { availableDayKeys.count }

    /// The day key the chart is currently centred on, given `dayOffset`. 0 = most recent.
    var selectedDayKey: String? {
        let keys = availableDayKeys
        guard !keys.isEmpty else { return nil }
        let index = max(0, min(dayOffset, keys.count - 1))
        return keys[keys.count - 1 - index]
    }

    /// "Today" / "Yesterday" / "Mon Aug 25" — the label in the day-navigator.
    var selectedDayLabel: String {
        guard let key = selectedDayKey,
              let date = DailyUsageAccumulator.date(fromDayKey: key, calendar: calendar)
        else { return "" }
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var canStepDayBackward: Bool { dayOffset < max(0, availableDayCount - 1) }
    var canStepDayForward: Bool { dayOffset > 0 }

    func stepDayBackward() {
        guard canStepDayBackward else { return }
        dayOffset += 1
    }

    func stepDayForward() {
        guard canStepDayForward else { return }
        dayOffset -= 1
    }

    private func apply(_ snapshot: UsageHistorySnapshot) {
        self.snapshot = snapshot
        rebuildProjection()
    }

    private func rebuildProjection() {
        guard let snapshot else { return }
        let window: UsageHistoryWindow
        if range == .day, let selectedDayKey {
            window = .day(selectedDayKey)
        } else {
            window = .recentDays(range.daysBack)
        }
        let projection = UsageWindowProjection(
            snapshot: snapshot,
            window: window,
            now: now(),
            calendar: calendar
        )
        results = projection.results
        totalTokens = projection.totalTokens
        totalRequests = projection.totalRequests
        dailySeries = projection.dailySeries
        hourlySeries = projection.hourlySeries
    }
}
