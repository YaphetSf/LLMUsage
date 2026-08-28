import Foundation
import LLMUsagePreferences

struct CodexProvider: UsageProvider {
    let id = "codex"
    let displayName = "Codex"

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsage() async throws -> Usage {
        let credential = try Self.loadCredential()
        var headers = ["User-Agent": "LLMUsage"]
        if let accountID = credential.accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        let request = URLRequest.usageRequest(
            url: Self.usageURL,
            bearerToken: credential.accessToken,
            headers: headers
        )

        do {
            let (data, response) = try await session.data(for: request)
            let http = try validatedHTTPResponse(response, provider: displayName)
            return try Self.mapResponse(data, headers: http.allHeaderFields, now: Date())
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.network("Codex: \(error.localizedDescription)")
        }
    }

    static func mapResponse(
        _ data: Data,
        headers: [AnyHashable: Any] = [:],
        now: Date = Date()
    ) throws -> Usage {
        let body = try ProviderJSON.object(data)
        let rateLimit = body["rate_limit"] as? [String: Any]
        let candidates: [WindowCandidate] = [
            makeCandidate(
                rateLimit?["primary_window"],
                headerPercent: header(headers, named: "x-codex-primary-used-percent"),
                fallback: .session
            ),
            makeCandidate(
                rateLimit?["secondary_window"],
                headerPercent: header(headers, named: "x-codex-secondary-used-percent"),
                fallback: .weekly
            )
        ].compactMap { $0 }

        var lines: [MetricLine] = []
        if let session = line(kind: .session, candidates: candidates, now: now) { lines.append(session) }
        if let weekly = line(kind: .weekly, candidates: candidates, now: now) { lines.append(weekly) }

        let plan = formatPlan(body["plan_type"] as? String)
        return Usage(plan: plan, lines: lines)
    }

    private enum WindowKind { case session, weekly }

    private struct WindowCandidate {
        let window: [String: Any]
        let percent: Int?
        let fallback: WindowKind
    }

    private static func makeCandidate(
        _ value: Any?,
        headerPercent: Double?,
        fallback: WindowKind
    ) -> WindowCandidate? {
        guard let window = value as? [String: Any] ?? (headerPercent == nil ? nil : [:]) else { return nil }
        return WindowCandidate(
            window: window,
            percent: ProviderJSON.percent(window["used_percent"] ?? headerPercent),
            fallback: fallback
        )
    }

    private static func line(kind: WindowKind, candidates: [WindowCandidate], now: Date) -> MetricLine? {
        let exact = candidates.first { exactKind($0.window) == kind }
        let fallback = candidates.first { exactKind($0.window) == nil && $0.fallback == kind }
        guard let candidate = exact ?? fallback, let percent = candidate.percent else { return nil }
        let label = kind == .session ? "Session" : "Weekly"
        return MetricLine(label: label, percent: percent, text: nil, resetsAt: resetDate(candidate.window, now: now))
    }

    private static func exactKind(_ window: [String: Any]) -> WindowKind? {
        guard let seconds = ProviderJSON.number(window["limit_window_seconds"]) else { return nil }
        return switch Int(seconds) {
        case 18_000: .session
        case 604_800: .weekly
        default: nil
        }
    }

    private static func resetDate(_ window: [String: Any], now: Date) -> Date? {
        if let date = ProviderJSON.epochDate(window["reset_at"]) { return date }
        return ProviderJSON.number(window["reset_after_seconds"]).map { now.addingTimeInterval($0) }
    }

    private static func header(_ headers: [AnyHashable: Any], named name: String) -> Double? {
        let value = headers.first { String(describing: $0.key).caseInsensitiveCompare(name) == .orderedSame }?.value
        return ProviderJSON.number(value)
    }

    private static func formatPlan(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "prolite": return "Pro 5x"
        case "pro": return "Pro 20x"
        default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private struct Credential {
        let accessToken: String
        let accountID: String?
    }

    private static func loadCredential() throws -> Credential {
        let environment = ProcessInfo.processInfo.environment
        var paths: [URL] = []
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            paths.append(URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json"))
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            paths.append(home.appendingPathComponent(".config/codex/auth.json"))
            paths.append(home.appendingPathComponent(".codex/auth.json"))
        }

        for path in paths {
            guard let data = try? Data(contentsOf: path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = root["tokens"] as? [String: Any],
                  let accessToken = (tokens["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !accessToken.isEmpty
            else { continue }
            return Credential(accessToken: accessToken, accountID: tokens["account_id"] as? String)
        }
        throw UsageError.missingCredentials
    }
}
