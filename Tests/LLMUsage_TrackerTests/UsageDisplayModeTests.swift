import Foundation
import LLMUsagePreferences
import Testing

@Test func usageDisplayModeShortLabelsMatchTheirFullLabels() {
    #expect(UsageDisplayMode.remaining.shortLabel == "Full")
    #expect(UsageDisplayMode.used.shortLabel == "Empty")
}

@Test @MainActor func usageDisplayModePickerLeadsWithTheDefault() {
    #expect(UsageDisplayMode.allCases == [.remaining, .used])
    #expect(UsageDisplayMode.allCases.first == AppPreferences.defaultUsageDisplayMode)
}

@Test func displayPercentStaysInversesAcrossTheBoundary() {
    #expect(UsageDisplayMode.remaining.displayPercent(forUsed: 25) == 75)
    #expect(UsageDisplayMode.used.displayPercent(forUsed: 25) == 25)
    // Picking either side around the boundaries clamps the same way.
    #expect(UsageDisplayMode.remaining.displayPercent(forUsed: 0) == 100)
    #expect(UsageDisplayMode.remaining.displayPercent(forUsed: 100) == 0)
}
