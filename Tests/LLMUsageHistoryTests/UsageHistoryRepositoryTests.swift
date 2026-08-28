import Foundation
import Testing
@testable import LLMUsageHistory

private struct RepositoryFixtureProvider: UsageHistoryProvider {
    let id: String
    let displayName: String
    let history: UsageHistory?

    func scanHistory(daysBack: Int, now: Date) async throws -> UsageHistory? { history }
}

private struct FailingRepositoryFixtureProvider: UsageHistoryProvider {
    let id: String
    let displayName: String

    func scanHistory(daysBack: Int, now: Date) async throws -> UsageHistory? {
        throw FixtureFailure.unreadable
    }

    private enum FixtureFailure: Error { case unreadable }
}

@Test func repositorySnapshotSurvivesRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("cache.sqlite3")
    let history = UsageHistory(providerID: "fixture", days: [
        DayUsage(day: "2026-08-28", models: [
            ModelDayUsage(
                model: "fixture/model",
                tokens: TokenBreakdown(input: 700),
                requests: 2
            )
        ])
    ])
    let providers: [any UsageHistoryProvider] = [
        RepositoryFixtureProvider(id: "fixture", displayName: "Fixture", history: history)
    ]
    let first = UsageHistoryRepository(providers: providers, databaseURL: database)
    let fresh = await first.refresh(daysBack: 90, now: Date(timeIntervalSince1970: 1_788_000_000))

    let relaunched = UsageHistoryRepository(providers: providers, databaseURL: database)
    let cached = await relaunched.cachedSnapshot()

    #expect(cached == fresh)
    #expect(cached?.daysBack == 90)
    #expect(cached?.results.first?.history == history)
}

@Test func failedRefreshDoesNotDestroyTheLastGoodPersistedSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("cache.sqlite3")
    let history = UsageHistory(providerID: "fixture", days: [
        DayUsage(day: "2026-08-28", models: [
            ModelDayUsage(
                model: "fixture/model",
                tokens: TokenBreakdown(input: 700),
                requests: 2
            )
        ])
    ])
    let good = UsageHistoryRepository(
        providers: [RepositoryFixtureProvider(
            id: "fixture", displayName: "Fixture", history: history
        )],
        databaseURL: database
    )
    _ = await good.refresh(daysBack: 90)

    let failing = UsageHistoryRepository(
        providers: [FailingRepositoryFixtureProvider(id: "fixture", displayName: "Fixture")],
        databaseURL: database
    )
    let liveFailure = await failing.refresh(daysBack: 90)
    if case .failed = liveFailure.results.first?.outcome {} else {
        Issue.record("The live refresh should still surface the provider failure")
    }

    let relaunched = UsageHistoryRepository(
        providers: [FailingRepositoryFixtureProvider(id: "fixture", displayName: "Fixture")],
        databaseURL: database
    )
    #expect(await relaunched.cachedSnapshot()?.results.first?.history == history)
}
