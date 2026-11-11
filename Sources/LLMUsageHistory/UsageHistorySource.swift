import Foundation

public protocol UsageHistorySource: Sendable {
    func cachedSnapshot(timeZone: TimeZone) async -> UsageHistorySnapshot?
    func refresh(daysBack: Int, now: Date, timeZone: TimeZone) async throws -> UsageHistorySnapshot
}

extension UsageHistoryRepository: UsageHistorySource {}

public enum UsageHistoryExport {
    public static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LLMUsage/history.json")

    public static func write(_ snapshot: UsageHistorySnapshot, to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}
