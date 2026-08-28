import LLMUsagePreferences
import LLMUsageUI
import SwiftUI

/// What the strip in the menu bar looks like. Every option is a card that draws itself, so
/// picking one is a matter of looking rather than reading.
struct MenuBarSettingsView: View {
    @EnvironmentObject private var preferences: Preferences
    @Environment(\.themeAccent) private var themeAccent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader("Menu Bar")
                modes
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .scrollIndicators(.never)
        .tint(themeAccent)
        .animation(.spring(response: 0.36, dampingFraction: 0.85),
                   value: preferences.usageDisplayMode)
    }

    private var modes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                SectionLabel("DISPLAY")
                Spacer(minLength: 12)
                SegmentedPills(
                    options: UsageDisplayMode.allCases,
                    selection: $preferences.usageDisplayMode,
                    label: \.shortLabel
                )
                .frame(maxWidth: 220)
            }
            ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                ModeCard(
                    mode: mode,
                    usageDisplayMode: preferences.usageDisplayMode,
                    isSelected: preferences.menuBarDisplayMode == mode
                ) {
                    preferences.menuBarDisplayMode = mode
                }
            }
        }
    }
}

/// One display mode: its own live strip and the selection state. The strip floats on top in
/// the same capsule the live menu bar uses, and the title sits below — there is no per-mode
/// explanatory copy, since the preview already says what the mode is.
private struct ModeCard: View {
    let mode: MenuBarDisplayMode
    let usageDisplayMode: UsageDisplayMode
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.themeAccent) private var themeAccent

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                MenuBarStrip(
                    metrics: SampleUsage.metrics(displayMode: usageDisplayMode),
                    displayMode: mode
                )
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.black.opacity(0.34)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 1))

                HStack(spacing: 6) {
                    Text(mode.label)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer(minLength: 8)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected
                                         ? AnyShapeStyle(themeAccent)
                                         : AnyShapeStyle(Color.white.opacity(0.16)))
                        .scaleEffect(isSelected ? 1.1 : 1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(themeAccent, lineWidth: 1.5)
                .opacity(isSelected ? 1 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}