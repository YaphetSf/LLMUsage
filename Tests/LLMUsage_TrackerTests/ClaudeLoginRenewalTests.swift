import Foundation
import Testing
@testable import LLMUsage_Tracker

/// The tracker renews Claude Code's OAuth login itself instead of waiting for the CLI to run.
@Suite(.serialized)
struct ClaudeLoginRenewalTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func expiredLoginIsRenewedAndWrittenBackBesideTheRestOfTheEntry() async throws {
        let directory = try makeConfigDirectory(expiresAt: now.addingTimeInterval(-60))
        let calls = StubServer.start { request in
            request.url == ClaudeCredentialStore.tokenURL
                ? (200, #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":28800,"scope":"user:inference user:profile"}"#)
                : (200, #"{"five_hour":{"utilization":12,"resets_at":"2027-01-15T12:00:00Z"}}"#)
        }

        let usage = try await ClaudeProvider(session: StubServer.session, credentials: store(directory)).fetchUsage()

        #expect(usage.lines.map(\.percent) == [12])
        #expect(usage.plan == "Max 20x")
        let requests = calls()
        #expect(requests.compactMap(\.url?.host) == ["platform.claude.com", "api.anthropic.com"])
        let grant = try #require(try JSONSerialization.jsonObject(with: requests[0].bodyData) as? [String: Any])
        #expect(grant["grant_type"] as? String == "refresh_token")
        #expect(grant["refresh_token"] as? String == "old-refresh")
        #expect(grant["scope"] as? String == "user:inference user:profile")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
        let root = try readCredentials(directory)
        let oauth = try #require(root["claudeAiOauth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == "new-access")
        #expect(oauth["refreshToken"] as? String == "new-refresh")
        #expect(oauth["expiresAt"] as? Int == Int(now.timeIntervalSince1970 * 1000) + 28_800_000)
        #expect(oauth["subscriptionType"] as? String == "max")
        #expect((root["mcpOAuth"] as? [String: Any])?["server"] as? String == "kept")
        let permissions = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(".credentials.json").path
        )[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".oauth_refresh.lock").path))
    }

    @Test func liveLoginIsUsedWithoutRenewal() async throws {
        let directory = try makeConfigDirectory(expiresAt: now.addingTimeInterval(3600))
        let calls = StubServer.start { _ in (200, #"{"five_hour":{"utilization":3}}"#) }

        _ = try await ClaudeProvider(session: StubServer.session, credentials: store(directory)).fetchUsage()

        #expect(calls().compactMap(\.url?.host) == ["api.anthropic.com"])
    }

    @Test func rejectedTokenIsRenewedOnceAndRetried() async throws {
        let directory = try makeConfigDirectory(expiresAt: now.addingTimeInterval(3600))
        let calls = StubServer.start { request in
            if request.url == ClaudeCredentialStore.tokenURL {
                return (200, #"{"access_token":"new-access","expires_in":28800}"#)
            }
            let fresh = request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access"
            return fresh ? (200, #"{"five_hour":{"utilization":3}}"#) : (401, "{}")
        }

        _ = try await ClaudeProvider(session: StubServer.session, credentials: store(directory)).fetchUsage()

        #expect(calls().compactMap(\.url?.host) == ["api.anthropic.com", "platform.claude.com", "api.anthropic.com"])
        let oauth = try #require(try readCredentials(directory)["claudeAiOauth"] as? [String: Any])
        #expect(oauth["refreshToken"] as? String == "old-refresh")
    }

    @Test func deadRefreshTokenReportsAnExpiredLogin() async throws {
        let directory = try makeConfigDirectory(expiresAt: now.addingTimeInterval(-60))
        _ = StubServer.start { _ in (400, #"{"error":"invalid_grant"}"#) }

        await #expect(throws: UsageError.authExpired) {
            try await ClaudeProvider(session: StubServer.session, credentials: store(directory)).fetchUsage()
        }
        let oauth = try #require(try readCredentials(directory)["claudeAiOauth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == "old-access")
    }

    @Test func refreshLockYieldsToALiveHolderAndTakesOverAnAbandonedOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(".oauth_refresh.lock").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)

        #expect(ClaudeRefreshLock.tryAcquire([path]) == nil)
        #expect(FileManager.default.fileExists(atPath: path))

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90)], ofItemAtPath: path)
        let lock = try #require(ClaudeRefreshLock.tryAcquire([path]))
        #expect(FileManager.default.fileExists(atPath: path))
        lock.release()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func keychainServiceFollowsTheConfigDirectoryLikeClaudeCode() {
        #expect(ClaudeCredentialStore.keychainService(configDirectory: nil) == "Claude Code-credentials")
        #expect(ClaudeCredentialStore.keychainService(configDirectory: "/tmp/claude-alt")
            == "Claude Code-credentials-04923786")
        #expect(ClaudeCredentialStore.keychainAccount(["USER": "ding"]) == "ding")
        #expect(ClaudeCredentialStore.keychainAccount(["USER": "a b"]) == "claude-code-user")
    }

    private func store(_ directory: URL) -> ClaudeCredentialStore {
        let now = now
        return ClaudeCredentialStore(configDirectory: directory, keychain: nil, session: StubServer.session, now: { now })
    }

    private func makeConfigDirectory(expiresAt: Date) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root: [String: Any] = [
            "mcpOAuth": ["server": "kept"],
            "claudeAiOauth": [
                "accessToken": "old-access",
                "refreshToken": "old-refresh",
                "expiresAt": Int(expiresAt.timeIntervalSince1970 * 1000),
                "scopes": ["user:inference", "user:profile"],
                "subscriptionType": "max",
                "rateLimitTier": "default_claude_max_20x"
            ]
        ]
        try JSONSerialization.data(withJSONObject: root)
            .write(to: directory.appendingPathComponent(".credentials.json"))
        return directory
    }

    private func readCredentials(_ directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(".credentials.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class StubServer: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, String)

    private nonisolated(unsafe) static var handler: Handler?
    private nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }()

    static func start(_ handler: @escaping Handler) -> @Sendable () -> [URLRequest] {
        lock.withLock {
            self.handler = handler
            requests = []
        }
        return { lock.withLock { requests } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        request.httpBody = request.bodyData
        let handler = Self.lock.withLock {
            Self.requests.append(request)
            return Self.handler
        }
        let (status, body) = handler?(request) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// URLProtocol sees the body as a stream.
    var bodyData: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
