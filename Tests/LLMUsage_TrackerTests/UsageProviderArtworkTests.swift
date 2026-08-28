import Testing
@testable import LLMUsageHistory
@testable import LLMUsageUI

/// Every history provider must resolve to real artwork.
///
/// `ProviderLogoView` falls back to a generic SF Symbol when a name does not resolve, so a typo or a
/// renamed asset degrades silently into a dashed placeholder rather than failing. `iconName` exists
/// precisely to point somewhere other than `id`, which makes that easy to get wrong unnoticed.
@Test @MainActor func everyHistoryProviderResolvesToRealArtwork() {
    let providers: [any UsageHistoryProvider] = [
        ClaudeHistoryProvider(), CodexHistoryProvider(), OpenCodeHistoryProvider()
    ]
    for provider in providers {
        #expect(
            ProviderLogoLibrary.image(for: provider.iconName) != nil,
            "no artwork named \(provider.iconName) for \(provider.displayName)"
        )
    }
}

/// The Usage page deliberately uses a different mark from the quota cards: those speak about the
/// account being billed, this speaks about the CLI doing the work.
@Test @MainActor func theCliMarksAreDistinctFromTheAccountMarks() {
    #expect(ClaudeHistoryProvider().iconName != ClaudeHistoryProvider().id)
    #expect(CodexHistoryProvider().iconName != CodexHistoryProvider().id)
    // OpenCode has no separate account card, so its mark is named after the provider itself.
    #expect(OpenCodeHistoryProvider().iconName == "opencode")
    for name in ["claude", "codex", "zai", "minimax"] {
        #expect(ProviderLogoLibrary.image(for: name) != nil)
    }
}

/// The brand mark is one SVG shipped in the UI bundle; the About pane, control center header,
/// tracker panel and Dock icon all render from that single file. If it stops resolving, every
/// surface loses its logo at once — fail loudly here instead.
@Test @MainActor func theAppMarkResolvesFromItsSingleSVGSource() {
    #expect(BrandMarkLibrary.image() != nil)
}
