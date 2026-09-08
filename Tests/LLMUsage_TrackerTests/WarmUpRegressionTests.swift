import Foundation
import LLMUsagePreferences
import Testing
@testable import LLMUsage_Tracker

private func regressionCalendar(_ zone: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: zone)!
    return c
}
private func instant(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }

@Test func latestOccurrenceUsesFirstInstantOfRepeatedHour() {
    let table = WarmUpTimetable(calendar: regressionCalendar("Europe/London"))
    let schedule = WarmUpSchedule(hour: 1, minute: 30, clients: [.codex])
    let first = instant("2026-10-25T00:30:00Z")
    let afterSecond = instant("2026-10-25T01:35:00Z")
    let due = table.latestOccurrence(of: schedule, through: afterSecond)
    #expect(due == first)
}

@Test func latestOccurrenceNeverIncludesAFutureInstant() {
    let table = WarmUpTimetable(calendar: regressionCalendar("UTC"))
    let schedule = WarmUpSchedule(hour: 8, clients: [.codex])
    let slot = instant("2026-09-07T08:00:00Z")
    let due = table.latestOccurrence(of: schedule, through: slot.addingTimeInterval(-0.5))
    #expect(due! < slot)
}

@Test func codexRejectsMessageWithoutTurnCompletion() {
    let output = Data("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Thinking about the request\"}}\n".utf8)
    #expect(CLIWarmUpExecutor.completion(.codex, output: output) == nil)
}

@Test func glmRejectsTruncatedReasoningWithoutAnswer() {
    let output = Data("{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"content\":\"\",\"reasoning_content\":\"I need to reply\"}}]}".utf8)
    #expect(GLMWarmUpExecutor.completion(output) == nil)
}

@MainActor
@Test func startupPersistsInterruptedRunsWithoutWaitingForDueWork() {
    var state = WarmUpState()
    state.record(WarmUpRun(client: .codex, startedAt: instant("2026-09-07T08:00:00Z")))
    var saved: WarmUpState?
    let coordinator = WarmUpCoordinator(configuration: .init(), state: state,
        now: { instant("2026-09-07T08:02:00Z") }, persist: { saved = $0 },
        execute: { _, _ in WarmUpReport(outcome: .succeeded) })
    coordinator.evaluate()
    #expect(saved?.latestRun(for: .codex)?.outcome == .failed("Interrupted"))
    coordinator.stop()
}

@MainActor
@Test func coordinatorDoesNotRepeatTheSecondDSTInstant() {
    var config = WarmUpConfiguration()
    config.schedules = [WarmUpSchedule(hour: 1, minute: 30, clients: [.codex])]
    var state = WarmUpState()
    state.handled["codex"] = instant("2026-10-25T00:30:00Z")
    let coordinator = WarmUpCoordinator(configuration: config, state: state,
        timetable: WarmUpTimetable(calendar: regressionCalendar("Europe/London")),
        now: { instant("2026-10-25T01:35:00Z") }, persist: { _ in },
        execute: { _, _ in WarmUpReport(outcome: .succeeded) })
    coordinator.evaluate()
    #expect(coordinator.state.runs.isEmpty)
    coordinator.stop()
}

@MainActor
@Test func editedScheduleWatermarkSurvivesCrash() {
    var original = WarmUpConfiguration()
    original.schedules = [WarmUpSchedule(hour: 7, clients: [.codex])]
    var saved = WarmUpState()
    saved.handled["codex"] = instant("2026-09-07T07:00:00Z")
    let first = WarmUpCoordinator(configuration: original, state: saved,
        timetable: WarmUpTimetable(calendar: regressionCalendar("UTC")),
        now: { instant("2026-09-07T08:05:00Z") }, persist: { saved = $0 },
        execute: { _, _ in WarmUpReport(outcome: .succeeded) })
    var edited = original
    edited.schedules[0].hour = 8
    first.updateConfiguration(edited)
    let diskBeforeCrash = saved
    let restarted = WarmUpCoordinator(configuration: edited, state: diskBeforeCrash,
        timetable: WarmUpTimetable(calendar: regressionCalendar("UTC")),
        now: { instant("2026-09-07T08:06:00Z") }, persist: { _ in },
        execute: { _, _ in WarmUpReport(outcome: .succeeded) })
    restarted.evaluate()
    #expect(restarted.state.runs.isEmpty)
    first.stop()
    restarted.stop()
}

@Test func repeatedHourRemainsOneOccurrenceAcrossBothInstants() {
    let table = WarmUpTimetable(calendar: regressionCalendar("Europe/London"))
    let schedule = WarmUpSchedule(hour: 1, minute: 30, clients: [.codex])
    let first = instant("2026-10-25T00:30:00Z")
    let previous = instant("2026-10-24T00:30:00Z")
    let following = instant("2026-10-26T01:30:00Z")
    for offset in [-0.5, 0, 0.5, 1800, 3599.5, 3600, 3600.5, 3900] {
        let now = first.addingTimeInterval(offset)
        #expect(table.latestOccurrence(of: schedule, through: now) == (offset < 0 ? previous : first))
        #expect(table.nextOccurrence(of: schedule, after: now) == (offset < 0 ? first : following))
    }
    // A gap does not manufacture an occurrence or erase the previous valid day.
    #expect(table.latestOccurrence(of: schedule, through: instant("2026-03-29T02:00:00Z"))
        == instant("2026-03-28T01:30:00Z"))
}

@MainActor
@Test func coordinatorWaitsUntilTheExactScheduledInstant() {
    var config = WarmUpConfiguration()
    config.schedules = [WarmUpSchedule(hour: 8, clients: [.codex])]
    let slot = instant("2026-09-07T08:00:00Z")
    var now = slot.addingTimeInterval(-60)
    let coordinator = WarmUpCoordinator(configuration: config, state: .init(),
        timetable: WarmUpTimetable(calendar: regressionCalendar("UTC")),
        now: { now }, persist: { _ in }, execute: { _, _ in WarmUpReport(outcome: .succeeded) })
    defer { coordinator.stop() }
    now = slot.addingTimeInterval(-0.5)
    coordinator.evaluate()
    #expect(coordinator.state.runs.isEmpty)
    now = slot
    coordinator.evaluate()
    #expect(coordinator.state.latestRun(for: .codex)?.scheduledAt == slot)
    #expect(coordinator.state.latestRun(for: .codex)?.startedAt == slot)
}

@Test func codexRejectsIncompleteOrFailedFinalTurns() {
    let answer = #"{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}"#
    let completed = #"{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":1}}"#
    let started = #"{"type":"turn.started"}"#
    for events in [
        [completed],
        [answer, #"{"type":"turn.failed"}"#],
        [answer, completed, started, answer],
        [answer, completed, #"{"type":"error"}"#]
    ] {
        #expect(CLIWarmUpExecutor.completion(.codex, output: Data(events.joined(separator: "\n").utf8)) == nil)
    }
    #expect(CLIWarmUpExecutor.completion(.codex, output: Data([started, answer, completed]
        .joined(separator: "\n").utf8))?.tokens == 3)
}

@Test func glmRequiresFinishedAnswerEvenWhenPartialContentExists() throws {
    for (reason, content, reasoning) in [
        ("length", "O", "thinking"),
        ("stop", "  \n", "thinking"),
        ("tool_calls", "OK", ""),
        ("", "OK", "")
    ] {
        let data = try JSONSerialization.data(withJSONObject: ["choices": [[
            "finish_reason": reason, "message": ["content": content, "reasoning_content": reasoning]
        ]]])
        #expect(GLMWarmUpExecutor.completion(data) == nil)
    }
}
