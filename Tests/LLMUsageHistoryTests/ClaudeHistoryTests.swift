import Foundation
import Testing
@testable import LLMUsageHistory

/// Writes a `<config>/projects/<project>/<session>.jsonl` tree the way Claude Code lays one out.
private struct ClaudeFixture {
    let configDirectory: URL
    let sessionFile: URL

    init(lines: [String], project: String = "-Users-test-proj", session: String = "s1") throws {
        configDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-fixture-\(UUID().uuidString)")
        let projects = configDirectory.appendingPathComponent("projects/\(project)")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        sessionFile = projects.appendingPathComponent("\(session).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(
            to: sessionFile,
            atomically: true, encoding: .utf8
        )
    }

    func cleanUp() { try? FileManager.default.removeItem(at: configDirectory) }

    var provider: ClaudeHistoryProvider {
        ClaudeHistoryProvider(
            environment: ["CLAUDE_CONFIG_DIR": configDirectory.path],
            homeDirectory: URL(fileURLWithPath: "/nonexistent")
        )
    }
}

@Test func partialAppendedLineIsParsedOnlyAfterItsNewlineArrives() async throws {
    let first = claudeLine(
        timestamp: stamp(1), messageID: "first", requestID: "first", input: 100
    )
    let second = claudeLine(
        timestamp: stamp(2), messageID: "second", requestID: "second", input: 200
    )
    let fixture = try ClaudeFixture(lines: [first])
    defer { fixture.cleanUp() }

    let initial = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))
    #expect(initial.requests == 1)

    let split = second.index(second.startIndex, offsetBy: second.count / 2)
    let handle = try FileHandle(forWritingTo: fixture.sessionFile)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(second[..<split].utf8))
    try handle.close()

    let partial = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))
    #expect(partial.requests == 1)

    let finish = try FileHandle(forWritingTo: fixture.sessionFile)
    try finish.seekToEnd()
    try finish.write(contentsOf: Data((second[split...] + "\n").utf8))
    try finish.close()

    let complete = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))
    #expect(complete.requests == 2)
    #expect(complete.tokens.input == 300)
}

/// Mirrors a real assistant line, including the `iterations` breakdown Claude writes inside `usage`.
private func claudeLine(
    timestamp: String,
    model: String = "claude-opus-5",
    messageID: String? = "msg_1",
    requestID: String? = "req_1",
    input: Int = 0,
    output: Int = 0,
    cacheCreation: Int = 0,
    cacheRead: Int = 0,
    thinking: Int? = nil,
    isSidechain: Bool = false,
    withIterations: Bool = true
) -> String {
    var usage = """
        "input_tokens":\(input),"output_tokens":\(output),\
        "cache_creation_input_tokens":\(cacheCreation),"cache_read_input_tokens":\(cacheRead)
        """
    if let thinking {
        usage += ",\"output_tokens_details\":{\"thinking_tokens\":\(thinking)}"
    }
    if withIterations {
        // Claude writes iterations that sum to exactly the parent usage.
        usage += """
            ,"iterations":[{"type":"message","input_tokens":\(input),"output_tokens":\(output),\
            "cache_creation_input_tokens":\(cacheCreation),"cache_read_input_tokens":\(cacheRead)}]
            """
    }
    let message = "{\"id\":\(messageID.map { "\"\($0)\"" } ?? "null"),\"model\":\"\(model)\",\"usage\":{\(usage)}}"
    let request = requestID.map { ",\"requestId\":\"\($0)\"" } ?? ""
    return "{\"timestamp\":\"\(timestamp)\",\"isSidechain\":\(isSidechain),\"message\":\(message)\(request)}"
}

private let today = DailyUsageAccumulator.dayKey(from: Date())
private func stamp(_ hour: Int) -> String {
    // Anchored to "now" so the fixture always lands inside the scan window.
    let date = Calendar.current.date(bySettingHour: 12, minute: hour, second: 0, of: Date())!
    let utc = ISO8601DateFormatter()
    utc.timeZone = TimeZone(identifier: "UTC")
    utc.formatOptions = [.withInternetDateTime]
    return utc.string(from: date)
}

// MARK: - The two things that decide whether the numbers are right

@Test func repeatedRecordsOfOneMessageCountOnce() async throws {
    // Claude Code rewrites a message's record as the turn progresses: an early snapshot with no
    // output, then the finished one. Summing the file as-is inflated the real log by 1.84x.
    let fixture = try ClaudeFixture(lines: [
        claudeLine(timestamp: stamp(1), input: 7455, output: 0),
        claudeLine(timestamp: stamp(2), input: 38596, output: 298, cacheRead: 11264),
        claudeLine(timestamp: stamp(3), input: 38596, output: 298, cacheRead: 11264)
    ])
    defer { fixture.cleanUp() }

    let history = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))

    #expect(history.requests == 1)
    #expect(history.tokens.input == 38_596)
    #expect(history.tokens.output == 298)
    #expect(history.tokens.cacheRead == 11_264)
}

@Test func iterationsAreABreakdownOfTheParentNotExtraUsage() async throws {
    // `sum(iterations) == parent usage` on every real row that carries one, so adding them would
    // double the line exactly.
    let fixture = try ClaudeFixture(lines: [
        claudeLine(timestamp: stamp(1), input: 1_000, output: 200, withIterations: true)
    ])
    defer { fixture.cleanUp() }

    let history = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))

    #expect(history.tokens.input == 1_000)
    #expect(history.tokens.output == 200)
    #expect(history.tokens.total == 1_200)
}

@Test func distinctMessagesAreAllCounted() async throws {
    let fixture = try ClaudeFixture(lines: [
        claudeLine(timestamp: stamp(1), messageID: "msg_a", requestID: "req_a", input: 100),
        claudeLine(timestamp: stamp(2), messageID: "msg_b", requestID: "req_b", input: 200),
        // Same message id, different request: a genuine retry, not a repeat of the same response.
        claudeLine(timestamp: stamp(3), messageID: "msg_a", requestID: "req_c", input: 400)
    ])
    defer { fixture.cleanUp() }

    let history = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))

    #expect(history.requests == 3)
    #expect(history.tokens.input == 700)
}

@Test func sidechainCopyLosesToTheOriginalRecord() async throws {
    let fixture = try ClaudeFixture(lines: [
        claudeLine(timestamp: stamp(1), input: 500, output: 50, isSidechain: true),
        claudeLine(timestamp: stamp(2), input: 500, output: 50, isSidechain: false)
    ])
    defer { fixture.cleanUp() }

    let history = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))

    #expect(history.requests == 1)
    #expect(history.tokens.total == 550)
}

@Test func thinkingTokensRideInsideOutputAndAreNotAddedAgain() async throws {
    let fixture = try ClaudeFixture(lines: [
        claudeLine(timestamp: stamp(1), output: 2_046, thinking: 1_638)
    ])
    defer { fixture.cleanUp() }

    let history = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))

    #expect(history.tokens.output == 2_046)
    #expect(history.tokens.reasoning == 1_638)
    #expect(history.tokens.total == 2_046)
}

@Test func linesWithoutARequestIdStillDeduplicateOnTheirMessageId() async throws {
    let fixture = try ClaudeFixture(lines: [
        claudeLine(timestamp: stamp(1), messageID: "msg_x", requestID: nil, input: 10),
        claudeLine(timestamp: stamp(2), messageID: "msg_x", requestID: nil, input: 10)
    ])
    defer { fixture.cleanUp() }

    let history = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))

    #expect(history.requests == 1)
}

@Test func usageIsAttributedToItsModel() async throws {
    let fixture = try ClaudeFixture(lines: [
        claudeLine(timestamp: stamp(1), model: "claude-opus-5", messageID: "a", requestID: "a", input: 900),
        claudeLine(timestamp: stamp(2), model: "claude-sonnet-5", messageID: "b", requestID: "b", input: 100)
    ])
    defer { fixture.cleanUp() }

    let history = try #require(try await fixture.provider.scanHistory(daysBack: 2, now: Date()))
    let byModel = Dictionary(
        uniqueKeysWithValues: history.days.flatMap { $0.models }.map { ($0.model, $0.tokens.input) }
    )

    #expect(byModel["claude-opus-5"] == 900)
    #expect(byModel["claude-sonnet-5"] == 100)
}

// MARK: - Roots

@Test func missingProjectsDirectoryMeansClaudeCodeIsNotInstalled() async throws {
    let provider = ClaudeHistoryProvider(
        environment: ["CLAUDE_CONFIG_DIR": "/nonexistent/claude"],
        homeDirectory: URL(fileURLWithPath: "/nonexistent")
    )
    #expect(try await provider.scanHistory(daysBack: 30, now: Date()) == nil)
}

@Test func configDirEnvironmentOverrideAcceptsSeveralRootsAndEitherLevel() throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("claude-roots-\(UUID().uuidString)")
    let one = base.appendingPathComponent("one/projects")
    let two = base.appendingPathComponent("two/projects")
    try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    // First entry names the config dir, second names the `projects/` dir directly.
    let provider = ClaudeHistoryProvider(
        environment: ["CLAUDE_CONFIG_DIR": "\(base.path)/one, \(two.path)"],
        homeDirectory: URL(fileURLWithPath: "/nonexistent")
    )

    #expect(provider.projectDirectories() == [one.path, two.path])
}
