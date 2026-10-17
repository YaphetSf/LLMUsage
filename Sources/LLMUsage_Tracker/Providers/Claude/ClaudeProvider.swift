import Foundation
import LLMUsagePreferences

struct ClaudeProvider: UsageProvider {
    let id = "claude"
    let displayName = "Claude"

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session: URLSession
    private let credentials: ClaudeCredentialStore

    init(session: URLSession = .shared, credentials: ClaudeCredentialStore? = nil) {
        self.session = session
        self.credentials = credentials ?? ClaudeCredentialStore(session: session)
    }

    func fetchUsage() async throws -> Usage {
        var credential = try await credentials.validCredential()
        var (data, response) = try await requestUsage(bearerToken: credential.accessToken)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            credential = try await credentials.refresh(replacing: credential.accessToken)
            (data, response) = try await requestUsage(bearerToken: credential.accessToken)
        }
        _ = try validatedHTTPResponse(response, provider: displayName)
        return try Self.mapResponse(data, plan: credential.plan)
    }

    private func requestUsage(bearerToken: String) async throws -> (Data, URLResponse) {
        let request = URLRequest.usageRequest(
            url: Self.usageURL,
            bearerToken: bearerToken,
            headers: [
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "claude-code/2.1.69"
            ]
        )
        do {
            return try await session.data(for: request)
        } catch {
            throw UsageError.network("Claude: \(error.localizedDescription)")
        }
    }

    static func mapResponse(_ data: Data, plan: String? = nil) throws -> Usage {
        let body = try ProviderJSON.object(data)
        let fields = [
            (key: "five_hour", label: "Session"),
            (key: "seven_day", label: "Weekly"),
            (key: "seven_day_sonnet", label: "Sonnet")
        ]
        let lines = fields.compactMap { field -> MetricLine? in
            guard let window = body[field.key] as? [String: Any],
                  let usedPercent = ProviderJSON.number(window["utilization"]),
                  let percent = ProviderJSON.percent(usedPercent)
            else { return nil }
            return MetricLine(
                label: field.label,
                percent: percent,
                text: nil,
                resetsAt: ProviderJSON.iso8601Date(window["resets_at"]),
                windowIsActive: usedPercent > 0
            )
        }
        return Usage(plan: plan, lines: lines)
    }
}
