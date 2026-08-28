import Foundation
import LLMUsagePreferences

struct ZAIProvider: UsageProvider {
    let id = "zai"
    let displayName = "GLM"

    private static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    private static let subscriptionURL = URL(string: "https://api.z.ai/api/biz/subscription/list")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsage() async throws -> Usage {
        let apiKey = try Self.loadAPIKey()
        async let quota = fetch(Self.quotaURL, apiKey: apiKey)
        async let subscription = fetch(Self.subscriptionURL, apiKey: apiKey)

        let quotaData = try await quota
        let subscriptionData = try? await subscription
        return try Self.mapResponse(quotaData, subscriptionData: subscriptionData)
    }

    static func mapResponse(_ quotaData: Data, subscriptionData: Data? = nil) throws -> Usage {
        let root = try ProviderJSON.object(quotaData)
        if root["success"] as? Bool == false {
            throw UsageError.noPlan
        }
        guard root["success"] as? Bool == true,
              let data = root["data"] as? [String: Any],
              let limits = data["limits"] as? [[String: Any]]
        else {
            throw UsageError.network("GLM: invalid quota response")
        }
        if limits.isEmpty {
            throw UsageError.emptyButSuccessful(raw: String(decoding: quotaData, as: UTF8.self))
        }

        var lines: [MetricLine] = []
        for entry in limits {
            let type = (entry["type"] as? String) ?? (entry["name"] as? String)
            guard type == "CREDIT_LIMIT" || type == "TOKENS_LIMIT" else { continue }
            guard let unit = ProviderJSON.number(entry["unit"]),
                  let number = ProviderJSON.number(entry["number"]),
                  number > 0,
                  let percent = ProviderJSON.percent(entry["percentage"])
            else {
                throw UsageError.network("GLM: invalid quota entry")
            }

            let label: String?
            switch Int(unit) {
            case 3, 4: label = "Session"
            case 6: label = "Weekly"
            default: label = nil
            }
            if let label {
                lines.append(MetricLine(
                    label: label,
                    percent: percent,
                    text: nil,
                    resetsAt: ProviderJSON.epochDate(entry["nextResetTime"], milliseconds: true)
                ))
            }
        }
        guard !lines.isEmpty else {
            throw UsageError.network("GLM: response contained no recognized quota limits")
        }

        let plan: String? = subscriptionData.flatMap { body in
            guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let data = root["data"] as? [[String: Any]],
                  let name = data.first?["productName"] as? String,
                  !name.isEmpty
            else { return nil }
            return name
        }
        return Usage(plan: plan, lines: lines)
    }

    private func fetch(_ url: URL, apiKey: String) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: .usageRequest(url: url, bearerToken: apiKey))
            _ = try validatedHTTPResponse(response, provider: displayName)
            return data
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.network("GLM: \(error.localizedDescription)")
        }
    }

    private static func loadAPIKey() throws -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/openusage/zai.json")
        if let data = try? Data(contentsOf: path),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = (root["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }
        for name in ["ZAI_API_KEY", "GLM_API_KEY"] {
            if let key = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                return key
            }
        }
        throw UsageError.missingCredentials
    }
}
