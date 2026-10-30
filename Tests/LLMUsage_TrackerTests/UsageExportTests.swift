import Foundation
import LLMUsagePreferences
import Testing
@testable import LLMUsage_Tracker

/// The hub serves `usage.json` to the phone verbatim, so its field names are the wire.
struct UsageExportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func successAndFailureSnapshotsKeepTheirWireShape() throws {
        let reset = now.addingTimeInterval(3600)
        let snapshots = [
            ProviderSnapshot(id: "claude", displayName: "Claude", result: .success(Usage(plan: "Max 20x", lines: [
                MetricLine(label: "Session", percent: 37, resetsAt: reset, windowIsActive: true),
                MetricLine(label: "Credits", text: "$4.20"),
            ]))),
            ProviderSnapshot(id: "codex", displayName: "Codex", result: .missingCredentials),
        ]

        let data = try UsageExport.data(snapshots, at: now)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(root["updated_at"] as? String == "2027-01-15T08:00:00Z")
        let providers = try #require(root["providers"] as? [[String: Any]])
        #expect(providers.map { $0["id"] as? String } == ["claude", "codex"])

        let claude = providers[0]
        #expect(claude["name"] as? String == "Claude")
        #expect(claude["plan"] as? String == "Max 20x")
        #expect(claude["error"] == nil)
        let lines = try #require(claude["lines"] as? [[String: Any]])
        #expect(lines[0]["label"] as? String == "Session")
        #expect(lines[0]["used_percent"] as? Int == 37)
        #expect(lines[0]["resets_at"] as? String == "2027-01-15T09:00:00Z")
        #expect(lines[0]["window_is_active"] as? Bool == true)
        #expect(lines[1]["text"] as? String == "$4.20")
        #expect(lines[1]["used_percent"] == nil)

        let codex = providers[1]
        #expect(codex["error"] as? String == "Missing credentials")
        #expect((codex["lines"] as? [Any])?.isEmpty == true)
    }

    @Test func writeReplacesTheFileAtomically() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("usage.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try UsageExport.write([], at: now, to: url)
        try UsageExport.write([ProviderSnapshot(id: "zai", displayName: "GLM", result: .noPlan)], at: now, to: url)

        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((root["providers"] as? [[String: Any]])?.first?["error"] as? String == "No active plan")
    }
}
