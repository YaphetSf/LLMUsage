import Foundation
import LLMUsagePreferences
import Testing
@testable import LLMUsage_Tracker

/// The per-account tracking switch: an account turned off in the control center leaves the
/// fetch loop, the popover, and the menu bar strip, and its Overview row survives so it can
/// be turned back on.
@MainActor
struct ProviderTrackingTests {
    @Test func registryListsEveryProviderTheTrackerPolls() {
        let providers: [any UsageProvider] = [
            ClaudeProvider(), CodexProvider(), ZAIProvider(), MiniMaxProvider()
        ]
        #expect(Set(KnownProvider.allCases.map(\.id)) == Set(providers.map(\.id)))
        #expect(KnownProvider.allCases.count == 4)
        #expect(KnownProvider(rawValue: "zai")?.displayName == "GLM")
    }

    @Test func disabledProviderIDsRoundTripThroughDefaults() {
        let original = AppPreferences.disabledProviderIDs
        defer { AppPreferences.disabledProviderIDs = original }

        AppPreferences.disabledProviderIDs = ["minimax"]
        #expect(AppPreferences.disabledProviderIDs == ["minimax"])

        AppPreferences.disabledProviderIDs = []
        #expect(AppPreferences.disabledProviderIDs.isEmpty)
    }
}
