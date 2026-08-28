import LLMUsagePreferences
import LLMUsageUI
import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader("Appearance")
                themeCard
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .scrollIndicators(.never)
        .animation(.spring(response: 0.36, dampingFraction: 0.85),
                   value: preferences.menuBarDisplayMode)
    }

    private var themeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Accent")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white)
            HStack(spacing: 10) {
                ForEach(AccentChoice.allCases, id: \.self) { choice in
                    AccentSwatch(
                        choice: choice,
                        isSelected: preferences.accentChoice == choice
                    ) {
                        preferences.accentChoice = choice
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

private struct AccentSwatch: View {
    let choice: AccentChoice
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.themeAccent) private var themeAccent

    private var swatchColor: Color { color(for: choice) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(swatchColor)
                        .frame(width: 36, height: 36)
                    if isSelected {
                        Circle()
                            .strokeBorder(themeAccent, lineWidth: 2.5)
                            .frame(width: 44, height: 44)
                    }
                }
                Text(choice.label)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white : Color.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}