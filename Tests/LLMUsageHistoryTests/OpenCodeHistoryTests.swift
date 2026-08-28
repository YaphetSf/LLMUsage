import Foundation
import Testing
@testable import LLMUsageHistory

/// Builds a throwaway database with OpenCode's real shape: a `message` table of `(id, time_created,
/// data)` where `data` is the JSON blob. Written through the `sqlite3` CLI so the tests exercise the
/// production SQL — the aggregation, the JSON extraction and the local-day bucketing are where the
/// bugs live, and a hand-rolled Swift fixture would test none of them.
private struct OpenCodeFixture {
    let directory: URL
    var databasePath: String { directory.appendingPathComponent("opencode.db").path }

    init(rows: [Row]) throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var sql = "CREATE TABLE message (id TEXT PRIMARY KEY, time_created INTEGER, data TEXT);\n"
        for (index, row) in rows.enumerated() {
            sql += "INSERT INTO message VALUES ('m\(index)', \(row.timeCreatedMilliseconds), '\(row.json)');\n"
        }
        try Self.run(sql: sql, at: databasePath)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    struct Row {
        var timeCreatedMilliseconds: Int64
        var json: String

        /// Mirrors the blob OpenCode writes, including `reasoning` as a sibling of `output`.
        static func assistant(
            at date: Date,
            provider: String,
            model: String,
            input: Int = 0,
            output: Int = 0,
            reasoning: Int = 0,
            cacheRead: Int = 0,
            cacheWrite: Int = 0
        ) -> Row {
            let total = input + output + reasoning + cacheRead + cacheWrite
            let json = """
                {"role":"assistant","providerID":"\(provider)","modelID":"\(model)",\
                "tokens":{"total":\(total),"input":\(input),"output":\(output),"reasoning":\(reasoning),\
                "cache":{"read":\(cacheRead),"write":\(cacheWrite)}}}
                """
            return Row(timeCreatedMilliseconds: Int64(date.timeIntervalSince1970 * 1000), json: json)
        }

        static func user(at date: Date) -> Row {
            Row(
                timeCreatedMilliseconds: Int64(date.timeIntervalSince1970 * 1000),
                json: #"{"role":"user","providerID":"minimax","modelID":"MiniMax-M3"}"#
            )
        }
    }

    private static func run(sql: String, at path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(sql.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
    }
}

private func scan(
    _ fixture: OpenCodeFixture,
    daysBack: Int = 30,
    now: Date
) async throws -> UsageHistory? {
    let path = fixture.databasePath
    let provider = OpenCodeHistoryProvider(databasePaths: { [path] })
    return try await provider.scanHistory(daysBack: daysBack, now: now)
}

private let noon = Date(timeIntervalSince1970: 1_780_000_000)

// MARK: - The bug this provider exists to fix

@Test func countsBringYourOwnKeyProvidersNotJustOpenCodeHostedOnes() async throws {
    let fixture = try OpenCodeFixture(rows: [
        .assistant(at: noon, provider: "vectide", model: "glm-5.3", input: 1_000, output: 200),
        .assistant(at: noon, provider: "deepseek", model: "deepseek-v4-pro", input: 500, output: 100),
        .assistant(at: noon, provider: "opencode", model: "zen-model", input: 10, output: 5)
    ])
    defer { fixture.cleanUp() }

    let history = try #require(try await scan(fixture, now: noon))
    let models = Set(history.days.flatMap { $0.models.map(\.model) })

    // Filtering to OpenCode's own gateways — what the upstream scanner does — would drop the first
    // two rows entirely, reporting nothing at all for a user who brings their own API keys.
    #expect(models == ["vectide/glm-5.3", "deepseek/deepseek-v4-pro", "opencode/zen-model"])
    #expect(history.tokens.total == 1_815)
}

@Test func foldsReasoningIntoOutputSoTotalsMatchOpenCodesOwnArithmetic() async throws {
    // Taken from a real row shape: reasoning exceeds output, which is only possible because
    // OpenCode reports them as siblings.
    let fixture = try OpenCodeFixture(rows: [
        .assistant(
            at: noon, provider: "deepseek", model: "deepseek-v4-pro",
            input: 40_873, output: 65, reasoning: 185
        )
    ])
    defer { fixture.cleanUp() }

    let history = try #require(try await scan(fixture, now: noon))
    let tokens = history.tokens

    #expect(tokens.output == 250)      // 65 emitted + 185 reasoning
    #expect(tokens.reasoning == 185)   // still reported separately for display
    #expect(tokens.total == 41_123)    // equals OpenCode's own `tokens.total`
}

// MARK: - Windowing and filtering

@Test func onlyAssistantRowsInsideTheWindowAreCounted() async throws {
    let calendar = Calendar.current
    let old = calendar.date(byAdding: .day, value: -40, to: noon)!
    let recent = calendar.date(byAdding: .day, value: -2, to: noon)!
    let fixture = try OpenCodeFixture(rows: [
        .assistant(at: old, provider: "glm", model: "glm-5.3", input: 111),
        .assistant(at: recent, provider: "glm", model: "glm-5.3", input: 222),
        .user(at: recent)
    ])
    defer { fixture.cleanUp() }

    let history = try #require(try await scan(fixture, daysBack: 30, now: noon))

    #expect(history.tokens.input == 222)
    #expect(history.days.count == 1)
    #expect(history.days.first?.requests == 1)
}

@Test func daysAreBucketedInLocalTimeAndReturnedAscending() async throws {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: noon).addingTimeInterval(12 * 3_600)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
    // 23:30 local — a UTC-based bucket would push this onto the following day for most of the
    // Americas, showing usage on a day the user was asleep.
    let lateYesterday = calendar.startOfDay(for: yesterday).addingTimeInterval(23 * 3_600 + 1_800)

    let fixture = try OpenCodeFixture(rows: [
        .assistant(at: today, provider: "glm", model: "glm-5.3", input: 1),
        .assistant(at: lateYesterday, provider: "glm", model: "glm-5.3", input: 2)
    ])
    defer { fixture.cleanUp() }

    let history = try #require(try await scan(fixture, now: noon))

    #expect(history.days.count == 2)
    #expect(history.days.map(\.day) == [
        DailyUsageAccumulator.dayKey(from: yesterday),
        DailyUsageAccumulator.dayKey(from: today)
    ])
    #expect(history.days.first?.tokens.input == 2)
}

@Test func missingDatabaseMeansNotInstalledRatherThanEmpty() async throws {
    let provider = OpenCodeHistoryProvider(databasePaths: { [] })
    #expect(try await provider.scanHistory(daysBack: 30, now: noon) == nil)
}

@Test func presentButEmptyDatabaseYieldsAnEmptyHistory() async throws {
    let fixture = try OpenCodeFixture(rows: [])
    defer { fixture.cleanUp() }

    let history = try #require(try await scan(fixture, now: noon))
    #expect(history.days.isEmpty)
    #expect(history.tokens.total == 0)
}

@Test func unreadableDatabaseThrowsRatherThanReportingZeroUsage() async throws {
    let provider = OpenCodeHistoryProvider(databasePaths: { ["/nonexistent/opencode.db"] })
    await #expect(throws: UsageHistoryError.self) {
        _ = try await provider.scanHistory(daysBack: 30, now: noon)
    }
}

// MARK: - Paths

@Test func dataDirectoryFollowsOpenCodesOwnResolutionOrder() {
    let home = URL(fileURLWithPath: "/Users/test")

    #expect(OpenCodePaths.dataDirectory(
        environment: ["OPENCODE_DATA_DIR": "~/custom/"], homeDirectory: home
    ) == "/Users/test/custom")

    #expect(OpenCodePaths.dataDirectory(
        environment: ["XDG_DATA_HOME": "/xdg"], homeDirectory: home
    ) == "/xdg/opencode")

    #expect(OpenCodePaths.dataDirectory(
        environment: [:], homeDirectory: home
    ) == "/Users/test/.local/share/opencode")

    // An explicit override outranks XDG.
    #expect(OpenCodePaths.dataDirectory(
        environment: ["OPENCODE_DATA_DIR": "/explicit", "XDG_DATA_HOME": "/xdg"], homeDirectory: home
    ) == "/explicit")
}

@Test func databaseGlobCoversEveryReleaseChannelAndSkipsSidecars() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("opencode-paths-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    for name in ["opencode.db", "opencode-next.db", "opencode.db-wal", "opencode.db-shm", "other.db"] {
        FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data())
    }

    let found = try OpenCodePaths.databaseFiles(in: directory.path).map { ($0 as NSString).lastPathComponent }
    #expect(found == ["opencode-next.db", "opencode.db"])
}

@Test func missingDataDirectoryIsAbsenceNotFailure() throws {
    #expect(try OpenCodePaths.databaseFiles(in: "/nonexistent/opencode").isEmpty)
}
