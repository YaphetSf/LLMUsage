import Foundation
import Testing
@testable import LLMUsageHistory

private struct CachedTestEntry: Codable, Equatable, Sendable {
    let value: Int
}

private struct CachedTestState: Codable, Equatable, Sendable {
    var batches = 0
}

private func cacheFixture() throws -> (directory: URL, database: URL, first: URL, second: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let first = directory.appendingPathComponent("first.jsonl")
    let second = directory.appendingPathComponent("second.jsonl")
    try Data("1\n".utf8).write(to: first)
    try Data("8\n".utf8).write(to: second)
    return (directory, directory.appendingPathComponent("cache.sqlite3"), first, second)
}

private func parseIntegerLines(
    _ url: URL,
    from offset: Int64,
    state: CachedTestState
) -> JSONLParseBatch<CachedTestEntry, CachedTestState> {
    let data = (try? Data(contentsOf: url)) ?? Data()
    let start = min(max(Int(offset), 0), data.count)
    let values = String(decoding: data[start...], as: UTF8.self)
        .split(separator: "\n")
        .compactMap { Int($0) }
        .map(CachedTestEntry.init(value:))
    return JSONLParseBatch(entries: values, state: CachedTestState(batches: state.batches + 1))
}

@Test func parsedEntriesSurviveAcrossCacheInstancesAndOnlyAppendIsParsed() async throws {
    let fixture = try cacheFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let firstCache = JSONLParseCache<CachedTestEntry, CachedTestState>(
        namespace: "test-v1",
        databaseURL: fixture.database
    )
    let initial = await firstCache.entries(
        for: [fixture.first],
        initialState: CachedTestState(),
        parse: parseIntegerLines
    )
    #expect(initial == [CachedTestEntry(value: 1)])

    let relaunchedCache = JSONLParseCache<CachedTestEntry, CachedTestState>(
        namespace: "test-v1",
        databaseURL: fixture.database
    )
    let restored = await relaunchedCache.entries(
        for: [fixture.first],
        initialState: CachedTestState(),
        parse: { _, _, _ in
            JSONLParseBatch(entries: [CachedTestEntry(value: 999)], state: CachedTestState())
        }
    )
    #expect(restored == initial)

    let handle = try FileHandle(forWritingTo: fixture.first)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("2\n".utf8))
    try handle.close()

    let appended = await relaunchedCache.entries(
        for: [fixture.first],
        initialState: CachedTestState(),
        parse: parseIntegerLines
    )
    #expect(appended == [CachedTestEntry(value: 1), CachedTestEntry(value: 2)])
}

@Test func filesOutsideTheCurrentWindowAreNotImmediatelyEvicted() async throws {
    let fixture = try cacheFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let cache = JSONLParseCache<CachedTestEntry, CachedTestState>(
        namespace: "window-v1",
        databaseURL: fixture.database
    )
    _ = await cache.entries(
        for: [fixture.first, fixture.second],
        initialState: CachedTestState(),
        parse: parseIntegerLines
    )
    _ = await cache.entries(
        for: [fixture.second],
        initialState: CachedTestState(),
        parse: parseIntegerLines
    )

    let relaunchedCache = JSONLParseCache<CachedTestEntry, CachedTestState>(
        namespace: "window-v1",
        databaseURL: fixture.database
    )
    let restored = await relaunchedCache.entries(
        for: [fixture.first],
        initialState: CachedTestState(),
        parse: { _, _, _ in
            JSONLParseBatch(entries: [CachedTestEntry(value: 999)], state: CachedTestState())
        }
    )
    #expect(restored == [CachedTestEntry(value: 1)])
}

@Test func transientParseFailureKeepsTheLastGoodRecordAndCursor() async throws {
    let fixture = try cacheFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let cache = JSONLParseCache<CachedTestEntry, CachedTestState>(
        namespace: "failure-v1",
        databaseURL: fixture.database
    )
    let initial = await cache.entries(
        for: [fixture.first],
        initialState: CachedTestState(),
        parse: parseIntegerLines
    )
    #expect(initial == [CachedTestEntry(value: 1)])

    let handle = try FileHandle(forWritingTo: fixture.first)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("2\n".utf8))
    try handle.close()

    let duringFailure = await cache.entries(
        for: [fixture.first],
        initialState: CachedTestState(),
        parse: { _, _, state in
            JSONLParseBatch(entries: [], state: state, succeeded: false)
        }
    )
    #expect(duringFailure == initial)

    let recovered = await cache.entries(
        for: [fixture.first],
        initialState: CachedTestState(),
        parse: parseIntegerLines
    )
    #expect(recovered == [CachedTestEntry(value: 1), CachedTestEntry(value: 2)])
}
