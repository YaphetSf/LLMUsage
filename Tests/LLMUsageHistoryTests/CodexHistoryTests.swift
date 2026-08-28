import Foundation
import Testing
@testable import LLMUsageHistory

/// Writes a `<home>/sessions/<yyyy>/<mm>/<dd>/rollout-*.jsonl` tree the way Codex lays one out.
private struct CodexFixture {
    let home: URL
    let sessionFiles: [URL]

    init(sessions: [[String]]) throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-fixture-\(UUID().uuidString)")
        let directory = home.appendingPathComponent("sessions/2026/08/27")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [URL] = []
        for (index, lines) in sessions.enumerated() {
            let file = directory.appendingPathComponent("rollout-\(index).jsonl")
            try (lines.joined(separator: "\n") + "\n").write(
                to: file,
                atomically: true, encoding: .utf8
            )
            files.append(file)
        }
        sessionFiles = files
    }

    func cleanUp() { try? FileManager.default.removeItem(at: home) }

    var provider: CodexHistoryProvider {
        CodexHistoryProvider(
            environment: ["CODEX_HOME": home.path],
            homeDirectory: URL(fileURLWithPath: "/nonexistent")
        )
    }
}

@Test func appendedTurnsReuseThePersistedModelCheckpoint() async throws {
    let fixture = try CodexFixture(sessions: [[
        turnContext("gpt-5.6-sol", at: stamp(0)),
        tokenCount(at: stamp(1), input: 100, output: 10, cumulative: 110)
    ]])
    defer { fixture.cleanUp() }

    _ = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))

    let handle = try FileHandle(forWritingTo: fixture.sessionFiles[0])
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(
        (tokenCount(at: stamp(2), input: 200, output: 20, cumulative: 330) + "\n").utf8
    ))
    try handle.close()

    let history = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))
    let models = Set(history.days.flatMap { $0.models.map(\.model) })
    #expect(models == ["gpt-5.6-sol"])
    #expect(history.requests == 2)
}

private func turnContext(_ model: String, at timestamp: String) -> String {
    "{\"timestamp\":\"\(timestamp)\",\"type\":\"turn_context\",\"payload\":{\"model\":\"\(model)\"}}"
}

/// A `token_count` event. `input` is the value Codex writes, which already includes `cached`.
private func tokenCount(
    at timestamp: String,
    input: Int,
    cached: Int = 0,
    output: Int = 0,
    reasoning: Int = 0,
    cumulative: Int
) -> String {
    """
    {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{\
    "last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),\
    "output_tokens":\(output),"reasoning_output_tokens":\(reasoning),\
    "cache_write_input_tokens":0,"total_tokens":\(input + output)},\
    "total_token_usage":{"total_tokens":\(cumulative)}}}}
    """
}

private func stamp(_ minute: Int) -> String {
    let date = Calendar.current.date(bySettingHour: 12, minute: minute, second: 0, of: Date())!
    let utc = ISO8601DateFormatter()
    utc.timeZone = TimeZone(identifier: "UTC")
    utc.formatOptions = [.withInternetDateTime]
    return utc.string(from: date)
}

// MARK: - The two things that decide whether the numbers are right

@Test func cachedInputIsSubtractedBecauseCodexReportsItInsideInput() async throws {
    // On the real log the cache is 95% of all input, so treating `input_tokens` as fresh input
    // would roughly double the whole provider.
    let fixture = try CodexFixture(sessions: [[
        turnContext("gpt-5.6", at: stamp(0)),
        tokenCount(at: stamp(1), input: 195_103, cached: 190_208, output: 342, reasoning: 186, cumulative: 195_445)
    ]])
    defer { fixture.cleanUp() }

    let history = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))
    let tokens = history.tokens

    #expect(tokens.input == 4_895)          // 195,103 - 190,208
    #expect(tokens.cacheRead == 190_208)
    #expect(tokens.output == 342)
    #expect(tokens.reasoning == 186)        // inside output, not added again
    #expect(tokens.total == 195_445)        // matches Codex's own total_tokens
}

@Test func forkedSessionsReplayingParentTurnsCountOnce() async throws {
    // A fork rewrites every replayed event's timestamp to the fork instant, so nothing keyed on
    // time can separate them — but the token values and the cumulative total are copied verbatim.
    let parent = [
        turnContext("gpt-5.6", at: stamp(0)),
        tokenCount(at: stamp(1), input: 195_103, cached: 190_208, output: 342, cumulative: 4_650_305),
        tokenCount(at: stamp(2), input: 195_490, cached: 194_304, output: 7_801, cumulative: 4_853_596)
    ]
    let child = [
        turnContext("gpt-5.6", at: stamp(9)),
        // Replayed with the fork's timestamp, identical values.
        tokenCount(at: stamp(9), input: 195_103, cached: 190_208, output: 342, cumulative: 4_650_305),
        tokenCount(at: stamp(9), input: 195_490, cached: 194_304, output: 7_801, cumulative: 4_853_596),
        // A genuinely new turn after the fork.
        tokenCount(at: stamp(10), input: 1_000, cached: 0, output: 50, cumulative: 4_854_646)
    ]
    let fixture = try CodexFixture(sessions: [parent, child])
    defer { fixture.cleanUp() }

    let history = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))

    #expect(history.requests == 3)          // two parent turns + one real child turn
    #expect(history.tokens.output == 8_193) // 342 + 7,801 + 50
}

@Test func reEmittedSnapshotAtAnUnchangedCumulativeTotalIsNotNewUsage() async throws {
    let fixture = try CodexFixture(sessions: [[
        turnContext("gpt-5.6", at: stamp(0)),
        tokenCount(at: stamp(1), input: 500, output: 20, cumulative: 1_000),
        tokenCount(at: stamp(2), input: 500, output: 20, cumulative: 1_000)
    ]])
    defer { fixture.cleanUp() }

    let history = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))

    #expect(history.requests == 1)
    #expect(history.tokens.output == 20)
}

@Test func identicalTurnsAtDifferentCumulativeTotalsAreBothRealUsage() async throws {
    // Two turns can legitimately cost the same; the advancing cumulative total is what says they
    // are distinct, and it is what keeps the dedup from swallowing real work.
    let fixture = try CodexFixture(sessions: [[
        turnContext("gpt-5.6", at: stamp(0)),
        tokenCount(at: stamp(1), input: 500, output: 20, cumulative: 1_000),
        tokenCount(at: stamp(2), input: 500, output: 20, cumulative: 1_520)
    ]])
    defer { fixture.cleanUp() }

    let history = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))

    #expect(history.requests == 2)
    #expect(history.tokens.output == 40)
}

@Test func turnContextSetsTheModelForEveryFollowingTurn() async throws {
    let fixture = try CodexFixture(sessions: [[
        turnContext("gpt-5.5", at: stamp(0)),
        tokenCount(at: stamp(1), input: 100, output: 10, cumulative: 110),
        turnContext("gpt-5.6-sol", at: stamp(2)),
        tokenCount(at: stamp(3), input: 200, output: 20, cumulative: 330)
    ]])
    defer { fixture.cleanUp() }

    let history = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))
    let byModel = Dictionary(
        uniqueKeysWithValues: history.days.flatMap { $0.models }.map { ($0.model, $0.tokens.output) }
    )

    #expect(byModel["gpt-5.5"] == 10)
    #expect(byModel["gpt-5.6-sol"] == 20)
}

@Test func turnsBeforeAnyTurnContextAreStillCounted() async throws {
    // Early sessions have no model metadata. Their tokens are real and must not be dropped just
    // because they cannot be attributed.
    let fixture = try CodexFixture(sessions: [[
        tokenCount(at: stamp(1), input: 100, output: 10, cumulative: 110)
    ]])
    defer { fixture.cleanUp() }

    let history = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))

    #expect(history.tokens.output == 10)
    #expect(history.days.first?.models.first?.model == "unknown")
}

@Test func archivedSessionsAreScannedAlongsideLiveOnes() async throws {
    let fixture = try CodexFixture(sessions: [[
        turnContext("gpt-5.6", at: stamp(0)),
        tokenCount(at: stamp(1), input: 100, output: 10, cumulative: 110)
    ]])
    defer { fixture.cleanUp() }

    let archived = fixture.home.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    try (tokenCount(at: stamp(2), input: 300, output: 30, cumulative: 440) + "\n")
        .write(to: archived.appendingPathComponent("old.jsonl"), atomically: true, encoding: .utf8)

    let history = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))

    #expect(history.tokens.output == 40)
    #expect(fixture.provider.sessionDirectories().count == 2)
}

@Test func missingSessionsDirectoryMeansCodexIsNotInstalled() async throws {
    let provider = CodexHistoryProvider(
        environment: ["CODEX_HOME": "/nonexistent/codex"],
        homeDirectory: URL(fileURLWithPath: "/nonexistent")
    )
    #expect(try await provider.scanHistory(daysBack: 30, now: Date()) == nil)
}

// MARK: - Shared plumbing

@Test func logTimestampsParseWithoutAFormatter() {
    let parsed = try! #require(JSONLScanning.timestamp("2026-08-27T17:36:27.175Z"))
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed)

    #expect(parts.year == 2026 && parts.month == 8 && parts.day == 27)
    #expect(parts.hour == 17 && parts.minute == 36 && parts.second == 27)
    #expect(JSONLScanning.timestamp("nonsense") == nil)
    #expect(JSONLScanning.timestamp("") == nil)
}

@Test func commaSeparatedRootOverridesDropBlanksAndFallBackWhenEmpty() {
    #expect(JSONLScanning.roots(environmentValue: "/a, /b ", defaults: ["/fallback"]) == ["/a", "/b"])
    #expect(JSONLScanning.roots(environmentValue: " , ", defaults: ["/fallback"]) == ["/fallback"])
    #expect(JSONLScanning.roots(environmentValue: nil, defaults: ["/fallback"]) == ["/fallback"])
}
