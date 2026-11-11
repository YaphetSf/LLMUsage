import Foundation
import LLMUsageHistory
import LLMUsagePreferences

public struct RemoteUsageDocument: Decodable, Sendable {
    public let updatedAt: Date
    private let providers: [Provider]

    private struct Provider: Decodable, Sendable {
        let id: String
        let name: String
        let plan: String?
        let error: String?
        let lines: [Line]
    }

    private struct Line: Decodable, Sendable {
        let label: String
        let usedPercent: Int?
        let text: String?
        let resetsAt: Date?
        let windowIsActive: Bool?
    }

    public var snapshots: [ProviderSnapshot] {
        providers.map { provider in
            ProviderSnapshot(id: provider.id, displayName: provider.name,
                result: provider.error.map(SnapshotResult.network) ?? .success(Usage(
                    plan: provider.plan,
                    lines: provider.lines.map {
                        MetricLine(label: $0.label, percent: $0.usedPercent, text: $0.text,
                                   resetsAt: $0.resetsAt, windowIsActive: $0.windowIsActive)
                    }
                )))
        }
    }
}

public struct RemoteUsageClient: UsageHistorySource, Sendable {
    private let configuration: RuntimeConfiguration
    private let session: URLSession
    private let cacheDirectory: URL

    public init(configuration: RuntimeConfiguration = .current, session: URLSession = .shared,
                cacheDirectory: URL? = nil) {
        self.configuration = configuration
        self.session = session
        self.cacheDirectory = cacheDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/LLMUsage/remote", isDirectory: true)
    }

    public func quota() async throws -> RemoteUsageDocument {
        let data = try await fetch("api/usage")
        let document = try Self.quotaDecoder().decode(RemoteUsageDocument.self, from: data)
        guard Set(document.snapshots.map(\.id)).count == document.snapshots.count else {
            throw RemoteUsageError.invalidResponse
        }
        try store(data, name: "usage.json")
        return document
    }

    public func cachedQuota() -> RemoteUsageDocument? {
        guard let data = try? Data(contentsOf: cacheURL("usage.json")) else { return nil }
        return try? Self.quotaDecoder().decode(RemoteUsageDocument.self, from: data)
    }

    public func cachedSnapshot(timeZone: TimeZone) async -> UsageHistorySnapshot? {
        guard let data = try? Data(contentsOf: cacheURL("history.json")) else { return nil }
        return try? Self.historyDecoder().decode(UsageHistorySnapshot.self, from: data)
    }

    public func refresh(daysBack: Int, now: Date, timeZone: TimeZone) async throws -> UsageHistorySnapshot {
        let data = try await fetch("api/usage/history")
        let snapshot = try Self.historyDecoder().decode(UsageHistorySnapshot.self, from: data)
        try store(data, name: "history.json")
        return snapshot
    }

    private func fetch(_ path: String) async throws -> Data {
        guard let baseURL = configuration.serverURL,
              ["http", "https"].contains(baseURL.scheme),
              let keyFile = configuration.keyFile else { throw RemoteUsageError.notConfigured }
        let keyURL = URL(fileURLWithPath: (keyFile as NSString).expandingTildeInPath)
        let key: String
        do {
            key = try String(contentsOf: keyURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { throw RemoteUsageError.missingKey }
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else { throw RemoteUsageError.missingKey }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw RemoteUsageError.invalidResponse }
        switch response.statusCode {
        case 200: return data
        case 401, 403: throw RemoteUsageError.unauthorized
        case 503: throw RemoteUsageError.unpublished
        default: throw RemoteUsageError.http(response.statusCode)
        }
    }

    private func cacheURL(_ name: String) -> URL {
        let namespace = Data((configuration.serverURL?.absoluteString ?? "unconfigured").utf8)
            .base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return cacheDirectory.appendingPathComponent(namespace, isDirectory: true).appendingPathComponent(name)
    }

    private func store(_ data: Data, name: String) throws {
        let url = cacheURL(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func quotaDecoder() -> JSONDecoder {
        let decoder = historyDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private static func historyDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum RemoteUsageError: LocalizedError {
    case notConfigured, missingKey, invalidResponse, unauthorized, unpublished
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Server connection not configured"
        case .missingKey: "Server key unavailable"
        case .invalidResponse: "Invalid server response"
        case .unauthorized: "Server access denied"
        case .unpublished: "Server data not published yet"
        case .http(let status): "Server returned HTTP \(status)"
        }
    }
}
