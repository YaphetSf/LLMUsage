import Foundation
import LLMUsagePreferences
import SwiftUI

@MainActor
final class WarmUpSettings: ObservableObject {
    struct PendingRequest {
        let id: UUID
        let date: Date
    }

    @Published var configuration: WarmUpConfiguration {
        didSet { if configuration != oldValue { WarmUpStore.saveConfiguration(configuration) } }
    }
    @Published private(set) var state: WarmUpState
    @Published private(set) var pending: [WarmUpClient: PendingRequest] = [:]
    @Published private(set) var failures: [WarmUpClient: String] = [:]
    private let timetable = WarmUpTimetable()

    init() {
        configuration = WarmUpStore.loadConfiguration()
        state = WarmUpStore.loadState()
    }

    func refresh() {
        let updated = WarmUpStore.loadState()
        if state != updated { state = updated }
        for (client, request) in pending {
            if state.runs.contains(where: { $0.id == request.id }) {
                pending[client] = nil
            } else if Date().timeIntervalSince(request.date) > 10 {
                pending[client] = nil
                failures[client] = "Tracker unavailable"
            }
        }
    }

    func runNow(_ client: WarmUpClient) {
        guard !isRunning(client) else { return }
        failures[client] = nil
        let id = UUID()
        pending[client] = PendingRequest(id: id, date: Date())
        WarmUpStore.requestRun(client, id: id)
    }

    func isRunning(_ client: WarmUpClient) -> Bool {
        if pending[client] != nil { return true }
        guard let run = state.latestRun(for: client) else { return false }
        // A killed helper cannot send completion. Never leave the control permanently disabled.
        return run.isRunning && Date().timeIntervalSince(run.startedAt) < 130
    }

    /// The timetable is shared code, so the control center can answer this without the tracker.
    func nextRun(for client: WarmUpClient) -> Date? {
        timetable.nextRun(for: client, in: configuration, after: .now)
    }

    func save(_ schedule: WarmUpSchedule) {
        var schedules = configuration.schedules
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
        configuration.schedules = schedules.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    func remove(_ schedule: WarmUpSchedule) {
        configuration.schedules.removeAll { $0.id == schedule.id }
    }

    func binding(to schedule: WarmUpSchedule) -> Binding<Bool> {
        Binding(
            get: { self.configuration.schedules.first { $0.id == schedule.id }?.enabled ?? false },
            set: { value in
                guard let index = self.configuration.schedules.firstIndex(where: { $0.id == schedule.id })
                else { return }
                self.configuration.schedules[index].enabled = value
            }
        )
    }

    func binding(to client: WarmUpClient) -> Binding<WarmUpClientConfiguration> {
        Binding(get: { self.configuration[client] }, set: { self.configuration[client] = $0 })
    }
}
