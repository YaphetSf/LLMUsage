import Foundation

/// Snapshot of one provider's quota after a single fetch. The menu-bar tracker writes a
/// `[ProviderSnapshot]` to the shared defaults suite on every refresh; the control center
/// reads it back so its Overview page shows the same numbers without re-fetching.
public struct ProviderSnapshot: Sendable, Codable, Identifiable {
    public let id: String
    public let displayName: String
    public let result: SnapshotResult

    public init(id: String, displayName: String, result: SnapshotResult) {
        self.id = id
        self.displayName = displayName
        self.result = result
    }
}

public struct Usage: Equatable, Sendable, Codable {
    public var plan: String?
    public var lines: [MetricLine]

    public init(plan: String? = nil, lines: [MetricLine]) {
        self.plan = plan
        self.lines = lines
    }
}

public struct MetricLine: Equatable, Sendable, Codable {
    public var label: String
    public var percent: Int?
    public var text: String?
    public var resetsAt: Date?

    public init(label: String, percent: Int? = nil, text: String? = nil, resetsAt: Date? = nil) {
        self.label = label
        self.percent = percent
        self.text = text
        self.resetsAt = resetsAt
    }
}

/// Concrete-decoded result. We re-wrap the standard `Result<Usage, UsageError>` so the JSON
/// shape stays stable across new `UsageError` cases — the control center doesn't need to
/// know every error variant to display the snapshot it reads back from defaults.
public enum SnapshotResult: Sendable, Codable {
    case success(Usage)
    case missingCredentials
    case authExpired
    case network(String)
    case noPlan
    case rateLimited(retryAfter: Int?)
    case emptyButSuccessful(raw: String)
}