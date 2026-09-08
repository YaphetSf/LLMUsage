import AppKit
import Foundation
import LLMUsagePreferences

/// Owns every warm-up run: one timer, one execution slot per client, and a persisted watermark
/// so a restart never repeats an occurrence it already handled. Client-specific behaviour lives
/// in the executors; the timetable alone decides when.
@MainActor
final class WarmUpCoordinator {
    typealias Execute = @Sendable (WarmUpClient, WarmUpClientConfiguration) async -> WarmUpReport
    /// When the client's session window closes, fetched at the moment warm up fires.
    typealias Window = @Sendable (WarmUpClient) async -> Date?
    /// Slack for a timer that fires a moment late. An occurrence older than this is gone: a
    /// Mac asleep at its scheduled time simply misses it, and nothing is replayed afterwards.
    static let lateTolerance: TimeInterval = 60
    /// Re-check at least this often so clock drift, sleep and time-zone edits cannot strand a schedule.
    private static let maximumSleep: TimeInterval = 300

    private(set) var configuration: WarmUpConfiguration
    private(set) var state: WarmUpState
    private var running: [WarmUpClient: (id: UUID, automatic: Bool, task: Task<Void, Never>)] = [:]
    private var timer: Timer?
    private var distributedObservers: [NSObjectProtocol] = []
    private var localObservers: [NSObjectProtocol] = []
    private var stopped = false
    private let timetable: WarmUpTimetable
    private let execute: Execute
    private let window: Window
    private let persist: @MainActor (WarmUpState) -> Void
    private var lastPersistedState: WarmUpState
    private let now: () -> Date

    init(configuration: WarmUpConfiguration = WarmUpStore.loadConfiguration(),
         state: WarmUpState = WarmUpStore.loadState(),
         timetable: WarmUpTimetable = WarmUpTimetable(),
         now: @escaping () -> Date = { .now },
         persist: @escaping @MainActor (WarmUpState) -> Void = WarmUpStore.saveState,
         execute: @escaping Execute = { await WarmUpExecutor().run($0, configuration: $1) },
         window: @escaping Window = { _ in nil }) {
        self.configuration = configuration
        self.state = state
        self.timetable = timetable
        self.now = now
        self.persist = persist
        self.lastPersistedState = state
        self.execute = execute
        self.window = window
        // A helper killed mid-run cannot report a result; never leave a run open forever.
        for index in self.state.runs.indices where self.state.runs[index].isRunning {
            self.state.runs[index].outcome = .failed("Interrupted")
            self.state.runs[index].finishedAt = now()
        }
        // A client only owes occurrences from the moment it first had a timetable to watch.
        for client in WarmUpClient.allCases where self.state.handled[client.rawValue] == nil {
            self.state.handled[client.rawValue] = now()
        }
        persistChanges()
    }

    func start() {
        guard distributedObservers.isEmpty else { return }
        stopped = false
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: WarmUpStore.configurationChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateConfiguration(WarmUpStore.loadConfiguration()) }
        })
        distributedObservers.append(distributed.addObserver(
            forName: WarmUpStore.runRequested, object: nil, queue: .main
        ) { [weak self] notification in
            guard let name = notification.object as? String, let client = WarmUpClient(rawValue: name),
                  let rawID = notification.userInfo?["requestID"] as? String,
                  let id = UUID(uuidString: rawID) else { return }
            Task { @MainActor in self?.runNow(client, requestID: id) }
        })
        localObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.evaluate() } })
        for name in [NSNotification.Name.NSSystemTimeZoneDidChange, NSNotification.Name.NSSystemClockDidChange] {
            localObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.evaluate() } })
        }
        evaluate()
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        distributedObservers.removeAll()
        localObservers.forEach { NotificationCenter.default.removeObserver($0) }
        localObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        localObservers.removeAll()
        for client in Array(running.keys) { cancel(client) }
        persistChanges()
    }

    func updateConfiguration(_ new: WarmUpConfiguration) {
        for client in WarmUpClient.allCases {
            let schedules = new.schedules(for: client)
            guard schedules != configuration.schedules(for: client) else { continue }
            // An edited timetable never fires retroactively for occurrences it was not watching.
            state.handled[client.rawValue] = now()
            if schedules.isEmpty, running[client]?.automatic == true { cancel(client) }
        }
        configuration = new
        evaluate()
    }

    func runNow(_ client: WarmUpClient, requestID: UUID = UUID()) {
        guard !stopped, running[client] == nil,
              !state.runs.contains(where: { $0.id == requestID }) else { return }
        launch(client, id: requestID, scheduledAt: nil)
        persistChanges()
    }

    private static func clockTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    func nextRun(for client: WarmUpClient) -> Date? {
        timetable.nextRun(for: client, in: configuration, after: now())
    }

    func evaluate() {
        guard !stopped else { return }
        timer?.invalidate()
        timer = nil
        let date = now()
        for client in WarmUpClient.allCases {
            guard let due = timetable.dueRun(for: client, in: configuration, through: date),
                  due > state.handled[client.rawValue] ?? .distantPast else { continue }
            // Claim the occurrence before acting, so a crash cannot turn it into a second run.
            state.handled[client.rawValue] = due
            // A warm up already in flight satisfies this occurrence.
            guard running[client] == nil else { continue }
            if date.timeIntervalSince(due) > Self.lateTolerance {
                record(.skipped("Missed"), client: client, scheduledAt: due)
            } else {
                launch(client, scheduledAt: due)
            }
        }
        // Tasks started above cannot run before this returns, so the claim is persisted first.
        persistChanges()
        scheduleTimer(from: date)
    }

    /// A run that never reached a client, kept so the page can say why.
    private func record(_ outcome: WarmUpOutcome, client: WarmUpClient,
                        id: UUID = UUID(), scheduledAt: Date?) {
        var run = WarmUpRun(id: id, client: client, scheduledAt: scheduledAt, startedAt: now())
        run.finishedAt = run.startedAt
        run.outcome = outcome
        state.record(run)
    }

    private func scheduleTimer(from date: Date) {
        let upcoming = WarmUpClient.allCases.compactMap {
            timetable.nextRun(for: $0, in: configuration, after: date)
        }.min()
        guard let upcoming else { return }
        let interval = min(max(0.5, upcoming.timeIntervalSince(date)), Self.maximumSleep)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Fetches the client's session window, then warms it only if that window is closed. A
    /// window opens at the first request after the previous one closed, so a request sent
    /// inside one opens nothing: it spends quota and moves no boundary. The check happens here
    /// rather than in `evaluate` because the answer has to be current at the firing instant.
    private func launch(_ client: WarmUpClient, id: UUID = UUID(), scheduledAt: Date?) {
        let configuration = configuration[client]
        state.record(WarmUpRun(id: id, client: client, scheduledAt: scheduledAt, startedAt: now()))
        let task = Task { [weak self, execute, window] in
            let end = await window(client)
            guard let self else { return }
            let report: WarmUpReport
            if Task.isCancelled {
                report = .cancelled
            } else if let end, end > self.now() {
                report = WarmUpReport(outcome: .skipped("Warm until \(Self.clockTime(end))"))
            } else {
                let result = await execute(client, configuration)
                report = Task.isCancelled ? .cancelled : result
            }
            guard self.running[client]?.id == id else { return }
            self.running[client] = nil
            self.complete(id, report: report)
            self.persistChanges()
            self.evaluate()
        }
        running[client] = (id, scheduledAt != nil, task)
    }

    private func complete(_ id: UUID, report: WarmUpReport) {
        guard let index = state.runs.firstIndex(where: { $0.id == id }) else { return }
        state.runs[index].finishedAt = now()
        state.runs[index].outcome = report.outcome
        state.runs[index].model = report.model
        state.runs[index].detail = report.detail
        state.runs[index].tokens = report.tokens
    }

    private func cancel(_ client: WarmUpClient) {
        guard let current = running[client] else { return }
        current.task.cancel()
        // Keep the slot occupied until cancellation completes, preventing overlapping children.
        guard let index = state.runs.firstIndex(where: { $0.id == current.id }) else { return }
        state.runs[index].outcome = .cancelled
        state.runs[index].finishedAt = now()
    }

    /// Save every state transition, including recovery and configuration edits that
    /// produce no due work. Unchanged timer evaluations do not rewrite preferences.
    private func persistChanges() {
        guard state != lastPersistedState else { return }
        persist(state)
        lastPersistedState = state
    }
}
