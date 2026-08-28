import Foundation
import LLMUsagePreferences

struct MiniMaxProvider: UsageProvider {
    let id = "minimax"
    let displayName = "MiniMax"

    private static let globalBaseURL = URL(string: "https://api.minimax.io")!
    private static let cnBaseURL = URL(string: "https://api.minimaxi.com")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsage() async throws -> Usage {
        let credential = try Self.loadCredential()
        let bases = Self.candidateBaseURLs(region: credential.region)

        do {
            return try await Self.firstSuccessful(
                session: session,
                bases: bases,
                credential: credential
            )
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.network("MiniMax: \(error.localizedDescription)")
        }
    }

    /// Probes each candidate base URL in order and returns the first one whose body decodes
    /// cleanly. Region-pin (config or env) locks the order so a configured region never silently
    /// switches; without a hint we try both regions, since MiniMax returns a hard `2049`
    /// "wrong region" otherwise and the only way to learn the correct one is to ask.
    private static func firstSuccessful(
        session: URLSession,
        bases: [URL],
        credential: Credential
    ) async throws -> Usage {
        var sawRegionMismatch = false
        for base in bases {
            let url = credential.endpoint(against: base)
            let request = URLRequest.usageRequest(url: url, bearerToken: credential.apiKey)
            do {
                let (data, response) = try await session.data(for: request)
                let http = try validatedHTTPResponse(response, provider: "MiniMax")
                return try mapResponse(
                    data,
                    kind: credential.kind,
                    httpStatus: http.statusCode
                )
            } catch let error as UsageError {
                if case .regionMismatch = error {
                    sawRegionMismatch = true
                    continue
                }
                throw error
            }
        }
        // If every probe returned the "wrong region" sentinel, the key is not valid for either
        // base we know about. Surface that as `noPlan` rather than leaking the internal signal.
        let terminal: UsageError = sawRegionMismatch ? .noPlan : .missingCredentials
        throw terminal
    }

    private static func candidateBaseURLs(region: Region) -> [URL] {
        switch region {
        case .global:
            return [globalBaseURL, cnBaseURL]
        case .cn:
            return [cnBaseURL, globalBaseURL]
        }
    }

    static func mapResponse(
        _ data: Data,
        kind: CredentialKind,
        httpStatus: Int,
        now: Date = Date()
    ) throws -> Usage {
        switch kind {
        case .payAsYouGo:
            return try mapBalance(data, httpStatus: httpStatus)
        case .tokenPlan:
            return try mapTokenPlan(data, httpStatus: httpStatus, now: now)
        }
    }

    private static func mapBalance(_ data: Data, httpStatus: Int) throws -> Usage {
        let root = try ProviderJSON.object(data)
        if let baseResp = root["base_resp"] as? [String: Any],
           let code = ProviderJSON.number(baseResp["status_code"]),
           Int(code) != 0 {
            throw UsageError.regionMismatch
        }
        let available = ProviderJSON.number(root["available_amount"]) ?? 0
        let total = (ProviderJSON.number(root["cash_balance"]) ?? 0)
            + (ProviderJSON.number(root["voucher_balance"]) ?? 0)
            + (ProviderJSON.number(root["credit_balance"]) ?? 0)
        guard total > 0 else {
            throw UsageError.network("MiniMax: balance response missing totals")
        }
        let percent = Int(((total - available) / total * 100).rounded())
        return Usage(
            plan: "Pay-as-you-go",
            lines: [
                MetricLine(
                    label: "Credits",
                    percent: min(100, max(0, percent)),
                    text: String(format: "%.2f", available),
                    resetsAt: nil
                )
            ]
        )
    }

    private static func mapTokenPlan(_ data: Data, httpStatus: Int, now: Date) throws -> Usage {
        _ = httpStatus
        let root = try ProviderJSON.object(data)
        if let baseResp = root["base_resp"] as? [String: Any],
           let code = ProviderJSON.number(baseResp["status_code"]),
           Int(code) != 0 {
            throw UsageError.regionMismatch
        }

        let models = (root["model_remains"] as? [[String: Any]]) ?? []
        let activeModels = models.filter { !isUnavailablePlan($0) }
        guard !activeModels.isEmpty else {
            throw UsageError.emptyButSuccessful(raw: String(decoding: data, as: UTF8.self))
        }

        let lines = activeModels.flatMap { MetricLine.metrics(for: $0, now: now) }
        guard !lines.isEmpty else {
            throw UsageError.emptyButSuccessful(raw: String(decoding: data, as: UTF8.self))
        }

        return Usage(plan: "Token Plan", lines: lines)
    }

    /// The API uses `status: 3` (unlimited) for both windows with zero totals when a model has
    /// no quota bucket in the current plan. Treat that combination as "not in plan" and drop the
    /// model entirely instead of rendering a fake "0% used" tile. A real limited plan entry can
    /// still come back with `total_count: 0` and a populated `*_remaining_percent`, which the
    /// metric line builder handles.
    private static func isUnavailablePlan(_ model: [String: Any]) -> Bool {
        let intervalTotal = ProviderJSON.number(model["current_interval_total_count"]) ?? 0
        let weeklyTotal = ProviderJSON.number(model["current_weekly_total_count"]) ?? 0
        let intervalStatus = ProviderJSON.number(model["current_interval_status"]) ?? 0
        let weeklyStatus = ProviderJSON.number(model["current_weekly_status"]) ?? 0
        return intervalTotal == 0
            && weeklyTotal == 0
            && Int(intervalStatus) == 3
            && Int(weeklyStatus) == 3
    }

    private struct Credential {
        let apiKey: String
        let region: Region
        let kind: CredentialKind

        var baseURL: URL {
            region.baseURL
        }

        func endpoint(against base: URL) -> URL {
            switch kind {
            case .payAsYouGo:
                return base.appendingPathComponent("account/query_balance")
            case .tokenPlan:
                return base.appendingPathComponent("v1/token_plan/remains")
            }
        }
    }

    /// Distinguished by the prefix MiniMax stamps on its keys so the right endpoint is picked
    /// without forcing the user to choose between pay-as-you-go and token-plan separately.
    enum CredentialKind { case tokenPlan, payAsYouGo }

    private enum Region: String {
        case global
        case cn

        var baseURL: URL {
            switch self {
            case .global: MiniMaxProvider.globalBaseURL
            case .cn: MiniMaxProvider.cnBaseURL
            }
        }
    }

    private static func loadCredential() throws -> Credential {
        if let credential = readConfigFile() { return credential }
        if let credential = readRawKeyFile() { return credential }

        let environment = ProcessInfo.processInfo.environment
        if let key = trimmed(environment["MINIMAX_API_KEY"]) {
            let region = Region(rawValue: environment["MINIMAX_REGION"]?.lowercased() ?? "")
                ?? .global
            return Credential(apiKey: key, region: region, kind: kind(forKey: key))
        }

        throw UsageError.missingCredentials
    }

    private static func readConfigFile() -> Credential? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/llmusage/minimax.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = trimmed(root["apiKey"] as? String)
        else { return nil }

        let regionRaw = (root["region"] as? String)?.lowercased()
        let region = Region(rawValue: regionRaw ?? "") ?? .global
        return Credential(apiKey: key, region: region, kind: kind(forKey: key))
    }

    /// A bare key file at `~/.config/llm/minimax.key` is the convention several tools on this
    /// machine already share (the opencode provider block points its `apiKey` at it). Reading it
    /// here means the user does not have to maintain a second copy just for LLMUsage.
    private static func readRawKeyFile() -> Credential? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/llm/minimax.key")
        guard let data = try? Data(contentsOf: path),
              let key = String(data: data, encoding: .utf8).flatMap(trimmed)
        else { return nil }

        let environment = ProcessInfo.processInfo.environment
        let region = Region(rawValue: environment["MINIMAX_REGION"]?.lowercased() ?? "")
            ?? .global
        return Credential(apiKey: key, region: region, kind: kind(forKey: key))
    }

    private static func kind(forKey key: String) -> CredentialKind {
        if key.hasPrefix("sk-api-") { return .payAsYouGo }
        return .tokenPlan
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private extension MetricLine {
    /// Build the session + weekly lines MiniMax exposes for one model. Either window may be
    /// absent (e.g. an unlimited weekly quota or a model only covered by the 5h window), and
    /// `weekly_boost_permille` lets a boosted plan render above 100% — we clamp at 100 because
    /// the LLMUsage meter tops out there. When the API gives `total_count: 0` but a populated
    /// `*_remaining_percent`, we trust the percent instead of bailing out.
    static func metrics(for model: [String: Any], now: Date) -> [MetricLine] {
        var lines: [MetricLine] = []
        if let session = window(
            total: model["current_interval_total_count"],
            usage: model["current_interval_usage_count"],
            percent: model["current_interval_remaining_percent"],
            endTime: model["end_time"],
            label: "Session",
            now: now
        ) {
            lines.append(session)
        }
        if let weekly = window(
            total: model["current_weekly_total_count"],
            usage: model["current_weekly_usage_count"],
            percent: model["current_weekly_remaining_percent"],
            endTime: model["weekly_end_time"],
            label: "Weekly",
            now: now,
            boostPermille: model["weekly_boost_permille"] as? Double
        ) {
            lines.append(weekly)
        }
        return lines
    }

    private static func window(
        total: Any?,
        usage: Any?,
        percent: Any?,
        endTime: Any?,
        label: String,
        now: Date,
        boostPermille: Double? = nil
    ) -> MetricLine? {
        let totalCount = ProviderJSON.number(total) ?? 0
        let usedCount = ProviderJSON.number(usage) ?? 0

        let remainingPct: Int?
        if let percentValue = ProviderJSON.number(percent) {
            let boosted = percentValue * (boostPermille ?? 1_000) / 1_000
            remainingPct = max(0, min(100, Int(boosted.rounded())))
        } else if totalCount > 0 {
            remainingPct = max(0, min(100, Int(((totalCount - usedCount) / totalCount * 100).rounded())))
        } else {
            remainingPct = nil
        }
        guard let remainingPct else { return nil }

        return MetricLine(
            label: label,
            percent: 100 - remainingPct,
            text: nil,
            resetsAt: ProviderJSON.epochDate(endTime, milliseconds: true)
        )
    }
}