import Foundation
import Testing
@testable import LLMUsageHistory

/// Builds a throwaway database with ZCode's real `model_usage` shape. Written through the
/// `sqlite3` CLI so the tests exercise the production SQL — the cache split, the status filter
/// and the local-day bucketing are where the bugs live.
private struct ZCodeFixture {
    let directory: URL
    var databasePath: String { directory.appendingPathComponent("db.sqlite").path }

    /// `wal` leaves the database in WAL journal mode with no sidecars — the state ZCode's file is
    /// in while the app is closed. This build of the `sqlite3` CLI leaves a checkpointed, empty
    /// `-wal`/`-shm` behind on exit instead of deleting them, so the fixture removes them itself.
    init(rows: [Row], wal: Bool = false) throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zcode-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var sql = wal ? "PRAGMA journal_mode=WAL;\n" : ""
        sql += """
            CREATE TABLE model_usage (
              id TEXT PRIMARY KEY, logical_request_id TEXT, attempt_index INTEGER DEFAULT 0,
              provider_id TEXT NOT NULL, model_id TEXT NOT NULL, status TEXT NOT NULL,
              started_at INTEGER NOT NULL, input_tokens INTEGER DEFAULT 0,
              output_tokens INTEGER DEFAULT 0, reasoning_tokens INTEGER DEFAULT 0,
              cache_creation_input_tokens INTEGER DEFAULT 0,
              cache_read_input_tokens INTEGER DEFAULT 0,
              computed_total_tokens INTEGER DEFAULT 0);\n
            """
        for (index, row) in rows.enumerated() {
            sql += """
                INSERT INTO model_usage VALUES ('r\(index)', 'lr\(index)', 0, \
                '\(row.provider)', '\(row.model)', '\(row.status)', \(row.startedAtMilliseconds), \
                \(row.input), \(row.output), \(row.reasoning), \(row.cacheWrite), \(row.cacheRead), \
                \(row.input + row.output));\n
                """
        }
        try Self.run(sql: sql, at: databasePath)
        if wal {
            for suffix in ["-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: databasePath + suffix)
            }
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    struct Row {
        var startedAtMilliseconds: Int64
        var provider: String
        var model: String
        var status: String
        var input: Int
        var output: Int
        var reasoning: Int
        var cacheWrite: Int
        var cacheRead: Int

        /// `input` is ZCode's `input_tokens`, which already contains the cached prefix.
        static func request(
            at date: Date,
            provider: String = "builtin:zai-coding-plan",
            model: String = "GLM-5.3",
            status: String = "completed",
            input: Int = 0,
            output: Int = 0,
            reasoning: Int = 0,
            cacheWrite: Int = 0,
            cacheRead: Int = 0
        ) -> Row {
            Row(startedAtMilliseconds: Int64(date.timeIntervalSince1970 * 1000),
                provider: provider, model: model, status: status, input: input, output: output,
                reasoning: reasoning, cacheWrite: cacheWrite, cacheRead: cacheRead)
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

private func scan(_ fixture: ZCodeFixture, daysBack: Int = 30, now: Date) async throws -> UsageHistory? {
    let path = fixture.databasePath
    return try await ZCodeHistoryProvider(databasePaths: { [path] })
        .scanHistory(daysBack: daysBack, now: now)
}

private let noon = Date(timeIntervalSince1970: 1_780_000_000)

// MARK: - The bug this provider exists to avoid

@Test func theCachedPrefixIsSplitOutOfInputInsteadOfCountedTwice() async throws {
    // A real row: 387,727 input of which 387,520 was a cache hit, plus 234 output.
    let fixture = try ZCodeFixture(rows: [
        .request(at: noon, input: 387_727, output: 234, cacheRead: 387_520)
    ])
    defer { fixture.cleanUp() }
    let history = try #require(try await scan(fixture, now: noon))
    let day = try #require(history.days.first)
    #expect(day.tokens.cacheRead == 387_520)
    #expect(day.tokens.input == 207)
    #expect(day.tokens.output == 234)
    // ZCode's own computed_total_tokens is input_tokens + output_tokens; the four buckets must
    // add back up to it rather than double-counting the cached prefix.
    #expect(day.tokens.total == 387_727 + 234)
}

@Test func theFourBucketsAlwaysReconcileWithZCodesOwnTotal() async throws {
    let fixture = try ZCodeFixture(rows: [
        .request(at: noon, input: 1_000, output: 50, cacheWrite: 200, cacheRead: 700),
        // Defensive: cache columns larger than input_tokens must not produce a negative bucket.
        .request(at: noon, input: 100, output: 10, cacheWrite: 90, cacheRead: 400)
    ])
    defer { fixture.cleanUp() }
    let history = try #require(try await scan(fixture, now: noon))
    let day = try #require(history.days.first)
    #expect(day.tokens.input >= 0)
    #expect(day.tokens.total == 1_000 + 50 + 100 + 10)
}

@Test func reasoningIsDetailNotAnExtraOutputBucket() async throws {
    let fixture = try ZCodeFixture(rows: [
        .request(at: noon, input: 500, output: 120, reasoning: 80)
    ])
    defer { fixture.cleanUp() }
    let history = try #require(try await scan(fixture, now: noon))
    let day = try #require(history.days.first)
    #expect(day.tokens.reasoning == 80)
    #expect(day.tokens.output == 120)
    #expect(day.tokens.total == 620)
}

// MARK: - Reading while ZCode is closed

@Test func aWALDatabaseLeftCheckpointedByACleanExitIsStillReadable() async throws {
    let fixture = try ZCodeFixture(rows: [
        .request(at: noon, input: 387_727, output: 234, cacheRead: 387_520)
    ], wal: true)
    defer { fixture.cleanUp() }
    // A clean exit checkpoints and deletes the sidecars; a read-only connection then cannot
    // recreate them, which is the whole bug.
    #expect(!FileManager.default.fileExists(atPath: fixture.databasePath + "-wal"))
    let history = try #require(try await scan(fixture, now: noon))
    let day = try #require(history.days.first)
    #expect(day.requests == 1)
    #expect(day.tokens.total == 387_727 + 234)
}

// MARK: - Rows that must not be counted

@Test func onlyCompletedRequestsCount() async throws {
    let fixture = try ZCodeFixture(rows: [
        .request(at: noon, input: 300, output: 20),
        .request(at: noon, status: "error"),
        .request(at: noon, status: "cancelled"),
        .request(at: noon, status: "running", input: 999, output: 999)
    ])
    defer { fixture.cleanUp() }
    let history = try #require(try await scan(fixture, now: noon))
    let day = try #require(history.days.first)
    #expect(day.requests == 1)
    #expect(day.tokens.total == 320)
}

@Test func requestsOlderThanTheWindowAreExcluded() async throws {
    let fixture = try ZCodeFixture(rows: [
        .request(at: noon, input: 100, output: 10),
        .request(at: noon.addingTimeInterval(-40 * 86_400), input: 5_000, output: 500)
    ])
    defer { fixture.cleanUp() }
    let history = try #require(try await scan(fixture, daysBack: 30, now: noon))
    #expect(history.days.count == 1)
    #expect(history.days.first?.tokens.total == 110)
}

// MARK: - Labels and installation

@Test func thePlanStaysInTheLabelAndTheBuiltinMarkerDoesNot() async throws {
    let fixture = try ZCodeFixture(rows: [
        .request(at: noon, provider: "builtin:zai-coding-plan", model: "GLM-5.3", input: 10, output: 1),
        .request(at: noon, provider: "builtin:zai-start-plan", model: "GLM-5.3-Flash", input: 20, output: 2)
    ])
    defer { fixture.cleanUp() }
    let history = try #require(try await scan(fixture, now: noon))
    let day = try #require(history.days.first)
    #expect(Set(day.models.map(\.model)) == ["zai-coding-plan/GLM-5.3", "zai-start-plan/GLM-5.3-Flash"])
    #expect(ZCodeHistoryProvider.label(provider: "custom", model: "m") == "custom/m")
}

@Test func aMachineWithoutZCodeReportsNotInstalledRatherThanEmpty() async throws {
    #expect(try await ZCodeHistoryProvider(databasePaths: { [] }).scanHistory(now: noon) == nil)
    #expect(ZCodePaths.databaseFiles(path: "/nowhere/db.sqlite").isEmpty)
    #expect(ZCodePaths.databaseFile(homeDirectory: URL(fileURLWithPath: "/Users/x"))
        == "/Users/x/.zcode/cli/db/db.sqlite")
}
