import Charts
import LLMUsageHistory
import LLMUsageUI
import SwiftUI

/// Usage = "what have I actually burned", read from the logs the agent CLIs already keep on this
/// machine. Overview answers *how much quota is left right now*; this page answers *where it went*.
struct UsageView: View {
    @Environment(\.themeAccent) private var themeAccent
    @ObservedObject var store: UsageStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                rangeCard
                if store.everythingUninstalled {
                    emptyCard
                } else {
                    totalsCard
                    if store.hasAnyUsage { chartCard }
                    ForEach(store.results) { result in
                        ProviderHistoryCard(result: result)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 660, alignment: .leading)
        }
        .scrollIndicators(.never)
        .task { store.loadIfNeeded() }
    }

    // MARK: Range

    private var rangeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                AccentIcon("chart.bar", size: 30)
                Text("Usage")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                Spacer(minLength: 12)
                if store.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Scanning local logs")
                } else if store.range.granularity == .hour {
                    Text(store.selectedDayLabel)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(themeAccent)
                } else {
                    Text(store.range.label)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(themeAccent)
                }
            }
            SegmentedPills(
                options: UsageRange.allCases,
                selection: $store.range,
                label: \.label
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: Totals

    private var totalsCard: some View {
        let tokens = store.totalTokens
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Metric(title: "Tokens", value: UsageFormat.tokens(tokens.total))
                Metric(title: "Requests", value: UsageFormat.count(store.totalRequests))
                Spacer(minLength: 0)
            }
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 22) {
                SubMetric(title: "In", value: UsageFormat.tokens(tokens.input))
                SubMetric(title: "Out", value: UsageFormat.tokens(tokens.output))
                SubMetric(title: "Cache read", value: UsageFormat.tokens(tokens.cacheRead))
                if tokens.reasoning > 0 {
                    SubMetric(title: "Reasoning", value: UsageFormat.tokens(tokens.reasoning))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SectionLabel(store.range.granularity == .hour ? "TOKENS PER HOUR" : "TOKENS PER DAY")
                Spacer(minLength: 8)
                if store.range.granularity == .hour {
                    dayNavigator
                }
            }
            Chart(chartPoints) { point in
                BarMark(
                    x: .value(chartXLabel, point.date, unit: chartXUnit),
                    y: .value("Tokens", point.tokens)
                )
                .foregroundStyle(Brand.level)
                .cornerRadius(2)
                .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .shortened))
                .accessibilityValue("\(UsageFormat.tokens(point.tokens)) tokens")
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.07))
                    AxisValueLabel {
                        if let tokens = value.as(Int.self) {
                            Text(UsageFormat.tokens(tokens))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: chartXLabelCount)) { value in
                    // Built through a Text rather than `AxisValueLabel(format:)`: the bare format
                    // initialiser renders in the window's tint, which puts accent-coloured dates
                    // under a grey axis.
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: chartXFormat)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(height: 168)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    /// Concrete chart points fed to `Chart(...)`. Type-erased into `AnyIdentifiableDatePoint`
    /// because the bar data comes from either `dailySeries` or `hourlySeries` and Swift Charts
    /// needs a single homogeneous element type.
    private var chartPoints: [AnyUsagePoint] {
        switch store.range.granularity {
        case .day:
            store.dailySeries.map(AnyUsagePoint.day)
        case .hour:
            store.hourlySeries.map(AnyUsagePoint.hour)
        }
    }

    private var chartXLabel: String {
        store.range.granularity == .hour ? "Hour" : "Day"
    }

    private var chartXUnit: Calendar.Component {
        store.range.granularity == .hour ? .hour : .day
    }

    private var chartXLabelCount: Int {
        store.range.granularity == .hour ? 6 : 5
    }

    private var chartXFormat: Date.FormatStyle {
        store.range.granularity == .hour
            ? Date.FormatStyle().hour(.defaultDigits(amPM: .narrow))
            : Date.FormatStyle().month(.abbreviated).day()
    }

    private var dayNavigator: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    store.stepDayBackward()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(store.canStepDayBackward ? 0.75 : 0.25))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!store.canStepDayBackward)
            .accessibilityLabel("Previous day")

            Text(store.selectedDayLabel)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(themeAccent)
                .frame(minWidth: 84)
                .monospacedDigit()

            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                    store.stepDayForward()
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(store.canStepDayForward ? 0.75 : 0.25))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!store.canStepDayForward)
            .accessibilityLabel("Next day")
        }
    }

    // MARK: Empty

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No local usage logs found")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white)
            Text("This page reads the session logs the agent CLIs keep on disk. None of the tracked tools have written any on this Mac yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

// MARK: - Provider card

/// One tool's contribution: its totals, then the models it ran, biggest first.
private struct ProviderHistoryCard: View {
    let result: ProviderHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ProviderBadge(providerID: result.iconName, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.displayName)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.white)
                    subtitle
                }
                Spacer(minLength: 8)
                if let history = result.history, !history.days.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(UsageFormat.tokens(history.tokens.total))
                            .font(.system(.callout, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text("\(UsageFormat.count(history.requests)) req")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if let models = topModels, !models.isEmpty {
                Divider().overlay(Color.white.opacity(0.08))
                VStack(spacing: 8) {
                    ForEach(models, id: \.model) { model in
                        ModelRow(model: model, share: share(of: model))
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    @ViewBuilder
    private var subtitle: some View {
        switch result.outcome {
        case .scanned(let history):
            if history.days.isEmpty {
                Text("No usage in this window").font(.caption).foregroundStyle(.tertiary)
            } else {
                InfoChip { Text("\(history.days.count) active day\(history.days.count == 1 ? "" : "s")") }
            }
        case .notInstalled:
            Text("Not installed").font(.caption).foregroundStyle(.tertiary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(Brand.warning).lineLimit(2)
        }
    }

    /// Models collapsed across days, largest first. Capped because a long tail of one-request
    /// models would push the other providers off the screen.
    private var topModels: [ModelDayUsage]? {
        guard let history = result.history else { return nil }
        var merged: [String: ModelDayUsage] = [:]
        for day in history.days {
            for model in day.models {
                if var existing = merged[model.model] {
                    existing.tokens += model.tokens
                    existing.requests += model.requests
                    merged[model.model] = existing
                } else {
                    merged[model.model] = model
                }
            }
        }
        return merged.values.sorted { $0.tokens.total > $1.tokens.total }.prefix(8).map { $0 }
    }

    private func share(of model: ModelDayUsage) -> Double {
        let total = result.history?.tokens.total ?? 0
        guard total > 0 else { return 0 }
        return Double(model.tokens.total) / Double(total)
    }
}

private struct ModelRow: View {
    let model: ModelDayUsage
    let share: Double

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.model)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
                    .truncationMode(.middle)
                QuotaBar(fraction: share, tone: .standard, height: 4)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(UsageFormat.tokens(model.tokens.total))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.72))
                Text("\(UsageFormat.count(model.requests)) req")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.model)
        .accessibilityValue(
            "\(UsageFormat.tokens(model.tokens.total)) tokens, \(model.requests) requests"
        )
    }

}

// MARK: - Small pieces

private struct Metric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SubMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
        }
        .accessibilityElement(children: .combine)
    }
}

/// Type-erased chart point. The chart mixes day- and hour-bucketed series, so we wrap whichever
/// is in play behind one `Identifiable` so SwiftUI Charts gets a single element type.
enum AnyUsagePoint: Identifiable {
    case day(UsageDayPoint)
    case hour(UsageHourPoint)

    var id: Date {
        switch self {
        case .day(let point): point.id
        case .hour(let point): point.id
        }
    }

    var date: Date { id }

    var tokens: Int {
        switch self {
        case .day(let point): point.tokens
        case .hour(let point): point.tokens
        }
    }
}
