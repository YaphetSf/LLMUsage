import Foundation
import LLMUsagePreferences
import Testing
@testable import LLMUsage_Tracker

private let london: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}()
private let timetable = WarmUpTimetable(calendar: london)

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
                  in calendar: Calendar = london) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func schedule(hour: Int, minute: Int = 0, weekdays: Set<Int> = Set(1...7),
                      clients: Set<WarmUpClient>) -> WarmUpSchedule {
    WarmUpSchedule(hour: hour, minute: minute, weekdays: weekdays, clients: clients)
}

private func configuration(_ schedules: WarmUpSchedule...) -> WarmUpConfiguration {
    var configuration = WarmUpConfiguration()
    configuration.schedules = schedules
    return configuration
}

// MARK: - Timetable

@Test func timetableFindsSurroundingOccurrencesOnSelectedWeekdays() {
    let weekdays = schedule(hour: 7, minute: 55, weekdays: [2, 3, 4, 5, 6], clients: [.claude])
    let monday = date(2026, 9, 7, 12, 0)
    #expect(timetable.nextOccurrence(of: weekdays, after: monday) == date(2026, 9, 8, 7, 55))
    #expect(timetable.latestOccurrence(of: weekdays, through: monday) == date(2026, 9, 7, 7, 55))
    // Friday looks past the weekend in both directions.
    let friday = date(2026, 9, 11, 12, 0)
    #expect(timetable.nextOccurrence(of: weekdays, after: friday) == date(2026, 9, 14, 7, 55))
    #expect(timetable.latestOccurrence(of: schedule(hour: 7, minute: 55, weekdays: [2], clients: [.claude]),
                                       through: friday) == date(2026, 9, 7, 7, 55))
    // An occurrence exactly now is due, not upcoming.
    let slot = date(2026, 9, 8, 7, 55)
    #expect(timetable.latestOccurrence(of: weekdays, through: slot) == slot)
    #expect(timetable.nextOccurrence(of: weekdays, after: slot) == date(2026, 9, 9, 7, 55))
}

@Test func timetableSkipsNonexistentTimeAndResolvesRepeatedHourOnce() {
    let overnight = schedule(hour: 1, minute: 30, clients: [.codex])
    // 2026-03-29 01:30 does not exist in London; the schedule skips that day.
    #expect(timetable.nextOccurrence(of: overnight, after: date(2026, 3, 28, 12, 0)) == date(2026, 3, 30, 1, 30))
    // 2026-10-25 01:30 happens twice; the first, still-BST instant is the single occurrence.
    var utc = london
    utc.timeZone = TimeZone(identifier: "UTC")!
    let repeated = timetable.nextOccurrence(of: overnight, after: date(2026, 10, 24, 12, 0))
    #expect(repeated == date(2026, 10, 25, 0, 30, in: utc))
    #expect(timetable.nextOccurrence(of: overnight, after: repeated!) == date(2026, 10, 26, 1, 30))
}

@Test func timetableFollowsTheTimeZone() {
    var tokyo = london
    tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    var utc = london
    utc.timeZone = TimeZone(identifier: "UTC")!
    let morning = schedule(hour: 8, clients: [.glm])
    let start = date(2026, 9, 7, 0, 0, in: utc)
    #expect(timetable.nextOccurrence(of: morning, after: start) == date(2026, 9, 7, 8, 0))
    #expect(WarmUpTimetable(calendar: tokyo).nextOccurrence(of: morning, after: start)
        == date(2026, 9, 8, 8, 0, in: tokyo))
}

@Test func inactiveSchedulesNeverOccur() {
    var disabled = schedule(hour: 8, clients: [.claude])
    disabled.enabled = false
    let now = date(2026, 9, 7, 0, 0)
    #expect(timetable.nextOccurrence(of: disabled, after: now) == nil)
    #expect(timetable.nextOccurrence(of: schedule(hour: 8, weekdays: [], clients: [.claude]), after: now) == nil)
    #expect(timetable.nextOccurrence(of: schedule(hour: 8, clients: []), after: now) == nil)
    #expect(timetable.nextRun(for: .claude, in: configuration(disabled), after: now) == nil)
}

// MARK: - Coordinator

@MainActor
private final class TestClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private actor ControlledExecutor {
    private(set) var calls: [WarmUpClient] = []
    private var continuations: [WarmUpClient: CheckedContinuation<WarmUpReport, Never>] = [:]
    func run(_ client: WarmUpClient) async -> WarmUpReport {
        calls.append(client)
        return await withCheckedContinuation { continuations[client] = $0 }
    }
    func finish(_ client: WarmUpClient, report: WarmUpReport = WarmUpReport(outcome: .succeeded)) {
        continuations.removeValue(forKey: client)?.resume(returning: report)
    }
}

@MainActor
private func settle(_ condition: () async -> Bool) async {
    for _ in 0..<1000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Coordinator did not settle")
}

@MainActor
private func coordinator(_ configuration: WarmUpConfiguration, state: WarmUpState = WarmUpState(),
                         clock: TestClock, persist: @escaping @MainActor (WarmUpState) -> Void = { _ in },
                         window: @escaping WarmUpCoordinator.Window = { _ in nil },
                         execute: @escaping WarmUpCoordinator.Execute) -> WarmUpCoordinator {
    WarmUpCoordinator(configuration: configuration, state: state, timetable: timetable,
                      now: { clock.date }, persist: persist, execute: execute, window: window)
}

@MainActor
@Test func scheduledOccurrenceRunsOnceAndRestartDoesNotRepeatIt() async {
    let config = configuration(schedule(hour: 8, weekdays: [2, 3, 4, 5, 6], clients: [.claude]))
    let clock = TestClock(date(2026, 9, 7, 7, 59))
    let executor = ControlledExecutor()
    var saved = WarmUpState()
    let scheduler = coordinator(config, clock: clock, persist: { saved = $0 },
                                execute: { client, _ in await executor.run(client) })
    defer { scheduler.stop() }
    scheduler.evaluate()
    #expect(await executor.calls.isEmpty)
    #expect(scheduler.nextRun(for: .claude) == date(2026, 9, 7, 8, 0))

    clock.date = date(2026, 9, 7, 8, 0)
    scheduler.evaluate()
    await settle { await executor.calls == [.claude] }
    #expect(scheduler.state.latestRun(for: .claude)?.scheduledAt == date(2026, 9, 7, 8, 0))
    await executor.finish(.claude, report: WarmUpReport(outcome: .succeeded, model: "claude-opus-5",
                                                        detail: "exit 0", tokens: 42))
    await settle { scheduler.state.latestRun(for: .claude)?.outcome == .succeeded }
    #expect(scheduler.state.latestRun(for: .claude)?.tokens == 42)
    clock.date = date(2026, 9, 7, 8, 1)
    scheduler.evaluate()
    #expect(await executor.calls.count == 1)

    let restarted = coordinator(config, state: saved, clock: TestClock(date(2026, 9, 7, 8, 5)),
                                execute: { _, _ in
                                    Issue.record("A claimed occurrence ran again after restart")
                                    return WarmUpReport(outcome: .succeeded)
                                })
    defer { restarted.stop() }
    restarted.evaluate()
}

@MainActor
@Test func aLateTimerStillRunsButAMissedOccurrenceIsDropped() async {
    let config = configuration(schedule(hour: 8, clients: [.codex]))
    let executor = ControlledExecutor()
    var state = WarmUpState()
    state.handled["codex"] = date(2026, 9, 6, 8, 0)

    // A timer firing a moment late still belongs to its occurrence.
    let jitter = coordinator(config, state: state,
                             clock: TestClock(date(2026, 9, 7, 8, 0).addingTimeInterval(30)),
                             execute: { client, _ in await executor.run(client) })
    defer { jitter.stop() }
    jitter.evaluate()
    await settle { await executor.calls == [.codex] }
    await executor.finish(.codex)
    await settle { jitter.state.latestRun(for: .codex)?.outcome == .succeeded }

    // Asleep at 08:00, awake at 08:10: the occurrence is gone, never replayed as a backlog.
    let woke = coordinator(config, state: state, clock: TestClock(date(2026, 9, 7, 8, 10)),
                           execute: { _, _ in
                               Issue.record("A missed occurrence must not run afterwards")
                               return WarmUpReport(outcome: .succeeded)
                           })
    defer { woke.stop() }
    woke.evaluate()
    #expect(woke.state.latestRun(for: .codex)?.outcome == .skipped("Missed"))
    #expect(woke.state.handled["codex"] == date(2026, 9, 7, 8, 0))
    woke.evaluate()
    #expect(woke.state.runs.count == 1)
}

@MainActor
@Test func oneScheduleFiresEverySelectedClientIndependently() async {
    let config = configuration(schedule(hour: 8, clients: [.claude, .codex, .glm]))
    let clock = TestClock(date(2026, 9, 7, 7, 59))
    let executor = ControlledExecutor()
    let scheduler = coordinator(config, clock: clock, execute: { client, _ in await executor.run(client) })
    defer { scheduler.stop() }
    scheduler.evaluate()
    clock.date = date(2026, 9, 7, 8, 0)
    scheduler.evaluate()
    await settle { await executor.calls.count == 3 }
    await executor.finish(.claude)
    await executor.finish(.codex, report: .failed("HTTP 500"))
    await settle { scheduler.state.latestRun(for: .codex)?.outcome == .failed("HTTP 500") }
    #expect(scheduler.state.latestRun(for: .glm)?.isRunning == true)
    await executor.finish(.glm)
    await settle { scheduler.state.latestRun(for: .glm)?.outcome == .succeeded }
}

@MainActor
@Test func manualRunsDoNotDisturbTheTimetableAndNeverRepeatARequest() async {
    let config = configuration(schedule(hour: 8, clients: [.glm]))
    let clock = TestClock(date(2026, 9, 7, 12, 0))
    let executor = ControlledExecutor()
    let scheduler = coordinator(config, clock: clock, execute: { client, _ in await executor.run(client) })
    defer { scheduler.stop() }
    scheduler.evaluate()
    let request = UUID()
    scheduler.runNow(.glm, requestID: request)
    scheduler.runNow(.glm)
    await settle { await executor.calls == [.glm] }
    #expect(scheduler.state.latestRun(for: .glm)?.isAutomatic == false)
    #expect(scheduler.nextRun(for: .glm) == date(2026, 9, 8, 8, 0))
    await executor.finish(.glm)
    await settle { scheduler.state.latestRun(for: .glm)?.outcome == .succeeded }
    scheduler.runNow(.glm, requestID: request)
    #expect(await executor.calls.count == 1)
}

@MainActor
@Test func anOccurrenceArrivingDuringARunIsAbsorbed() async {
    let config = configuration(schedule(hour: 8, clients: [.codex]), schedule(hour: 8, minute: 1, clients: [.codex]))
    let clock = TestClock(date(2026, 9, 7, 7, 59))
    let executor = ControlledExecutor()
    let scheduler = coordinator(config, clock: clock, execute: { client, _ in await executor.run(client) })
    defer { scheduler.stop() }
    scheduler.evaluate()
    clock.date = date(2026, 9, 7, 8, 0)
    scheduler.evaluate()
    await settle { await executor.calls == [.codex] }
    clock.date = date(2026, 9, 7, 8, 1)
    scheduler.evaluate()
    #expect(scheduler.state.runs.count == 1)
    #expect(scheduler.state.handled["codex"] == date(2026, 9, 7, 8, 1))
    #expect(await executor.calls.count == 1)
    await executor.finish(.codex)
    await settle { scheduler.state.latestRun(for: .codex)?.outcome == .succeeded }
}

@MainActor
@Test func disablingAScheduleCancelsItsAutomaticRunAndClearsTheTimetable() async {
    var config = configuration(schedule(hour: 8, clients: [.codex]))
    let clock = TestClock(date(2026, 9, 7, 7, 59))
    let executor = ControlledExecutor()
    let scheduler = coordinator(config, clock: clock, execute: { client, _ in await executor.run(client) })
    defer { scheduler.stop() }
    scheduler.evaluate()
    clock.date = date(2026, 9, 7, 8, 0)
    scheduler.evaluate()
    await settle { await executor.calls == [.codex] }
    config.schedules[0].enabled = false
    scheduler.updateConfiguration(config)
    #expect(scheduler.nextRun(for: .codex) == nil)
    #expect(scheduler.state.latestRun(for: .codex)?.outcome == .cancelled)
    #expect(await executor.calls.count == 1)
    await executor.finish(.codex)
}

@MainActor
@Test func aNewScheduleNeverFiresForOccurrencesItWasNotWatching() async {
    let clock = TestClock(date(2026, 9, 7, 14, 0))
    let scheduler = coordinator(WarmUpConfiguration(), clock: clock, execute: { _, _ in
        Issue.record("A schedule added after an occurrence must not fire for it")
        return WarmUpReport(outcome: .succeeded)
    })
    defer { scheduler.stop() }
    scheduler.updateConfiguration(configuration(schedule(hour: 8, clients: [.claude])))
    #expect(scheduler.state.runs.isEmpty)
    #expect(scheduler.nextRun(for: .claude) == date(2026, 9, 8, 8, 0))
}

@MainActor
@Test func restartMarksAnUnfinishedRunAsInterrupted() {
    var state = WarmUpState()
    state.record(WarmUpRun(client: .claude, startedAt: date(2026, 9, 7, 8, 0)))
    let scheduler = coordinator(WarmUpConfiguration(), state: state,
                                clock: TestClock(date(2026, 9, 7, 8, 30)),
                                execute: { _, _ in WarmUpReport(outcome: .succeeded) })
    defer { scheduler.stop() }
    #expect(scheduler.state.latestRun(for: .claude)?.outcome == .failed("Interrupted"))
    #expect(scheduler.state.latestRun(for: .claude)?.finishedAt == date(2026, 9, 7, 8, 30))
}

// MARK: - State and configuration

@Test func historyKeepsTheNewestRunsWithinTheLimit() {
    var state = WarmUpState()
    for index in 0..<(WarmUpState.historyLimit + 10) {
        state.record(WarmUpRun(client: .glm, startedAt: Date(timeIntervalSince1970: Double(index))))
    }
    #expect(state.runs.count == WarmUpState.historyLimit)
    #expect(state.runs.first?.startedAt == Date(timeIntervalSince1970: Double(WarmUpState.historyLimit + 9)))
    var latest = state.runs[0]
    latest.outcome = .succeeded
    state.record(latest)
    #expect(state.runs.count == WarmUpState.historyLimit)
    #expect(state.latestRun(for: .glm)?.outcome == .succeeded)
}

@Test func configurationRoundTripAndDefaults() throws {
    var config = WarmUpConfiguration()
    #expect(config.schedules.isEmpty)
    #expect(WarmUpClient.allCases.allSatisfy { config.schedules(for: $0).isEmpty })
    config = configuration(schedule(hour: 13, weekdays: [2, 3, 4, 5, 6], clients: [.codex, .glm]))
    config[.codex].executablePath = "/usr/local/bin/codex"
    #expect(config.schedules(for: .claude).isEmpty)
    #expect(config.schedules(for: .glm).count == 1)
    let encoded = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(WarmUpConfiguration.self, from: encoded) == config)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("apiKey"))
    #expect(config.schedules[0].weekdaysTitle == "Weekdays")
    #expect(config.schedules[0].timeTitle == "13:00")
    #expect(config.schedules[0].clientsTitle == "Codex, GLM 5.3")
}

// MARK: - Executors

private func withFakeCLI(_ script: String, operation: (String) async throws -> Void) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("fake cli")
    try Data(("#!/bin/sh\n" + script).utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    try await operation(executable.path)
}

private func cliConfiguration(_ client: WarmUpClient, path: String) -> WarmUpClientConfiguration {
    var configuration = WarmUpClientConfiguration(client: client)
    configuration.executablePath = path
    return configuration
}

@Test func cliReportsMissingBinaryAndExitFailure() async throws {
    #expect(await CLIWarmUpExecutor().run(.codex, configuration: cliConfiguration(.codex, path: "/not/a/real/cli"))
        .outcome == .failed("CLI not found"))
    try await withFakeCLI("exit 23\n") { path in
        let report = await CLIWarmUpExecutor().run(.codex, configuration: cliConfiguration(.codex, path: path))
        #expect(report.outcome == .failed("CLI exit 23"))
        #expect(report.detail == "exit 23")
    }
}

@Test func successNeedsACompletedModelTurnNotAnExitCode() async throws {
    try await withFakeCLI("exit 0\n") { path in
        let report = await CLIWarmUpExecutor().run(.codex, configuration: cliConfiguration(.codex, path: path))
        #expect(report.outcome == .failed("No completion"))
        #expect(report.detail == "exit 0")
    }
    try await withFakeCLI("""
    printf '%s\\n' '{"type":"turn.started"}'
    printf '%s\\n' '{"type":"turn.failed","error":{"message":"quota"}}'
    """) { path in
        #expect(await CLIWarmUpExecutor().run(.codex, configuration: cliConfiguration(.codex, path: path))
            .outcome == .failed("No completion"))
    }
    try await withFakeCLI("""
    printf '%s\\n' 'Reading additional input from stdin...'
    printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}'
    printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
    """) { path in
        var configuration = cliConfiguration(.codex, path: path)
        configuration.model = "gpt-5.3-codex"
        let report = await CLIWarmUpExecutor().run(.codex, configuration: configuration)
        #expect(report.outcome == .succeeded)
        #expect(report.tokens == 15)
        #expect(report.model == "gpt-5.3-codex")
        #expect(report.detail == "exit 0")
    }
}

@Test func claudeReportsItsAnsweringModelAndRejectsApplicationErrors() async throws {
    try await withFakeCLI("printf '%s' '{\"type\":\"result\",\"is_error\":true}'\n") { path in
        #expect(await CLIWarmUpExecutor().run(.claude, configuration: cliConfiguration(.claude, path: path))
            .outcome == .failed("No completion"))
    }
    try await withFakeCLI("printf '%s' '{\"type\":\"result\",\"is_error\":false,\"result\":\"\"}'\n") { path in
        #expect(await CLIWarmUpExecutor().run(.claude, configuration: cliConfiguration(.claude, path: path))
            .outcome == .failed("No completion"))
    }
    let success = """
    {"type":"result","is_error":false,"result":"OK","usage":{"input_tokens":2,"output_tokens":4},\
    "modelUsage":{"claude-haiku-4-5":{"costUSD":0.0009},"claude-opus-5":{"costUSD":0.0064}}}
    """
    try await withFakeCLI("printf '%s' '\(success)'\n") { path in
        let report = await CLIWarmUpExecutor().run(.claude, configuration: cliConfiguration(.claude, path: path))
        #expect(report.outcome == .succeeded)
        #expect(report.model == "claude-opus-5")
        #expect(report.tokens == 6)
    }
}

@Test func cliTimeoutAndCancellationTerminateChild() async throws {
    try await withFakeCLI("exec /bin/sleep 30\n") { path in
        let configuration = cliConfiguration(.codex, path: path)
        let start = Date()
        #expect(await CLIWarmUpExecutor(timeout: 0.1).run(.codex, configuration: configuration)
            .outcome == .failed("Timed out"))
        let task = Task { await CLIWarmUpExecutor().run(.codex, configuration: configuration) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value.outcome == .cancelled)
        #expect(Date().timeIntervalSince(start) < 3)
    }
}

@Test func cliUsesIsolatedDirectoryAndLiteralArguments() async throws {
    let script = """
    case "$PWD" in *llmusage-warmup-*) ;; *) exit 4;; esac
    for arg do
     if [ "$arg" = '$(exit 99) model' ]; then
      printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}'
      printf '%s\\n' '{"type":"turn.completed"}'
      exit 0
     fi
    done
    exit 5
    """
    try await withFakeCLI(script) { path in
        var configuration = cliConfiguration(.codex, path: path)
        configuration.model = "$(exit 99) model"
        #expect(await CLIWarmUpExecutor().run(.codex, configuration: configuration).outcome == .succeeded)
    }
}

private final class WarmUpURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let status = key == "Bearer reject" ? 401 : 200
        let body = key == "Bearer malformed"
            ? "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"\"}}]}"
            : "{\"model\":\"glm-5.3\",\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"OK\"}}],\"usage\":{\"total_tokens\":31}}"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func glmValidatesResponseAndMissingCredentials() async throws {
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [WarmUpURLProtocol.self]
    let session = URLSession(configuration: sessionConfiguration)
    defer { session.invalidateAndCancel() }
    let configuration = WarmUpClientConfiguration(client: .glm)
    #expect(await GLMWarmUpExecutor(session: session, loadKey: { nil }).run(configuration: configuration)
        .outcome == .failed("API key missing"))
    #expect(await GLMWarmUpExecutor(session: session, loadKey: { "reject" }).run(configuration: configuration)
        .outcome == .failed("HTTP 401"))
    #expect(await GLMWarmUpExecutor(session: session, loadKey: { "malformed" }).run(configuration: configuration)
        .outcome == .failed("No completion"))
    let report = await GLMWarmUpExecutor(session: session, loadKey: { "ok" }).run(configuration: configuration)
    #expect(report.outcome == .succeeded)
    #expect(report.model == "glm-5.3")
    #expect(report.detail == "HTTP 200")
    #expect(report.tokens == 31)
}

@Test func glmRequestUsesSelectedEndpointAndBoundedGeneration() throws {
    var configuration = WarmUpClientConfiguration(client: .glm)
    for endpoint in GLMEndpoint.allCases {
        configuration.endpoint = endpoint
        let request = try GLMWarmUpExecutor.request(configuration: configuration, key: "test-key")
        #expect(request.url == endpoint.url)
        #expect(request.httpMethod == "POST")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["model"] as? String == "glm-5.3")
        #expect(body["max_tokens"] as? Int == 64)
        #expect(body["reasoning_effort"] as? String == "low")
        #expect(body["thinking"] == nil)
    }
}

// MARK: - Open session windows

/// The window a client reports when warm up asks it, and a record of every time it was asked.
private actor WindowStub {
    private var closesAt: Date?
    private(set) var asked: [WarmUpClient] = []
    init(closesAt: Date? = nil) { self.closesAt = closesAt }
    func set(_ date: Date?) { closesAt = date }
    func window(_ client: WarmUpClient) -> Date? {
        asked.append(client)
        return closesAt
    }
}

@MainActor
@Test func aManualRunInsideAnOpenWindowReportsInsteadOfSpendingQuota() async {
    let clock = TestClock(date(2026, 9, 7, 19, 52))
    let windows = WindowStub(closesAt: date(2026, 9, 7, 19, 56))
    let scheduler = coordinator(WarmUpConfiguration(), clock: clock,
                                window: { await windows.window($0) },
                                execute: { _, _ in
        Issue.record("A request inside an open window opens nothing and must not be sent")
        return WarmUpReport(outcome: .succeeded)
    })
    defer { scheduler.stop() }
    let request = UUID()
    scheduler.runNow(.codex, requestID: request)
    await settle { scheduler.state.latestRun(for: .codex)?.isRunning == false }
    let run = scheduler.state.latestRun(for: .codex)
    #expect(run?.id == request)
    #expect(run?.outcome?.title.hasPrefix("Warm until") == true)
}

@MainActor
@Test func aManualRunProceedsOnceTheWindowHasClosed() async {
    let clock = TestClock(date(2026, 9, 7, 19, 57))
    let executor = ControlledExecutor()
    // The window named by the fetch has just expired.
    let windows = WindowStub(closesAt: date(2026, 9, 7, 19, 56))
    let scheduler = coordinator(WarmUpConfiguration(), clock: clock,
                                window: { await windows.window($0) },
                                execute: { client, _ in await executor.run(client) })
    defer { scheduler.stop() }
    scheduler.runNow(.codex)
    await settle { await executor.calls == [.codex] }
    await executor.finish(.codex)
    await settle { scheduler.state.latestRun(for: .codex)?.outcome == .succeeded }
}

@MainActor
@Test func aScheduledOccurrenceInsideAnOpenWindowIsSkipped() async {
    let config = configuration(schedule(hour: 8, clients: [.codex]))
    let clock = TestClock(date(2026, 9, 7, 7, 59))
    let windows = WindowStub(closesAt: date(2026, 9, 7, 9, 0))
    let scheduler = coordinator(config, clock: clock, window: { await windows.window($0) },
                                execute: { _, _ in
        Issue.record("A client that is already warm must not be warmed again")
        return WarmUpReport(outcome: .succeeded)
    })
    defer { scheduler.stop() }
    scheduler.evaluate()
    // Nothing is asked before the occurrence: the window is read at the firing instant.
    #expect(await windows.asked.isEmpty)

    clock.date = date(2026, 9, 7, 8, 0)
    scheduler.evaluate()
    await settle { scheduler.state.latestRun(for: .codex)?.isRunning == false }
    #expect(await windows.asked == [.codex])
    let run = scheduler.state.latestRun(for: .codex)
    #expect(run?.scheduledAt == date(2026, 9, 7, 8, 0))
    #expect(run?.outcome?.title.hasPrefix("Warm until") == true)

    // The occurrence is spent where it landed: the window closing does not revive it.
    clock.date = date(2026, 9, 7, 9, 1)
    await windows.set(nil)
    scheduler.evaluate()
    #expect(scheduler.state.runs.count == 1)
}

@MainActor
@Test func continuousUseSkipsEveryOccurrenceItCovers() async {
    let config = configuration(schedule(hour: 8, clients: [.codex]),
                               schedule(hour: 13, clients: [.codex]))
    let clock = TestClock(date(2026, 9, 7, 7, 59))
    let executor = ControlledExecutor()
    // Back-to-back windows: the client is warm across both of the day's occurrences.
    let windows = WindowStub(closesAt: date(2026, 9, 7, 13, 0))
    let scheduler = coordinator(config, clock: clock, window: { await windows.window($0) },
                                execute: { client, _ in await executor.run(client) })
    defer { scheduler.stop() }
    clock.date = date(2026, 9, 7, 8, 0)
    scheduler.evaluate()
    await settle { scheduler.state.runs.count == 1 && scheduler.state.runs[0].isRunning == false }

    clock.date = date(2026, 9, 7, 13, 0)
    await windows.set(date(2026, 9, 7, 18, 0))
    scheduler.evaluate()
    await settle { scheduler.state.runs.count == 2 && scheduler.state.runs[0].isRunning == false }
    #expect(await executor.calls.isEmpty)
    #expect(scheduler.state.runs.allSatisfy { $0.outcome?.title.hasPrefix("Warm until") == true })

    // Next morning the window is closed and that day's occurrence runs.
    clock.date = date(2026, 9, 8, 8, 0)
    await windows.set(nil)
    scheduler.evaluate()
    await settle { await executor.calls == [.codex] }
    #expect(scheduler.state.latestRun(for: .codex)?.scheduledAt == date(2026, 9, 8, 8, 0))
    await executor.finish(.codex)
    await settle { scheduler.state.latestRun(for: .codex)?.outcome == .succeeded }
}

@MainActor
@Test func aClientWithoutAReadableWindowAlwaysRuns() async {
    let config = configuration(schedule(hour: 8, clients: [.glm]))
    let clock = TestClock(date(2026, 9, 7, 7, 59))
    let executor = ControlledExecutor()
    // GLM's Coding plan reports no session window, and a failed fetch reads the same.
    let scheduler = coordinator(config, clock: clock, window: { _ in nil },
                                execute: { client, _ in await executor.run(client) })
    defer { scheduler.stop() }
    clock.date = date(2026, 9, 7, 8, 0)
    scheduler.evaluate()
    await settle { await executor.calls == [.glm] }
    await executor.finish(.glm)
    await settle { scheduler.state.latestRun(for: .glm)?.outcome == .succeeded }
}
