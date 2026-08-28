import AppKit
import LLMUsagePreferences
import LLMUsageUI
import SwiftUI

struct ProviderCardState: Identifiable {
    let id: String
    let displayName: String
    let snapshot: ProviderSnapshot?
}

/// The menu bar panel. It sits on the same ambient canvas as the control center window, so
/// dropping the strip open feels like opening a small window of the same app rather than a
/// system menu that happens to contain numbers.
struct UsageDashboardView: View {
    let providers: [ProviderCardState]
    let displayMode: UsageDisplayMode
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    static let width: CGFloat = 384
    /// Ceiling handed to the layout when measuring the panel — finite so an unbounded
    /// proposal can never reach `NSWindow`.
    static let maxHeight: CGFloat = 900

    /// The popover lives in the tracker process, outside the control center's view tree, so
    /// the user's accent is read straight from the shared defaults instead of the environment.
    /// Re-read whenever preferences change so a theme switch in the control center is picked
    /// up live.
    @State private var themeAccent = color(for: AppPreferences.accentChoice)

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 14) {
                ForEach(providers) { provider in
                    ProviderCard(
                        provider: provider,
                        displayMode: displayMode,
                        isRefreshing: isRefreshing
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            footer
        }
        .frame(width: Self.width)
        .background(AmbientBackground(.popover))
        .environment(\.colorScheme, .dark)
        .environment(\.themeAccent, themeAccent)
        .onReceive(DistributedNotificationCenter.default().publisher(
            for: AppPreferences.didChangeNotification
        )) { _ in
            themeAccent = color(for: AppPreferences.accentChoice)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            LLMUsageMark()
                .frame(width: 22, height: 22)
            Wordmark(size: 15)
            Spacer(minLength: 8)
            Text(displayMode == .remaining ? "REMAINING" : "USED")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .tracking(0.8)
        }
        .padding(.horizontal, 18)
        .padding(.top, 15)
        .padding(.bottom, 13)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(GlassIconButtonStyle())
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings")
            .accessibilityLabel("Settings")

            Spacer(minLength: 0)

            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 30, height: 30)
                    .accessibilityLabel("Refreshing usage")
            } else {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("Refresh all providers")
                .accessibilityLabel("Refresh all providers")
            }

            Button(action: onQuit) {
                Image(systemName: "power")
            }
            .buttonStyle(GlassIconButtonStyle())
            .help("Quit")
            .accessibilityLabel("Quit")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
    }
}

// MARK: - Provider card

private struct ProviderCard: View {
    let provider: ProviderCardState
    let displayMode: UsageDisplayMode
    let isRefreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(corner: 15)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(provider.displayName)
    }

    private var header: some View {
        HStack(spacing: 9) {
            ProviderBadge(providerID: provider.id, size: 26)
            Text(provider.displayName)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if case .success(let usage) = provider.snapshot?.result, let plan = usage.plan {
                InfoChip { Text(plan) }
                    .lineLimit(1)
            }
            if provider.id == "zai", case .success = provider.snapshot?.result {
                ZAIOffPeakBadge()
            }
            Spacer(minLength: 6)
            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Refreshing \(provider.displayName)")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = provider.snapshot {
            switch snapshot.result {
            case .success(let usage) where usage.lines.isEmpty:
                Text("No usage metrics returned")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .success(let usage):
                VStack(spacing: 13) {
                    ForEach(Array(usage.lines.enumerated()), id: \.offset) { _, line in
                        MetricRow(line: line, displayMode: displayMode)
                    }
                }
            case .emptyButSuccessful:
                ProviderErrorRow(error: UsageError.emptyButSuccessful(raw: ""), providerID: provider.id)
            case .missingCredentials:
                ProviderErrorRow(error: UsageError.missingCredentials, providerID: provider.id)
            case .authExpired:
                ProviderErrorRow(error: UsageError.authExpired, providerID: provider.id)
            case .noPlan:
                ProviderErrorRow(error: UsageError.noPlan, providerID: provider.id)
            case .rateLimited(let retry):
                ProviderErrorRow(error: UsageError.rateLimited(retryAfter: retry), providerID: provider.id)
            case .network(let text):
                ProviderErrorRow(error: UsageError.network(text), providerID: provider.id)
            }
        } else {
            VStack(spacing: 13) {
                MetricRow(line: MetricLine(label: "Session", percent: 62, text: nil, resetsAt: nil),
                          displayMode: displayMode)
                MetricRow(line: MetricLine(label: "Weekly", percent: 38, text: nil, resetsAt: nil),
                          displayMode: displayMode)
            }
            .redacted(reason: .placeholder)
            .accessibilityLabel("Loading usage")
        }
    }
}

private struct MetricRow: View {
    let line: MetricLine
    let displayMode: UsageDisplayMode
    @Environment(\.themeAccent) private var themeAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let percent = line.percent {
                let displayPercent = displayMode.displayPercent(forUsed: percent)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                    if let resetsAt = line.resetsAt {
                        ResetCountdownLabel(resetsAt: resetsAt)
                    }
                    Spacer(minLength: 8)
                    Text("\(displayPercent)%")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(valueStyle(usedPercent: percent))
                }
                QuotaBar(fraction: Double(displayPercent) / 100,
                         tone: MeterTone.forUsed(percent))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer(minLength: 8)
                    Text(line.text ?? "—")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The number itself only takes on a tone once a quota is actually running low; the rest
    /// of the time it stays plain white so a glance at the panel finds the warnings.
    private func valueStyle(usedPercent: Int) -> AnyShapeStyle {
        switch MeterTone.forUsed(usedPercent) {
        case .standard: AnyShapeStyle(Color.white)
        case .warning: AnyShapeStyle(Brand.warning)
        case .critical: AnyShapeStyle(Brand.critical)
        }
    }
}

/// The countdown rides bare next to its label rather than in a capsule: it sits on the same
/// line as the quota name, and a pill around it read as a second badge competing with the
/// plan chip in the card header.
private struct ResetCountdownLabel: View {
    let resetsAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 3) {
                Image(systemName: "hourglass")
                Text(ResetCountdownText.compact(until: resetsAt, now: context.date))
                    .monospacedDigit()
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ResetCountdownText.accessibilityLabel(until: resetsAt,
                                                                     now: context.date))
        }
    }
}

/// Z.ai's off-peak rate indicator on the GLM card: a moon and the credit multiplier while
/// the half rate is in force, nothing during peak hours. Rides bare after the plan chip for
/// the same reason as the reset countdown — a second pill would compete with it.
private struct ZAIOffPeakBadge: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if case .offPeak = ZAIOffPeak.period(at: context.date) {
                HStack(spacing: 3) {
                    Image(systemName: "moon.fill")
                    Text("0.5×")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Off-peak, credits charged at half rate")
            }
        }
    }
}

private struct ProviderErrorRow: View {
    let error: UsageError
    let providerID: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Brand.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(errorTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(errorMessage(error, providerID: providerID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Brand.warning.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Brand.warning.opacity(0.25), lineWidth: 1))
        .help(rawResponse ?? errorMessage(error, providerID: providerID))
        .accessibilityElement(children: .combine)
    }

    private var errorTitle: String {
        if case .emptyButSuccessful = error {
            switch providerID {
            case "zai": return "Empty response from Z.ai"
            case "minimax": return "Empty response from MiniMax"
            default: return "Empty response"
            }
        }
        return "Usage unavailable"
    }

    private var rawResponse: String? {
        if case .emptyButSuccessful(let raw) = error { return raw }
        return nil
    }
}

// MARK: - Countdown text

enum ResetCountdownText {
    static func compact(until resetsAt: Date, now: Date) -> String {
        let components = components(until: resetsAt, now: now)
        guard !components.isExpired else { return "Now" }

        if components.days > 0 {
            return components.hours > 0
                ? "\(components.days)d\(components.hours)h"
                : "\(components.days)d"
        }
        if components.hours > 0 {
            return components.minutes > 0
                ? "\(components.hours)h\(components.minutes)m"
                : "\(components.hours)h"
        }
        return "\(components.minutes)m"
    }

    static func accessibilityLabel(until resetsAt: Date, now: Date) -> String {
        let components = components(until: resetsAt, now: now)
        guard !components.isExpired else { return "Reset now" }

        let values: [(Int, String)]
        if components.days > 0 {
            values = [(components.days, "day"), (components.hours, "hour")]
        } else if components.hours > 0 {
            values = [(components.hours, "hour"), (components.minutes, "minute")]
        } else {
            values = [(components.minutes, "minute")]
        }
        let duration = values
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
            .joined(separator: ", ")
        return "Resets in \(duration)"
    }

    private static func components(until resetsAt: Date, now: Date) -> (
        days: Int,
        hours: Int,
        minutes: Int,
        isExpired: Bool
    ) {
        let interval = resetsAt.timeIntervalSince(now)
        guard interval > 0 else { return (0, 0, 0, true) }

        let totalMinutes = max(1, Int(ceil(interval / 60)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        return (days, hours, minutes, false)
    }
}

private func errorMessage(_ error: UsageError, providerID: String) -> String {
    switch error {
    case .missingCredentials: "Missing credentials"
    case .authExpired where providerID == "claude": "Run claude to refresh the login"
    case .authExpired where providerID == "codex": "Run codex to refresh the login"
    case .authExpired: "API key invalid"
    case .network(let text): text
    case .noPlan where providerID == "zai": "No active GLM Coding Plan"
    case .noPlan where providerID == "minimax": "No active Token Plan on this key"
    case .noPlan: "No active plan"
    case .regionMismatch: "Region mismatch"
    case .rateLimited(let retryAfter):
        if let retryAfter { "Rate limited — retry in \(retryAfter)s" }
        else { "Rate limited" }
    case .emptyButSuccessful: "The API succeeded but returned no limits. Hover to inspect the raw JSON."
    }
}
