import Foundation

/// One provider's contribution to a complete Usage snapshot. Keeping failure and installation
/// state beside successful history lets the repository publish one atomic result without one
/// unreadable source blanking the others.
public struct ProviderHistory: Identifiable, Codable, Equatable, Sendable {
    public enum Outcome: Codable, Equatable, Sendable {
        case scanned(UsageHistory)
        case notInstalled
        case failed(String)
    }

    public let id: String
    public let displayName: String
    public let iconName: String
    public let outcome: Outcome

    public init(id: String, displayName: String, iconName: String, outcome: Outcome) {
        self.id = id
        self.displayName = displayName
        self.iconName = iconName
        self.outcome = outcome
    }

    public var history: UsageHistory? {
        if case .scanned(let history) = outcome { return history }
        return nil
    }
}

/// A coherent result from all local history providers. The snapshot is persisted only after every
/// provider finishes, so cancellation or a process exit can never expose a half-refreshed cache.
public struct UsageHistorySnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let daysBack: Int
    public let timeZoneIdentifier: String
    public let results: [ProviderHistory]

    public init(
        generatedAt: Date,
        daysBack: Int,
        timeZoneIdentifier: String,
        results: [ProviderHistory]
    ) {
        self.generatedAt = generatedAt
        self.daysBack = daysBack
        self.timeZoneIdentifier = timeZoneIdentifier
        self.results = results
    }
}

/// The deep module behind the Usage page. Callers either read the last complete snapshot or ask
/// for one refresh; provider concurrency, ordering, failure isolation and persistence stay inside.
public actor UsageHistoryRepository {
    private let providers: [any UsageHistoryProvider]
    private let database: UsageHistoryCacheDatabase?
    private let snapshotKey: String

    public init(
        providers: [any UsageHistoryProvider] = [
            ClaudeHistoryProvider(), CodexHistoryProvider(), OpenCodeHistoryProvider()
        ],
        databaseURL: URL? = nil
    ) {
        self.providers = providers
        let resolvedURL = databaseURL ?? (try? UsageHistoryCacheLocation.defaultDatabaseURL())
        database = resolvedURL.flatMap { try? UsageHistoryCacheDatabase(url: $0) }
        snapshotKey = "usage-snapshot-v1:" + providers.map(\.id).joined(separator: ",")
    }

    public func cachedSnapshot(
        timeZone: TimeZone = .current
    ) -> UsageHistorySnapshot? {
        guard let database,
              let data = try? database.snapshotData(for: snapshotKey),
              let snapshot = try? JSONDecoder().decode(UsageHistorySnapshot.self, from: data),
              snapshot.timeZoneIdentifier == timeZone.identifier
        else { return nil }
        return snapshot
    }

    public func refresh(
        daysBack: Int,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) async -> UsageHistorySnapshot {
        let previous = cachedSnapshot(timeZone: timeZone)
        let providers = self.providers
        let order = Dictionary(uniqueKeysWithValues: providers.enumerated().map { ($1.id, $0) })
        let results = await withTaskGroup(of: ProviderHistory.self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        if let history = try await provider.scanHistory(daysBack: daysBack, now: now) {
                            return ProviderHistory(
                                id: provider.id,
                                displayName: provider.displayName,
                                iconName: provider.iconName,
                                outcome: .scanned(history)
                            )
                        }
                        return ProviderHistory(
                            id: provider.id,
                            displayName: provider.displayName,
                            iconName: provider.iconName,
                            outcome: .notInstalled
                        )
                    } catch {
                        return ProviderHistory(
                            id: provider.id,
                            displayName: provider.displayName,
                            iconName: provider.iconName,
                            outcome: .failed(error.localizedDescription)
                        )
                    }
                }
            }
            return await group.reduce(into: [ProviderHistory]()) { $0.append($1) }
        }
        let snapshot = UsageHistorySnapshot(
            generatedAt: now,
            daysBack: max(daysBack, 1),
            timeZoneIdentifier: timeZone.identifier,
            results: results.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        )
        let previousByID = Dictionary(
            uniqueKeysWithValues: (previous?.results ?? []).map { ($0.id, $0) }
        )
        let persistableResults = snapshot.results.map { result in
            if case .failed = result.outcome,
               let previousResult = previousByID[result.id],
               previousResult.history != nil {
                return previousResult
            }
            return result
        }
        let persistableSnapshot = UsageHistorySnapshot(
            generatedAt: snapshot.generatedAt,
            daysBack: snapshot.daysBack,
            timeZoneIdentifier: snapshot.timeZoneIdentifier,
            results: persistableResults
        )
        if let data = try? JSONEncoder().encode(persistableSnapshot) {
            try? database?.storeSnapshot(data, for: snapshotKey)
        }
        return snapshot
    }
}
