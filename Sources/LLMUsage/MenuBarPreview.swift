import LLMUsagePreferences
import LLMUsageUI
import SwiftUI

/// A mock macOS menu bar with LLMUsage's strip sitting in it. Every page that changes what
/// the strip looks like shows one of these, so the settings are never described in words
/// when they can be shown instead.
struct MenuBarPreview: View {
    let displayMode: MenuBarDisplayMode
    let usageDisplayMode: UsageDisplayMode
    var showsNeighbours = true

    var body: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            MenuBarStrip(
                metrics: SampleUsage.metrics(displayMode: usageDisplayMode),
                displayMode: displayMode
            )
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(0.10)))
            if showsNeighbours {
                neighbours
            }
        }
        .frame(height: 26)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.black.opacity(0.34)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Menu bar preview")
    }

    /// The system items LLMUsage would sit next to — they exist purely to give the strip a
    /// believable sense of scale.
    private var neighbours: some View {
        HStack(spacing: 11) {
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("9:41")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.42))
    }
}

/// One provider row rendered the way the menu bar panel draws it, used to preview the
/// "used vs remaining" perspective.
struct UsageRowPreview: View {
    let provider: SampleUsage.Provider
    let displayMode: UsageDisplayMode

    var body: some View {
        let session = displayMode.displayPercent(forUsed: provider.sessionUsed)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                ProviderBadge(providerID: provider.id, size: 24)
                Text(provider.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                Spacer(minLength: 8)
                Text("\(session)%")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
            }
            QuotaBar(fraction: Double(session) / 100,
                     tone: MeterTone.forUsed(provider.sessionUsed))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(provider.displayName), \(session) percent")
    }
}
