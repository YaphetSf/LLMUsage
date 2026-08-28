import AppKit
import LLMUsagePreferences
import LLMUsageUI
import SwiftUI

/// Root of the control center: ambient canvas, a floating glass sidebar, and a floating
/// content pane. Pages: Overview / Usage / Menu Bar / Appearance / About.
struct ControlCenterView: View {
    enum Destination: String, CaseIterable, Identifiable {
        case overview
        case usage
        case menuBar
        case appearance
        case about

        var id: Self { self }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .usage: "Usage"
            case .menuBar: "Menu Bar"
            case .appearance: "Appearance"
            case .about: "About"
            }
        }

        var systemImage: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .usage: "chart.bar"
            case .menuBar: "menubar.rectangle"
            case .appearance: "paintbrush"
            case .about: "info"
            }
        }
    }

    @State private var selection: Destination = .overview
    @StateObject private var tracker = TrackerStatus()
    @StateObject private var preferences = Preferences()
    @StateObject private var snapshots = SnapshotStore()
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @StateObject private var usageStore = UsageStore()

    var body: some View {
        ZStack {
            AmbientBackground()
            HStack(spacing: 0) {
                Sidebar(selection: $selection)
                    .frame(width: 224)
                    .glassCard()
                    .padding(.vertical, 12)
                    .padding(.leading, 12)
                pane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassCard()
                    .padding(12)
            }
            .id(preferences.accentChoice)
        }
        .tint(color(for: preferences.accentChoice))
        .environment(\.themeAccent, color(for: preferences.accentChoice))
        .environmentObject(tracker)
        .environmentObject(preferences)
        .environmentObject(snapshots)
        .environmentObject(launchAtLogin)
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: selection)
        .frame(minWidth: 820, minHeight: 560)
    }

    /// The active page. Re-keying on `selection` remounts the page so entrance animations
    /// replay and the transition fires.
    private var pane: some View {
        Group {
            switch selection {
            case .overview: OverviewView()
            case .usage: UsageView(store: usageStore)
            case .menuBar: MenuBarSettingsView()
            case .appearance: AppearanceSettingsView()
            case .about: AboutView()
            }
        }
        .id(selection)
        // Pages travel vertically: the incoming page rises from below while the outgoing one
        // exits through the top.
        .transition(.asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.97)),
            removal: .move(edge: .top)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.99))
        ))
    }
}

private struct Sidebar: View {
    @Binding var selection: ControlCenterView.Destination
    @EnvironmentObject private var tracker: TrackerStatus
    @Environment(\.themeAccent) private var themeAccent

    @Namespace private var selectionPill

    private static let shortVersion =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 11) {
                LLMUsageMark()
                    .frame(width: 40, height: 40)
                Text("LLMUsage")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.top, 48)
            .padding(.bottom, 18)

            ForEach(ControlCenterView.Destination.allCases) { destination in
                row(destination)
            }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                StatusDot(isOn: tracker.isRunning)
                Text(tracker.isRunning ? "Activated" : "Deactivated")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { tracker.isRunning },
                    set: { $0 ? tracker.start() : tracker.stop() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Brand.active)
                .disabled(!tracker.isInstalled)
                .accessibilityLabel("Run the tracker in the background")
                Text("v\(Self.shortVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity)
    }

    private func row(_ destination: ControlCenterView.Destination) -> some View {
        let isSelected = destination == selection
        return Button {
            selection = destination
        } label: {
            HStack(spacing: 10) {
                AccentIcon(destination.systemImage, size: 27, glowing: isSelected)
                Text(destination.title)
                    .font(.system(.body, design: .rounded).weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(themeAccent) : AnyShapeStyle(Color.white.opacity(0.52)))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule()
                        .fill(themeAccent.opacity(0.16))
                        .overlay(Capsule().strokeBorder(themeAccent.opacity(0.45), lineWidth: 1))
                        .matchedGeometryEffect(id: "selection-pill", in: selectionPill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

/// A live dot: green and breathing while the tracker runs, inert grey while it doesn't.
struct StatusDot: View {
    let isOn: Bool
    var diameter: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private var color: Color {
        isOn ? Brand.active : Color.white.opacity(0.28)
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .shadow(color: color.opacity(isOn ? (pulsing ? 0.9 : 0.35) : 0),
                    radius: pulsing ? 5 : 2)
            .scaleEffect(isOn && pulsing ? 1.12 : 1)
            .onAppear { startPulsing() }
            .onChange(of: isOn) { _ in startPulsing() }
            .accessibilityHidden(true)
    }

    private func startPulsing() {
        guard isOn, !reduceMotion else {
            pulsing = false
            return
        }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}
