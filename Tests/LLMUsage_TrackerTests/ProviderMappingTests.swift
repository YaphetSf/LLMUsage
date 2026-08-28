import AppKit
import Foundation
import LLMUsagePreferences
import LLMUsageUI
import SwiftUI
import Testing
@testable import LLMUsage_Tracker

@Test @MainActor func providerLogoAssetsLoad() {
    for providerID in ["claude", "codex", "zai", "minimax"] {
        #expect(ProviderLogoLibrary.image(for: providerID) != nil)
    }
}

@Test @MainActor func verticalRectangleStatusStripStaysCompact() {
    let metrics = [
        StatusMetric(id: "claude", displayName: "Claude", value: "100%", percent: 100),
        StatusMetric(id: "codex", displayName: "Codex", value: "56%", percent: 56),
        StatusMetric(id: "zai", displayName: "GLM", value: "28%", percent: 28)
    ]
    let image = StatusStripRenderer.image(metrics: metrics)

    #expect(image != nil)
    #expect((image?.size.width ?? 90) < 90)
}

@Test @MainActor func menuBarRendererSupportsAllThreeDisplayModes() {
    let metrics = [
        StatusMetric(
            id: "claude",
            displayName: "Claude",
            value: "7%",
            secondaryValue: "31%",
            percent: 93
        )
    ]

    for mode in MenuBarDisplayMode.allCases {
        #expect(StatusStripRenderer.image(metrics: metrics, displayMode: mode) != nil)
    }
    #expect(MenuBarDisplayMode.allCases == [.sessionNumber, .sessionAndWeeklyNumbers, .capacity])
}

@Test @MainActor func capacityAlwaysRendersAsTemplateImage() {
    let healthy = [StatusMetric(id: "claude", displayName: "Claude", value: "7%", percent: 93)]
    let warning = [StatusMetric(id: "claude", displayName: "Claude", value: "80%", percent: 20)]
    let blocked = [StatusMetric(
        id: "claude",
        displayName: "Claude",
        value: "0%",
        percent: 100,
        sessionBlockedByWeeklyLimit: true
    )]

    for metrics in [healthy, warning, blocked] {
        #expect(StatusStripRenderer.image(metrics: metrics, displayMode: .capacity)?.isTemplate == true)
    }
    #expect(StatusStripRenderer.image(metrics: warning, displayMode: .sessionNumber)?.isTemplate == true)
}

@Test func usageDisplayModeProjectsFullAndEmptyPercentages() {
    #expect(UsageDisplayMode.remaining.label == "Glass Half Full")
    #expect(UsageDisplayMode.used.label == "Glass Half Empty")
    #expect(UsageDisplayMode.used.displayPercent(forUsed: 7) == 7)
    #expect(UsageDisplayMode.remaining.displayPercent(forUsed: 7) == 93)
    #expect(UsageDisplayMode.remaining.displayPercent(forUsed: -5) == 100)
    #expect(UsageDisplayMode.remaining.displayPercent(forUsed: 105) == 0)
    #expect(VerticalUsageMeter.filledPercent(forUsed: 7) == 93)
    #expect(VerticalUsageMeter.filledPercent(forUsed: -5) == 100)
    #expect(VerticalUsageMeter.filledPercent(forUsed: 105) == 0)
}

@Test func capacityMeterToneUsesRemainingQuotaThresholds() {
    #expect(MeterTone.forRemaining( 100) == .standard)
    #expect(MeterTone.forRemaining( 26) == .standard)
    #expect(MeterTone.forRemaining( 25) == .warning)
    #expect(MeterTone.forRemaining( 11) == .warning)
    #expect(MeterTone.forRemaining( 10) == .critical)
    #expect(MeterTone.forRemaining( 0) == .critical)
}

@Test func exhaustedWeeklyQuotaBlocksOnlyAnOtherwiseAvailableSession() {
    #expect(QuotaRelationship.sessionIsBlockedByWeeklyLimit(
        sessionUsedPercent: 20,
        weeklyUsedPercent: 100
    ))
    #expect(!QuotaRelationship.sessionIsBlockedByWeeklyLimit(
        sessionUsedPercent: 100,
        weeklyUsedPercent: 100
    ))
    #expect(!QuotaRelationship.sessionIsBlockedByWeeklyLimit(
        sessionUsedPercent: 20,
        weeklyUsedPercent: 99
    ))
    #expect(!QuotaRelationship.sessionIsBlockedByWeeklyLimit(
        sessionUsedPercent: 20,
        weeklyUsedPercent: nil
    ))
}

@Test @MainActor func blockedSessionRendersInEveryModeAndExplainsItForAccessibility() {
    let metric = StatusMetric(
        id: "claude",
        displayName: "Claude",
        value: "20%",
        secondaryValue: "100%",
        percent: 80,
        sessionBlockedByWeeklyLimit: true
    )

    for mode in MenuBarDisplayMode.allCases {
        #expect(StatusStripRenderer.image(metrics: [metric], displayMode: mode) != nil)
    }
    #expect(metric.accessibilitySummary.contains("blocked by exhausted weekly quota"))
}

@Test @MainActor func blockedCapacityUsesSameSizedDashedRectangle() {
    let available = StatusMetric(
        id: "claude",
        displayName: "Claude",
        value: "0%",
        percent: 100
    )
    let blocked = StatusMetric(
        id: "claude",
        displayName: "Claude",
        value: "0%",
        percent: 100,
        sessionBlockedByWeeklyLimit: true
    )
    let availableImage = StatusStripRenderer.image(metrics: [available], displayMode: .capacity)
    let blockedImage = StatusStripRenderer.image(metrics: [blocked], displayMode: .capacity)

    #expect(blockedImage?.size.width == availableImage?.size.width)
    #expect(blockedImage?.size.height == availableImage?.size.height)
}

@Test func refreshFrequencyProvidesPersistableIntervalValues() {
    #expect(RefreshFrequency.allCases.map(\.rawValue) == [60, 300, 900, 1800])
    #expect(RefreshFrequency.every5Minutes.interval == 300)
    #expect(RefreshFrequency.everyMinute.label == "Every minute")
    #expect(RefreshFrequency.every30Minutes.label == "Every 30 minutes")
    #expect(RefreshFrequency.everyMinute.interval == 60)
}

@Test func resetCountdownUsesCompactUnits() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    #expect(ResetCountdownText.compact(
        until: now.addingTimeInterval(4 * 3_600 + 10 * 60),
        now: now
    ) == "4h10m")
    #expect(ResetCountdownText.compact(
        until: now.addingTimeInterval(6 * 86_400 + 13 * 3_600),
        now: now
    ) == "6d13h")
    #expect(ResetCountdownText.compact(until: now.addingTimeInterval(45), now: now) == "1m")
    #expect(ResetCountdownText.compact(until: now, now: now) == "Now")
    #expect(ResetCountdownText.accessibilityLabel(
        until: now.addingTimeInterval(4 * 3_600 + 10 * 60),
        now: now
    ) == "Resets in 4 hours, 10 minutes")
}

@Test func resetRefreshScheduleChoosesNearestFutureReset() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let expired = now.addingTimeInterval(-60)
    let nearest = now.addingTimeInterval(30)
    let later = now.addingTimeInterval(300)
    let snapshots = [
        ProviderSnapshot(
            id: "first",
            displayName: "First",
            result: .success(Usage(plan: nil, lines: [
                MetricLine(label: "Expired", percent: 0, text: nil, resetsAt: expired),
                MetricLine(label: "Later", percent: 0, text: nil, resetsAt: later)
            ]))
        ),
        ProviderSnapshot(
            id: "second",
            displayName: "Second",
            result: .success(Usage(plan: nil, lines: [
                MetricLine(label: "Nearest", percent: 0, text: nil, resetsAt: nearest)
            ]))
        ),
        ProviderSnapshot(id: "failed", displayName: "Failed", result: .network("offline"))
    ]

    #expect(UsageResetRefreshSchedule.nextRefreshDate(for: snapshots, now: now)
        == nearest.addingTimeInterval(1))
    #expect(UsageResetRefreshSchedule.nextRefreshDate(
        for: [snapshots[0]],
        now: later.addingTimeInterval(1)
    ) == nil)
}

@Test func claudeMapsUsageWindows() throws {
    let usage = try ClaudeProvider.mapResponse(Data(#"""
    {
      "five_hour":{"utilization":7.4,"resets_at":"2026-08-26T12:00:00Z"},
      "seven_day":{"utilization":42,"resets_at":"2026-08-30T12:00:00.000Z"},
      "seven_day_sonnet":null
    }
    """#.utf8), plan: "Max 20x")

    #expect(usage.plan == "Max 20x")
    #expect(usage.lines.map(\.label) == ["Session", "Weekly"])
    #expect(usage.lines.map(\.percent) == [7, 42])
    #expect(usage.lines.allSatisfy { $0.resetsAt != nil })
}

@Test func codexClassifiesWeeklyWindowInPrimarySlot() throws {
    let usage = try CodexProvider.mapResponse(Data(#"""
    {
      "plan_type":"prolite",
      "rate_limit":{"primary_window":{"used_percent":49,"limit_window_seconds":604800,"reset_after_seconds":60}},
      "credits":{"balance":"100"}
    }
    """#.utf8), now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(usage.plan == "Pro 5x")
    #expect(usage.lines.map(\.label) == ["Weekly"])
    #expect(usage.lines.map(\.percent) == [49])
}

@Test func zaiMapsCurrentCreditLimits() throws {
    let quota = Data(#"""
    {
      "success":true,
      "data":{"limits":[
        {"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":7,"nextResetTime":1787760000000},
        {"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":31,"nextResetTime":1788364800000}
      ]}
    }
    """#.utf8)
    let plan = Data(#"{"data":[{"productName":"GLM Coding Lite"}]}"#.utf8)
    let usage = try ZAIProvider.mapResponse(quota, subscriptionData: plan)

    #expect(usage.plan == "GLM Coding Lite")
    #expect(usage.lines.map(\.label) == ["Session", "Weekly"])
    #expect(usage.lines.map(\.percent) == [7, 31])
}

@Test func zaiEmptySuccessfulResponseCarriesRawJSON() {
    let raw = #"{"success":true,"data":{"limits":[]}}"#
    do {
        _ = try ZAIProvider.mapResponse(Data(raw.utf8))
        Issue.record("Expected emptyButSuccessful")
    } catch let error as UsageError {
        #expect(error == .emptyButSuccessful(raw: raw))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func zaiNoPlanIsDistinct() {
    let raw = #"{"success":false,"code":500,"msg":"no coding plan"}"#
    #expect(throws: UsageError.noPlan) {
        try ZAIProvider.mapResponse(Data(raw.utf8))
    }
}

@Test func minimaxTokenPlanMapsSessionAndWeekly() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let endTime = (now.addingTimeInterval(3 * 3_600).timeIntervalSince1970 * 1000)
    let weeklyEndTime = (now.addingTimeInterval(5 * 86_400 + 6 * 3_600).timeIntervalSince1970 * 1000)
    let body = Data(String(format: #"""
    {
      "model_remains": [
        {
          "model_name": "MiniMax-M3",
          "start_time": 0,
          "end_time": %.0f,
          "remains_time": 10800000,
          "current_interval_total_count": 100,
          "current_interval_usage_count": 23,
          "current_interval_remaining_percent": 77,
          "current_weekly_total_count": 1000,
          "current_weekly_usage_count": 312,
          "current_weekly_remaining_percent": 68,
          "weekly_start_time": 0,
          "weekly_end_time": %.0f,
          "weekly_remains_time": 453600000
        }
      ]
    }
    """#, endTime, weeklyEndTime).utf8)

    let usage = try MiniMaxProvider.mapResponse(body, kind: .tokenPlan, httpStatus: 200, now: now)

    #expect(usage.plan == "Token Plan")
    #expect(usage.lines.map(\.label) == ["Session", "Weekly"])
    #expect(usage.lines.map(\.percent) == [23, 32])
    #expect(usage.lines.allSatisfy { $0.resetsAt != nil })
}

@Test func minimaxTokenPlanAppliesWeeklyBoostMultiplier() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let endTime = now.addingTimeInterval(3_600).timeIntervalSince1970 * 1000
    let weeklyEndTime = now.addingTimeInterval(86_400).timeIntervalSince1970 * 1000
    let body = Data(String(format: #"""
    {
      "model_remains": [
        {
          "model_name": "MiniMax-M3",
          "start_time": 0,
          "end_time": %.0f,
          "remains_time": 3600000,
          "current_interval_total_count": 100,
          "current_interval_usage_count": 20,
          "current_interval_remaining_percent": 80,
          "current_weekly_total_count": 1000,
          "current_weekly_usage_count": 100,
          "current_weekly_remaining_percent": 90,
          "weekly_boost_permille": 1500,
          "weekly_start_time": 0,
          "weekly_end_time": %.0f,
          "weekly_remains_time": 86400000
        }
      ]
    }
    """#, endTime, weeklyEndTime).utf8)

    let usage = try MiniMaxProvider.mapResponse(body, kind: .tokenPlan, httpStatus: 200, now: now)
    let session = usage.lines.first { $0.label == "Session" }
    let weekly = usage.lines.first { $0.label == "Weekly" }

    #expect(session?.percent == 20)
    // 90% remaining × 1.5 boost = 135%, clamped to 100% → 0% used.
    #expect(weekly?.percent == 0)
}

@Test func minimaxTokenPlanTrustsPercentWhenTotalIsZero() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let endTime = (now.addingTimeInterval(3_600).timeIntervalSince1970 * 1000)
    let weeklyEndTime = (now.addingTimeInterval(86_400).timeIntervalSince1970 * 1000)
    let body = Data(String(format: #"""
    {
      "model_remains": [
        {
          "model_name": "general",
          "start_time": 0,
          "end_time": %.0f,
          "remains_time": 3600000,
          "current_interval_total_count": 0,
          "current_interval_usage_count": 0,
          "current_interval_remaining_percent": 88,
          "current_interval_status": 1,
          "current_weekly_total_count": 0,
          "current_weekly_usage_count": 0,
          "current_weekly_remaining_percent": 98,
          "current_weekly_status": 1,
          "weekly_start_time": 0,
          "weekly_end_time": %.0f,
          "weekly_remains_time": 86400000
        },
        {
          "model_name": "video",
          "start_time": 0,
          "end_time": %.0f,
          "remains_time": 3600000,
          "current_interval_total_count": 0,
          "current_interval_usage_count": 0,
          "current_interval_remaining_percent": 100,
          "current_interval_status": 3,
          "current_weekly_total_count": 0,
          "current_weekly_usage_count": 0,
          "current_weekly_remaining_percent": 100,
          "current_weekly_status": 3,
          "weekly_start_time": 0,
          "weekly_end_time": %.0f,
          "weekly_remains_time": 86400000
        }
      ]
    }
    """#, endTime, weeklyEndTime, endTime, weeklyEndTime).utf8)

    let usage = try MiniMaxProvider.mapResponse(body, kind: .tokenPlan, httpStatus: 200, now: now)

    // Only the "limited" general model should be rendered; the unlimited video bucket is dropped.
    #expect(usage.plan == "Token Plan")
    #expect(usage.lines.map(\.label) == ["Session", "Weekly"])
    #expect(usage.lines.map(\.percent) == [12, 2])
}

@Test func minimaxEmptyTokenPlanSurfacesEmptyButSuccessful() {
    let raw = #"{"model_remains":[],"base_resp":{"status_code":0}}"#
    do {
        _ = try MiniMaxProvider.mapResponse(
            Data(raw.utf8),
            kind: .tokenPlan,
            httpStatus: 200
        )
        Issue.record("Expected emptyButSuccessful")
    } catch let error as UsageError {
        #expect(error == .emptyButSuccessful(raw: raw))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func minimaxNonZeroBaseRespIsRegionMismatch() {
    let raw = #"{"model_remains":[],"base_resp":{"status_code":2049,"status_msg":"wrong region"}}"#
    do {
        _ = try MiniMaxProvider.mapResponse(Data(raw.utf8), kind: .tokenPlan, httpStatus: 200)
        Issue.record("Expected regionMismatch")
    } catch let error as UsageError {
        #expect(error == .regionMismatch)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func minimaxPayAsYouGoReportsCreditsUsage() throws {
    let body = Data(#"""
    {
      "available_amount": "25.00",
      "cash_balance": "20.00",
      "voucher_balance": "10.00",
      "credit_balance": "70.00"
    }
    """#.utf8)

    let usage = try MiniMaxProvider.mapResponse(body, kind: .payAsYouGo, httpStatus: 200)

    #expect(usage.plan == "Pay-as-you-go")
    #expect(usage.lines.map(\.label) == ["Credits"])
    #expect(usage.lines.first?.text == "25.00")
    // 75% used of 100 total.
    #expect(usage.lines.first?.percent == 75)
}

@Test @MainActor func panelMeasuresToAFiniteHeightForAnyProviderCount() {
    // The panel sizes the popover, and `NSPopover` aborts the process on a non-finite frame,
    // so an unbounded measurement here is a crash on the next menu bar click.
    for count in 0...4 {
        let providers = (0..<count).map { index in
            ProviderCardState(
                id: "claude",
                displayName: "Provider \(index)",
                snapshot: ProviderSnapshot(
                    id: "claude",
                    displayName: "Provider \(index)",
                    result: .success(Usage(plan: "Max", lines: [
                        MetricLine(label: "Session", percent: 40, text: nil,
                                   resetsAt: Date().addingTimeInterval(3_600)),
                        MetricLine(label: "Weekly", percent: 70, text: nil, resetsAt: nil)
                    ]))
                )
            )
        }
        let controller = NSHostingController(rootView: UsageDashboardView(
            providers: providers,
            displayMode: .remaining,
            isRefreshing: false,
            onRefresh: {},
            onOpenSettings: {},
            onQuit: {}
        ))
        let size = controller.sizeThatFits(in: NSSize(
            width: UsageDashboardView.width,
            height: UsageDashboardView.maxHeight
        ))

        #expect(size.height.isFinite)
        #expect(size.height > 0)
        #expect(size.height <= UsageDashboardView.maxHeight)
    }
}

@Test func capacityBarFillFollowsTheUsageDisplayMode() {
    let snapshot = ProviderSnapshot(
        id: "zai",
        displayName: "GLM",
        result: .success(Usage(plan: nil, lines: [
            MetricLine(label: "Session", percent: 40, text: nil, resetsAt: nil),
            MetricLine(label: "Weekly", percent: 70, text: nil, resetsAt: nil)
        ]))
    )

    // Glass Half Full drains toward empty; Glass Half Empty fills toward full.
    #expect(AppDelegate.compactPresentation(for: snapshot, displayMode: .remaining).percent == 60)
    #expect(AppDelegate.compactPresentation(for: snapshot, displayMode: .used).percent == 40)
}
