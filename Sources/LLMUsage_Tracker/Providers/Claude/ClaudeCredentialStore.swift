import CryptoKit
import Darwin
import Foundation

/// The OAuth login Claude Code keeps. Its access token lasts hours and Claude Code renews it only
/// while it runs, so the tracker renews it too, the way one more Claude Code process would: under
/// Claude Code's refresh lock, writing the result back where Claude Code reads it. Refresh tokens
/// rotate, so a renewal that is not written back logs Claude Code out.
struct ClaudeCredentialStore: Sendable {
    struct Credential: Equatable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let scopes: [String]
        let plan: String?

        func isExpiring(at now: Date) -> Bool {
            guard let expiresAt else { return false }
            return now.addingTimeInterval(ClaudeCredentialStore.refreshMargin) >= expiresAt
        }
    }

    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Claude Code's own margin: whichever process notices first renews, the rest adopt its result.
    static let refreshMargin: TimeInterval = 300

    let configDirectory: URL
    /// `nil` reads only the credentials file, as Claude Code does where there is no keychain.
    let keychain: ClaudeKeychainItem?
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(
        configDirectory: URL,
        keychain: ClaudeKeychainItem?,
        session: URLSession,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configDirectory = configDirectory
        self.keychain = keychain
        self.session = session
        self.now = now
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment, session: URLSession = .shared) {
        let custom = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let directory = custom.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        self.init(
            configDirectory: directory,
            keychain: ClaudeKeychainItem(
                service: Self.keychainService(configDirectory: custom),
                account: Self.keychainAccount(environment)
            ),
            session: session
        )
    }

    /// Claude Code suffixes its keychain service with a hash of `CLAUDE_CONFIG_DIR` when set.
    static func keychainService(configDirectory: String?) -> String {
        guard let configDirectory else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(configDirectory.precomposedStringWithCanonicalMapping.utf8))
        return "Claude Code-credentials-\(digest.map { String(format: "%02x", $0) }.joined().prefix(8))"
    }

    static func keychainAccount(_ environment: [String: String]) -> String {
        let name = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        return name.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil ? name : "claude-code-user"
    }

    func validCredential() async throws -> Credential {
        let stored = try load()
        guard stored.credential.isExpiring(at: now()) else { return stored.credential }
        return try await refresh(replacing: stored.credential.accessToken)
    }

    /// Renews the login, unless another process replaced `staleToken` with a live one meanwhile.
    func refresh(replacing staleToken: String) async throws -> Credential {
        guard let lock = await ClaudeRefreshLock.acquire(in: configDirectory) else {
            if let adopted = try adoptable(load(), replacing: staleToken) { return adopted }
            throw UsageError.network("Claude: another process is renewing the login")
        }
        defer { lock.release() }

        let stored = try load()
        if let adopted = adoptable(stored, replacing: staleToken) { return adopted }
        guard let refreshToken = stored.credential.refreshToken else { throw UsageError.authExpired }
        let grant = try await requestGrant(refreshToken: refreshToken, scopes: stored.credential.scopes)
        let root = Self.merging(grant, into: stored.root, now: now())
        try save(root, to: stored.location)
        guard let credential = Self.credential(from: root) else { throw UsageError.missingCredentials }
        return credential
    }

    private func adoptable(_ stored: Stored, replacing staleToken: String) -> Credential? {
        stored.credential.accessToken != staleToken && !stored.credential.isExpiring(at: now())
            ? stored.credential : nil
    }

    private func requestGrant(refreshToken: String, scopes: [String]) async throws -> [String: Any] {
        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID
        ]
        if !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        var request = URLRequest(url: Self.tokenURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.network("Claude: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network("Claude: invalid HTTP response")
        }
        switch http.statusCode {
        case 200:
            let grant = try ProviderJSON.object(data)
            guard grant["access_token"] is String, ProviderJSON.number(grant["expires_in"]) != nil else {
                throw UsageError.network("Claude: malformed token response")
            }
            return grant
        case 429:
            throw UsageError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) })
        default:
            let code = (try? ProviderJSON.object(data))?["error"] as? String
            if code == "invalid_grant" { throw UsageError.authExpired }
            throw UsageError.network("Claude: token refresh failed (\(code ?? "HTTP \(http.statusCode)"))")
        }
    }

    static func merging(_ grant: [String: Any], into root: [String: Any], now: Date) -> [String: Any] {
        var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        let nowMilliseconds = now.timeIntervalSince1970 * 1000
        oauth["accessToken"] = grant["access_token"]
        if let refreshToken = grant["refresh_token"] as? String, !refreshToken.isEmpty {
            oauth["refreshToken"] = refreshToken
        }
        if let seconds = ProviderJSON.number(grant["expires_in"]) {
            oauth["expiresAt"] = Int(nowMilliseconds + seconds * 1000)
        }
        if let seconds = ProviderJSON.number(grant["refresh_token_expires_in"]) {
            oauth["refreshTokenExpiresAt"] = Int(nowMilliseconds + seconds * 1000)
        }
        let scopes = (grant["scope"] as? String)?.split(separator: " ").map(String.init) ?? []
        if !scopes.isEmpty { oauth["scopes"] = scopes }
        var merged = root
        merged["claudeAiOauth"] = oauth
        return merged
    }

    static func credential(from root: [String: Any]) -> Credential? {
        guard let oauth = root["claudeAiOauth"] as? [String: Any],
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
        let refreshToken = (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Credential(
            accessToken: token,
            refreshToken: refreshToken,
            expiresAt: ProviderJSON.epochDate(oauth["expiresAt"], milliseconds: true),
            scopes: oauth["scopes"] as? [String] ?? [],
            plan: plan.isEmpty ? nil : plan
        )
    }

    private enum Location {
        case keychain(ClaudeKeychainItem)
        case file(URL)
    }

    private struct Stored {
        let root: [String: Any]
        let location: Location
        let credential: Credential
    }

    /// Keychain first, then the file: the order Claude Code reads them in on macOS.
    private func load() throws -> Stored {
        if let keychain, let data = keychain.read(), let stored = Self.stored(data, at: .keychain(keychain)) {
            return stored
        }
        let file = configDirectory.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: file), let stored = Self.stored(data, at: .file(file)) {
            return stored
        }
        throw UsageError.missingCredentials
    }

    private static func stored(_ data: Data, at location: Location) -> Stored? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credential = credential(from: root)
        else { return nil }
        return Stored(root: root, location: location, credential: credential)
    }

    private func save(_ root: [String: Any], to location: Location) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: .withoutEscapingSlashes)
        switch location {
        case .keychain(let item):
            guard item.write(data) else { throw UsageError.network("Claude: could not save the renewed login") }
        case .file(let url):
            let temporary = url.deletingLastPathComponent()
                .appendingPathComponent(".credentials.json.\(UUID().uuidString)")
            guard FileManager.default.createFile(
                atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]
            ), rename(temporary.path, url.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                throw UsageError.network("Claude: could not save the renewed login")
            }
        }
    }
}

/// Claude Code's keychain entry, read and written through Apple's `security` tool as Claude Code
/// itself does. The entry's partition list trusts that tool, so neither direction prompts; the
/// in-process SecItem API would prompt on every rebuild, since ad-hoc signatures change the cdhash.
struct ClaudeKeychainItem: Equatable, Sendable {
    let service: String
    let account: String

    /// `security -i` caps a stdin line at 4 KB; MCP logins share the entry and push it past that.
    private static let interactiveLineLimit = 4032

    func read() -> Data? {
        guard let output = Self.security(["find-generic-password", "-a", account, "-s", service, "-w"]) else {
            return nil
        }
        let secret = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
        return secret.isEmpty ? nil : Data(secret.utf8)
    }

    func write(_ data: Data) -> Bool {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        if command.utf8.count <= Self.interactiveLineLimit {
            return Self.security(["-i"], input: Data(command.utf8)) != nil
        }
        return Self.security(["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex]) != nil
    }

    private static func security(_ arguments: [String], input: Data? = nil) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do {
            try process.run()
            if let input {
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }
}

/// Claude Code's refresh lock: proper-lockfile directories, `.oauth_refresh.lock` inside the config
/// directory plus the legacy `<config dir>.lock` older releases take. A holder touches its lock every
/// 5 s and one untouched for 60 s is abandoned. The tracker holds it for one request.
struct ClaudeRefreshLock {
    static let staleAfter: TimeInterval = 60

    private let held: [String]

    static func acquire(in directory: URL, attempts: Int = 6) async -> ClaudeRefreshLock? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = [
            directory.appendingPathComponent(".oauth_refresh.lock").path,
            directory.resolvingSymlinksInPath().path + ".lock"
        ]
        for attempt in 1...attempts {
            if let lock = tryAcquire(paths) { return lock }
            if attempt < attempts {
                try? await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000_000...2_000_000_000))
            }
        }
        return nil
    }

    static func tryAcquire(_ paths: [String], now: Date = Date()) -> ClaudeRefreshLock? {
        var held: [String] = []
        for path in paths {
            switch take(path, now: now) {
            case .held: held.append(path)
            case .unavailable: continue
            case .busy:
                held.reversed().forEach { _ = rmdir($0) }
                return nil
            }
        }
        return ClaudeRefreshLock(held: held)
    }

    func release() {
        held.reversed().forEach { _ = rmdir($0) }
    }

    private enum Outcome { case held, busy, unavailable }

    private static func take(_ path: String, now: Date) -> Outcome {
        if mkdir(path, 0o755) == 0 { return .held }
        guard errno == EEXIST else { return .unavailable }
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
              now.timeIntervalSince(modified) > staleAfter,
              rmdir(path) == 0, mkdir(path, 0o755) == 0
        else { return .busy }
        return .held
    }
}
