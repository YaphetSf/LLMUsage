import Foundation
import LLMUsagePreferences

/// What a run produced. Success requires evidence that a model completed a turn, never an exit
/// code alone. Nothing here can carry a credential, a response body or CLI output.
struct WarmUpReport: Equatable, Sendable {
    var outcome: WarmUpOutcome
    var model: String?
    var detail: String?
    var tokens: Int?

    static let cancelled = WarmUpReport(outcome: .cancelled)
    static func failed(_ reason: String, detail: String? = nil) -> WarmUpReport {
        WarmUpReport(outcome: .failed(reason), detail: detail)
    }
}

/// The evidence a client's transport could extract from a completed turn.
struct WarmUpCompletion: Equatable, Sendable {
    var model: String?
    var tokens: Int?

    static func tokenCount(_ usage: [String: Any]?, _ keys: [String]) -> Int? {
        guard let usage else { return nil }
        let counts = keys.compactMap { usage[$0] as? Int }
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }
}

struct WarmUpExecutor: Sendable {
    static let prompt = "Reply with OK only. Do not use tools or access files."

    func run(_ client: WarmUpClient, configuration: WarmUpClientConfiguration) async -> WarmUpReport {
        if Task.isCancelled { return .cancelled }
        switch client {
        case .claude, .codex: return await CLIWarmUpExecutor().run(client, configuration: configuration)
        case .glm: return await GLMWarmUpExecutor().run(configuration: configuration)
        }
    }

    static func requestedModel(_ configuration: WarmUpClientConfiguration) -> String? {
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : model
    }
}

struct GLMWarmUpExecutor: Sendable {
    var session: URLSession = .shared
    var loadKey: @Sendable () throws -> String? = GLMCredentials.load

    static func request(configuration: WarmUpClientConfiguration, key: String) throws -> URLRequest {
        var request = URLRequest(url: configuration.endpoint.url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": WarmUpExecutor.requestedModel(configuration) ?? "glm-5.3",
            "messages": [["role": "user", "content": WarmUpExecutor.prompt]],
            "max_tokens": 64,
            "reasoning_effort": "low",
            "stream": false
        ])
        return request
    }

    static func completion(_ data: Data) -> WarmUpCompletion? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["error"] == nil, let choices = root["choices"] as? [[String: Any]],
              let choice = choices.first, choice["finish_reason"] as? String == "stop",
              let message = choice["message"] as? [String: Any],
              nonempty(message["content"] as? String) != nil
        else { return nil }
        return WarmUpCompletion(model: nonempty(root["model"] as? String),
                                tokens: WarmUpCompletion.tokenCount(root["usage"] as? [String: Any], ["total_tokens"]))
    }

    func run(configuration: WarmUpClientConfiguration) async -> WarmUpReport {
        do {
            guard let key = try loadKey() else { return .failed("API key missing") }
            let request = try Self.request(configuration: configuration, key: key)
            let (data, response) = try await session.data(for: request, delegate: NoWarmUpRedirects())
            guard let http = response as? HTTPURLResponse else { return .failed("Invalid response") }
            let detail = "HTTP \(http.statusCode)"
            guard (200..<300).contains(http.statusCode) else { return .failed(detail, detail: detail) }
            guard let completion = Self.completion(data) else { return .failed("No completion", detail: detail) }
            return WarmUpReport(outcome: .succeeded,
                                model: completion.model ?? WarmUpExecutor.requestedModel(configuration),
                                detail: detail, tokens: completion.tokens)
        } catch {
            if Task.isCancelled { return .cancelled }
            // Do not persist response bodies, headers or credential-bearing diagnostics.
            if let error = error as? URLError { return .failed("Network error (\(error.code.rawValue))") }
            return .failed("Request failed")
        }
    }
}

private final class NoWarmUpRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

struct CLIWarmUpExecutor: Sendable {
    var timeout: TimeInterval = 120

    static func arguments(_ client: WarmUpClient, configuration: WarmUpClientConfiguration) -> [String] {
        var arguments: [String]
        switch client {
        case .codex:
            arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
                         "--ignore-user-config", "--color", "never", "--json"]
        case .claude:
            arguments = ["--print", "--safe-mode", "--no-session-persistence", "--tools", "",
                         "--strict-mcp-config", "--disable-slash-commands", "--output-format", "json"]
        case .glm: return []
        }
        if let model = WarmUpExecutor.requestedModel(configuration) { arguments += ["--model", model] }
        return arguments + [WarmUpExecutor.prompt]
    }

    /// Claude reports one result object; Codex streams JSONL events. Both must show a finished
    /// model turn carrying text before a run counts as successful.
    static func completion(_ client: WarmUpClient, output: Data) -> WarmUpCompletion? {
        switch client {
        case .claude:
            guard let root = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
                  root["type"] as? String == "result", root["is_error"] as? Bool == false,
                  nonempty(root["result"] as? String) != nil else { return nil }
            let models = root["modelUsage"] as? [String: [String: Any]] ?? [:]
            return WarmUpCompletion(
                model: models.max { ($0.value["costUSD"] as? Double ?? 0) < ($1.value["costUSD"] as? Double ?? 0) }?.key,
                tokens: WarmUpCompletion.tokenCount(root["usage"] as? [String: Any], ["input_tokens", "output_tokens"])
            )
        case .codex:
            var completion: WarmUpCompletion?
            var hasAnswer = false
            for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
                guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                switch event["type"] as? String {
                case "turn.started":
                    hasAnswer = false
                    completion = nil
                case "item.completed":
                    guard let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message",
                          nonempty(item["text"] as? String) != nil else { continue }
                    hasAnswer = true
                case "turn.failed", "error":
                    return nil
                case "turn.completed":
                    guard hasAnswer else { return nil }
                    completion = WarmUpCompletion(tokens: WarmUpCompletion.tokenCount(
                        event["usage"] as? [String: Any], ["input_tokens", "output_tokens"]))
                default: continue
                }
            }
            return completion
        case .glm: return nil
        }
    }

    func run(_ client: WarmUpClient, configuration: WarmUpClientConfiguration) async -> WarmUpReport {
        let cancellation = ProcessCancellation()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                runSync(client, configuration: configuration, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    private func runSync(_ client: WarmUpClient, configuration: WarmUpClientConfiguration,
                         cancellation: ProcessCancellation) -> WarmUpReport {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("llmusage-warmup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let output = folder.appendingPathComponent("output")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.currentDirectoryURL = folder
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            let path = configuration.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
            let arguments = Self.arguments(client, configuration: configuration)
            if !path.isEmpty {
                guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                    return .failed("CLI not found")
                }
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
            } else {
                // Positional argv avoids interpolating paths, models or prompts into shell code.
                // The same timeout covers shell initialization and the actual request.
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-ilc", "exec \"$@\"", "llmusage-warmup", client.rawValue] + arguments
            }
            guard try cancellation.start(process) else { return .cancelled }
            defer { cancellation.clearProcess() }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if cancellation.isCancelled || Date() >= deadline {
                    process.terminate()
                    let grace = Date().addingTimeInterval(0.2)
                    while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                    return cancellation.isCancelled ? .cancelled : .failed("Timed out")
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            process.waitUntilExit()
            if cancellation.isCancelled { return .cancelled }
            let status = process.terminationStatus
            let detail = "exit \(status)"
            guard status == 0 else {
                return .failed(status == 127 ? "CLI not found" : "CLI \(detail)", detail: detail)
            }
            let reader = try FileHandle(forReadingFrom: output)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 1_048_576) ?? Data()
            guard let completion = Self.completion(client, output: data) else {
                return .failed("No completion", detail: detail)
            }
            return WarmUpReport(outcome: .succeeded,
                                model: completion.model ?? WarmUpExecutor.requestedModel(configuration),
                                detail: detail, tokens: completion.tokens)
        } catch { return .failed("Could not start CLI") }
    }
}

private func nonempty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
}

private final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?
    var isCancelled: Bool { lock.withLock { cancelled } }
    func start(_ process: Process) throws -> Bool {
        try lock.withLock {
            guard !cancelled else { return false }
            try process.run()
            self.process = process
            return true
        }
    }
    func clearProcess() { lock.withLock { process = nil } }
    func cancel() {
        lock.withLock {
            cancelled = true
            // The helper may be terminating; do not depend on a future poll to stop the CLI.
            if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
