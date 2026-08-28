import Foundation
import LLMUsagePreferences

protocol UsageProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func fetchUsage() async throws -> Usage
}

enum UsageError: Error, Equatable, Sendable {
    case missingCredentials
    case authExpired
    case network(String)
    case noPlan
    case regionMismatch
    /// The API told us to back off. Carries the `Retry-After` hint (seconds) when the server
    /// gave us one — for Claude this is the OAuth quota shape, not a server overload.
    case rateLimited(retryAfter: Int?)
    case emptyButSuccessful(raw: String)
}

extension UsageError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing credentials"
        case .authExpired:
            "Authentication expired"
        case .network(let message):
            message
        case .noPlan:
            "No active plan"
        case .regionMismatch:
            "Region mismatch"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                "Rate limited — try again in \(retryAfter)s"
            } else {
                "Rate limited"
            }
        case .emptyButSuccessful:
            "Empty successful response"
        }
    }
}

extension SnapshotResult {
    /// Bridge a live `Result<Usage, UsageError>` from a provider fetch into the stable
    /// snapshot shape that crosses the process boundary.
    init(_ result: Result<Usage, UsageError>) {
        switch result {
        case .success(let usage): self = .success(usage)
        case .failure(let error):
            switch error {
            case .missingCredentials: self = .missingCredentials
            case .authExpired: self = .authExpired
            case .network(let text): self = .network(text)
            case .noPlan: self = .noPlan
            case .rateLimited(let r): self = .rateLimited(retryAfter: r)
            case .regionMismatch:
                // Region mismatch is internal signalling the caller probes the next base URL;
                // from the control center's perspective the snapshot just failed.
                self = .network("Wrong region")
            case .emptyButSuccessful(let raw): self = .emptyButSuccessful(raw: raw)
            }
        }
    }

    /// Inverse bridge so the popover view (which still keys off `Result`) can render a
    /// snapshot that came back from defaults.
    var asResult: Result<Usage, UsageError> {
        switch self {
        case .success(let usage): .success(usage)
        case .missingCredentials: .failure(.missingCredentials)
        case .authExpired: .failure(.authExpired)
        case .network(let text): .failure(.network(text))
        case .noPlan: .failure(.noPlan)
        case .rateLimited(let r): .failure(.rateLimited(retryAfter: r))
        case .emptyButSuccessful(let raw): .failure(.emptyButSuccessful(raw: raw))
        }
    }
}

enum VerticalUsageMeter {
    static func filledPercent(forUsed usedPercent: Int) -> Int {
        100 - min(100, max(0, usedPercent))
    }
}

enum QuotaRelationship {
    static func sessionIsBlockedByWeeklyLimit(
        sessionUsedPercent: Int,
        weeklyUsedPercent: Int?
    ) -> Bool {
        guard let weeklyUsedPercent else { return false }
        let sessionRemaining = VerticalUsageMeter.filledPercent(forUsed: sessionUsedPercent)
        let weeklyRemaining = VerticalUsageMeter.filledPercent(forUsed: weeklyUsedPercent)
        return sessionRemaining > 0 && weeklyRemaining == 0
    }
}

enum UsageResetRefreshSchedule {
    private static let serverTransitionDelay: TimeInterval = 1

    static func nextRefreshDate(for snapshots: [ProviderSnapshot], now: Date) -> Date? {
        snapshots.compactMap { snapshot -> Date? in
            guard case .success(let usage) = snapshot.result else { return nil }
            return usage.lines
                .compactMap(\.resetsAt)
                .filter { $0 > now }
                .min()
        }
        .min()?
        .addingTimeInterval(serverTransitionDelay)
    }
}

enum ProviderJSON {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.network("Invalid JSON response")
        }
        return object
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return number.doubleValue
        case let string as String:
            return Double(string)
        default:
            return nil
        }
    }

    static func percent(_ value: Any?) -> Int? {
        number(value).map { min(100, max(0, Int($0.rounded()))) }
    }

    static func epochDate(_ value: Any?, milliseconds: Bool = false) -> Date? {
        guard var timestamp = number(value) else { return nil }
        if milliseconds || timestamp > 10_000_000_000 {
            timestamp /= 1000
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    static func iso8601Date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

extension URLRequest {
    static func usageRequest(url: URL, bearerToken: String, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

func validatedHTTPResponse(_ response: URLResponse, provider: String) throws -> HTTPURLResponse {
    guard let http = response as? HTTPURLResponse else {
        throw UsageError.network("\(provider): invalid HTTP response")
    }
    if http.statusCode == 401 || http.statusCode == 403 {
        throw UsageError.authExpired
    }
    if http.statusCode == 429 {
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
            .flatMap { Int($0) }
            ?? http.value(forHTTPHeaderField: "retry-after")
                .flatMap { Int($0) }
        throw UsageError.rateLimited(retryAfter: retryAfter)
    }
    guard (200..<300).contains(http.statusCode) else {
        throw UsageError.network("\(provider): HTTP \(http.statusCode)")
    }
    return http
}