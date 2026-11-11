import Foundation
import LLMUsageHistory
import LLMUsagePreferences
import LLMUsageRemote
import Testing
@testable import LLMUsage_Tracker

private final class HubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (Int, Data) = (503, Data())
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.response.0,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct RemoteUsageClientTests {
    private func fixture() throws -> (RemoteUsageClient, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = directory.appendingPathComponent("test-key")
        try "test-device-key\n".write(to: key, atomically: true, encoding: .utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HubProtocol.self]
        HubProtocol.requests = []
        return (RemoteUsageClient(configuration: RuntimeConfiguration(
            role: .client, serverURL: URL(string: "http://server.test:9091")!, keyFile: key.path
        ), session: URLSession(configuration: configuration), cacheDirectory: directory), directory)
    }

    @Test func quotaDecodesTheExistingServerExportAndAuthenticates() async throws {
        let (client, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        HubProtocol.response = (200, try UsageExport.data([
            ProviderSnapshot(id: "claude", displayName: "Claude", result: .success(Usage(
                plan: "Max", lines: [MetricLine(label: "Session", percent: 37,
                    resetsAt: now.addingTimeInterval(3600), windowIsActive: true)]
            ))),
            ProviderSnapshot(id: "codex", displayName: "Codex", result: .authExpired)
        ], at: now))
        let document = try await client.quota()
        #expect(document.updatedAt == now)
        #expect(document.snapshots.map(\.id) == ["claude", "codex"])
        if case .success(let usage) = document.snapshots[0].result {
            #expect(usage.lines[0].percent == 37)
            #expect(usage.lines[0].windowIsActive == true)
        } else { Issue.record("Expected successful quota") }
        #expect(HubProtocol.requests.first?.url?.path == "/api/usage")
        #expect(HubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-device-key")
        #expect(client.cachedQuota()?.updatedAt == now)

        HubProtocol.response = (403, Data())
        await #expect(throws: RemoteUsageError.self) { try await client.quota() }
        #expect(client.cachedQuota()?.updatedAt == now)
        #expect(HubProtocol.requests.count == 2)
    }

    @Test func historyUsesThePublishedServerSnapshotAndKeepsItOffline() async throws {
        let (client, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = UsageHistorySnapshot(generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            daysBack: 90, timeZoneIdentifier: "Europe/London", results: [
                ProviderHistory(id: "claude", displayName: "Claude", iconName: "terminal", outcome: .notInstalled)
            ])
        let export = directory.appendingPathComponent("server-history.json")
        try UsageHistoryExport.write(snapshot, to: export)
        HubProtocol.response = (200, try Data(contentsOf: export))
        #expect(try await client.refresh(daysBack: 90, now: Date(), timeZone: .current) == snapshot)
        #expect(HubProtocol.requests.first?.url?.path == "/api/usage/history")
        HubProtocol.response = (503, Data())
        await #expect(throws: RemoteUsageError.self) {
            try await client.refresh(daysBack: 90, now: Date(), timeZone: .current)
        }
        #expect(await client.cachedSnapshot(timeZone: .current) == snapshot)
    }

    @Test func anUnconfiguredClientCannotFallBackToLocalCollection() async {
        let client = RemoteUsageClient(configuration: RuntimeConfiguration(role: .client))
        await #expect(throws: RemoteUsageError.self) { try await client.quota() }
        await #expect(throws: RemoteUsageError.self) {
            try await client.refresh(daysBack: 90, now: Date(), timeZone: .current)
        }
    }

    @Test func duplicateProviderIDsCannotReplaceTheCache() async throws {
        let (client, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ProviderSnapshot(id: "claude", displayName: "Claude", result: .missingCredentials)
        HubProtocol.response = (200, try UsageExport.data([provider, provider], at: Date()))
        await #expect(throws: RemoteUsageError.self) { try await client.quota() }
        #expect(client.cachedQuota() == nil)
    }
}
