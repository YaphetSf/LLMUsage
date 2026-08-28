import Foundation
import LLMUsagePreferences

struct ClaudeProvider: UsageProvider {
    let id = "claude"
    let displayName = "Claude"

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsage() async throws -> Usage {
        let credential = try Self.loadCredential()
        let request = URLRequest.usageRequest(
            url: Self.usageURL,
            bearerToken: credential.accessToken,
            headers: [
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "claude-code/2.1.69"
            ]
        )

        do {
            let (data, response) = try await session.data(for: request)
            _ = try validatedHTTPResponse(response, provider: displayName)
            return try Self.mapResponse(data, plan: credential.plan)
        } catch let error as UsageError {
            throw error
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
                  let percent = ProviderJSON.percent(window["utilization"])
            else { return nil }
            return MetricLine(
                label: field.label,
                percent: percent,
                text: nil,
                resetsAt: ProviderJSON.iso8601Date(window["resets_at"])
            )
        }
        return Usage(plan: plan, lines: lines)
    }

    private struct Credential {
        let accessToken: String
        let plan: String?
    }

    private static func loadCredential() throws -> Credential {
        // Both sources read what Claude Code wrote from outside its keychain ACL: the
        // on-disk file, and the keychain entry via Apple's `security` tool (covered by the
        // entry's partition list). The in-process SecItem API would prompt for the login
        // password on every access by a binary the ACL has never seen — which is every dev
        // rebuild of this app, since ad-hoc signatures change the cdhash each time.
        let environment = ProcessInfo.processInfo.environment
        let base = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        let path = URL(fileURLWithPath: base).appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: path), let credential = parseCredential(data) {
            return credential
        }
        if let keychain = readKeychain(), let credential = parseCredential(keychain) {
            return credential
        }
        throw UsageError.missingCredentials
    }

    private static func readKeychain() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let secret = String(decoding: output, as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            return secret.isEmpty ? nil : Data(secret.utf8)
        } catch {
            return nil
        }
    }

    private static func parseCredential(_ data: Data) -> Credential? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = (oauth["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }

        let subscription = (oauth["subscriptionType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tier = oauth["rateLimitTier"] as? String
        let basePlan = subscription.flatMap { $0.isEmpty ? nil : $0.capitalized }
        let multiplier = tier.flatMap { value -> String? in
            guard let range = value.range(of: #"\d+x"#, options: .regularExpression) else { return nil }
            return String(value[range])
        }
        let plan = [basePlan, multiplier].compactMap { $0 }.joined(separator: " ")
        return Credential(accessToken: token, plan: plan.isEmpty ? nil : plan)
    }
}
