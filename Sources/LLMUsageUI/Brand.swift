import LLMUsagePreferences
import SwiftUI

/// LLMUsage's design language (2026-08-27): a deep graphite canvas with slowly drifting,
/// brand-tinted light blobs behind frosted glass panes. Both surfaces — the menu bar popover
/// and the control center window — draw every color, surface, and atom from this file so the
/// two read as one product rather than two apps that happen to ship together.
///
/// ## Theming
/// The metal itself is cast from the user's `AccentChoice`. Every ramp below runs through
/// `metal(_:)`, which maps the original *silver* brightness values onto the accent's hue:
/// highlights desaturate toward white, shadows keep the colour, so a pink theme reads as
/// polished rose-metal rather than flat pink. `silver` (the default) is near-neutral and
/// falls through to the original grey ramps untouched. The choice is read from the shared
/// defaults suite on every access, so views that re-evaluate pick up theme switches live.
///
/// Motion is generous but every endless animation is gated on Reduce Motion.
public enum Brand {
    // MARK: Theme

    /// Nonisolated read of the user's accent, so `Brand` can be consulted from any context
    /// (SwiftUI bodies, the tracker's render path, tests). `UserDefaults` reads are
    /// thread-safe; the suite is the one the control center and tracker already share.
    private static var currentAccent: AccentChoice {
        let raw = UserDefaults(suiteName: "com.llmusage.shared")?
            .string(forKey: AppPreferences.accentChoiceKey)
        return raw.flatMap(AccentChoice.init(rawValue:)) ?? AppPreferences.defaultAccentChoice
    }

    /// One stop on a metal ramp. `white` is the brightness the original silver ramp used at
    /// this position; a coloured accent re-tints it (highlights stay near-white with a cast,
    /// shadows saturate), while silver passes straight through.
    private static func metal(_ white: Double) -> Color {
        let choice = currentAccent
        if choice.isNeutral { return Color(white: white) }

        let c = choice.sRGB
        let maxV = max(c.red, c.green, c.blue)
        let minV = min(c.red, c.green, c.blue)
        let delta = maxV - minV
        guard maxV > 0 else { return Color(white: white) }
        let hue: Double
        if delta == 0 {
            return Color(white: white)
        } else if c.red == maxV {
            hue = ((c.green - c.blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if c.green == maxV {
            hue = (c.blue - c.red) / delta + 2
        } else {
            hue = (c.red - c.green) / delta + 4
        }
        let normalizedHue = (hue < 0 ? hue + 6 : hue) / 6
        // Brighter stops wash toward white so highlights still read as reflections; darker
        // stops carry most of the colour.
        let saturation = min(1.0, delta / maxV * (1.45 - white))
        return Color(hue: normalizedHue, saturation: max(0, saturation), brightness: white)
    }

    // MARK: Palette

    /// Silver is not a color you can paint on — a flat grey fill just reads as unfinished
    /// plastic. It has to come from the glass itself: a translucent surface, a specular ramp
    /// across it, and a rim that is bright where the light lands and gone on the far side.
    ///
    /// With a coloured accent chosen these tint with it — the glass remembers what metal it
    /// is made of.
    public static var tint: Color { metal(0.72) }
    public static var tintDeep: Color { metal(0.45) }
    public static var glow: Color { metal(0.78) }

    /// Quota tones. Amber and red only ever appear when a quota is genuinely running out, so
    /// this kind of color always means "pay attention", never decoration.
    public static let warning = Color(red: 1.0, green: 0.69, blue: 0.13)
    public static let critical = Color(red: 1.0, green: 0.30, blue: 0.42)

    /// "This thing is on" — state toggles and "this thing is on" dots read from this constant
    /// instead of `metal()`-derived accents. Silver's metal ramp at the brightest stops only
    /// reaches `(0.78, 0.78, 0.78)`, which collides with a near-white switch knob in dark
    /// mode and leaves the on-state indistinguishable from off. A bright cool silver lifts
    /// just enough off the knob to read, without leaving the brand's neutral language.
    public static let active = Color(red: 0.92, green: 0.95, blue: 0.98)

    /// Graphite rather than ink. Glass takes its brightness from what is behind it, so a
    /// near-black canvas produced black plates no matter how the tint was pushed; lifting the
    /// canvas a stop is what lets the silver actually read as silver. The canvas stays
    /// neutral whatever accent is picked — it is the desk, not the metal.
    public static let canvasTop = Color(red: 0.105, green: 0.114, blue: 0.140)
    public static let canvasBottom = Color(red: 0.042, green: 0.047, blue: 0.065)

    /// The cool light the whole app is lit by. With no light source the metal is just grey.
    public static let light = Color(red: 0.82, green: 0.88, blue: 1.0)

    // MARK: Gradients

    /// Polished metal. The specular band a third of the way across is the whole trick — a
    /// two-stop ramp reads as cardboard, this reads as metal.
    public static var accent: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: metal(0.58), location: 0.0),
                .init(color: metal(0.96), location: 0.34),
                .init(color: metal(0.56), location: 0.63),
                .init(color: metal(0.84), location: 1.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The same metal running down a tube, so a filled meter catches the light along its top
    /// edge the way liquid in a glass does.
    public static var level: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: metal(0.97), location: 0.0),
                .init(color: metal(0.72), location: 0.34),
                .init(color: metal(0.52), location: 0.78),
                .init(color: metal(0.76), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Rim light. A uniform white hairline reads as plastic; a rim that falls off across the
    /// shape reads as a glass edge catching a light source.
    public static var rim: LinearGradient {
        LinearGradient(
            colors: [metal(0.90).opacity(0.90), metal(0.60).opacity(0.30), metal(0.40).opacity(0.06)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The metal plate under a glass surface. Glass alone refracts but adds no substance —
    /// this is what a tile is actually made of, and the glass sits on top of it.
    public static var plate: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: metal(0.98), location: 0.0),
                .init(color: metal(0.74), location: 0.42),
                .init(color: metal(0.58), location: 0.72),
                .init(color: metal(0.80), location: 1.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Chrome for display type. Text needs the ramp running top-to-bottom with a dark band
    /// across the middle — the diagonal `accent` ramp only shows one slice of itself across
    /// a short wide word, which flattens it back to grey.
    public static var chrome: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: metal(1.0), location: 0.0),
                .init(color: metal(0.80), location: 0.44),
                .init(color: metal(0.50), location: 0.56),
                .init(color: metal(0.95), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    public static func tone(_ tone: MeterTone) -> AnyShapeStyle {
        switch tone {
        case .standard: AnyShapeStyle(level)
        case .warning: AnyShapeStyle(warning)
        case .critical: AnyShapeStyle(critical)
        }
    }

    public static func toneGlow(_ tone: MeterTone) -> Color {
        switch tone {
        case .standard: glow
        case .warning: warning
        case .critical: critical
        }
    }
}

/// How close a quota is to running out, expressed in terms of what's *left* regardless of
/// which perspective the user picked for the numbers.
public enum MeterTone: Equatable, Sendable {
    case standard
    case warning
    case critical

    public static func forRemaining(_ remainingPercent: Int) -> MeterTone {
        switch min(100, max(0, remainingPercent)) {
        case ...10: .critical
        case ...25: .warning
        default: .standard
        }
    }

    public static func forUsed(_ usedPercent: Int) -> MeterTone {
        forRemaining(100 - min(100, max(0, usedPercent)))
    }
}