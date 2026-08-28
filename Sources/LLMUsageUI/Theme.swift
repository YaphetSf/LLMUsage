import LLMUsagePreferences
import SwiftUI

/// SwiftUI environment plumbing for the user-picked accent colour. The picker writes to
/// `AppPreferences.accentChoice`; views read the resolved `Color` via `@Environment(\.themeAccent)`.
/// `Brand.accent` (the polished silver gradient) is left alone — this only replaces the
/// flat-colour decorations like selection rings, link text, and the toggle tint.
public struct ThemeAccentKey: EnvironmentKey {
    public static let defaultValue: Color = color(for: AppPreferences.defaultAccentChoice)
}

public extension EnvironmentValues {
    var themeAccent: Color {
        get { self[ThemeAccentKey.self] }
        set { self[ThemeAccentKey.self] = newValue }
    }
}

public extension Color {
    /// Resolve an `AccentChoice` into a concrete `Color`. Call sites should prefer reading
    /// `@Environment(\.themeAccent)` so updates propagate, but the constructor is useful at
    /// the root where the value is first injected.
    init(accent: AccentChoice) {
        self.init(red: accent.sRGB.red, green: accent.sRGB.green, blue: accent.sRGB.blue)
    }
}

public func color(for choice: AccentChoice) -> Color {
    Color(red: choice.sRGB.red, green: choice.sRGB.green, blue: choice.sRGB.blue)
}

/// Convenience for views that style their own selection / hover state with the theme accent
/// instead of the silver `Brand.accent`.
public struct AnyThemeAccentStyle: ShapeStyle {
    private let color: Color
    public init(_ color: Color) { self.color = color }
    public func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        AnyShapeStyle(color)
    }
}