import LLMUsagePreferences
import LLMUsageUI
import SwiftUI

/// Overview = the one screen users open to see "what's my quota right now". Live provider
/// snapshots up top, tracker state + refresh cadence underneath.
struct OverviewView: View {
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var tracker: TrackerStatus
    @EnvironmentObject private var snapshots: SnapshotStore
    @EnvironmentObject private var launchAtLogin: LaunchAtLoginController
    @Environment(\.themeAccent) private var themeAccent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                providersCard
                refreshCard
                startupCard
            }
            .padding(28)
            .frame(maxWidth: 660, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onAppear {
            tracker.refresh()
            launchAtLogin.refresh()
        }
    }

    // MARK: Providers

    private var providersCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if snapshots.snapshots.isEmpty {
                placeholderProviders
            } else {
                VStack(spacing: 10) {
                    ForEach(snapshots.snapshots) { snapshot in
                        OverviewProviderRow(snapshot: snapshot)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var placeholderProviders: some View {
        VStack(spacing: 10) {
            ForEach(SampleUsage.providers, id: \.id) { provider in
                OverviewPlaceholderRow(provider: provider)
            }
        }
        .redacted(reason: .placeholder)
    }

    // MARK: Refresh

    private var refreshCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                AccentIcon("arrow.clockwise", size: 30)
                Text("Refresh")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                Spacer(minLength: 12)
            }
            SegmentedPills(
                options: RefreshFrequency.allCases,
                selection: $preferences.refreshFrequency,
                label: \.shortLabel
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: Startup

    private var startupCard: some View {
        HStack(spacing: 11) {
            AccentIcon("powerplug.fill", size: 30)
            Text("Auto start on login")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white)
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Brand.active)
            .disabled(launchAtLogin.lastError != nil)
            .accessibilityLabel("Launch the tracker at login")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

/// One row in the Overview providers list: badge, name + plan, both percentages, error
/// state if the last fetch failed.
private struct OverviewProviderRow: View {
    let snapshot: ProviderSnapshot

    private var session: MetricLine? { usage?.lines.first { $0.label == "Session" } }
    private var weekly: MetricLine? { usage?.lines.first { $0.label == "Weekly" } }
    private var usage: Usage? {
        if case .success(let u) = snapshot.result { return u }
        return nil
    }

    var body: some View {
        HStack(spacing: 14) {
            ProviderBadge(providerID: snapshot.id, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.displayName)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                subtitle
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                percentRow(label: "5h", metric: session)
                percentRow(label: "1w", metric: weekly)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var subtitle: some View {
        switch snapshot.result {
        case .success(let usage):
            if let plan = usage.plan, !plan.isEmpty {
                InfoChip { Text(plan) }
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        case .missingCredentials:
            ErrorTag(text: "Missing credentials")
        case .authExpired:
            ErrorTag(text: "Login expired")
        case .noPlan:
            ErrorTag(text: "No active plan")
        case .rateLimited:
            ErrorTag(text: "Rate limited")
        case .network(let msg):
            ErrorTag(text: msg)
        case .emptyButSuccessful:
            ErrorTag(text: "No data")
        }
    }

    @ViewBuilder
    private func percentRow(label: String, metric: MetricLine?) -> some View {
        if let percent = metric?.percent {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                Text("\(percent)%")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        } else {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                Text("—")
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Placeholder row used until the tracker writes its first snapshot bundle.
private struct OverviewPlaceholderRow: View {
    let provider: SampleUsage.Provider

    var body: some View {
        HStack(spacing: 14) {
            ProviderBadge(providerID: provider.id, size: 34)
            Text(provider.displayName)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
    }
}

private struct ErrorTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Brand.warning)
    }
}