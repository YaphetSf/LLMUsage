import SwiftUI

// MARK: - Ambient background

/// The dark canvas with drifting blobs behind the glass panes. Shared by the control center
/// window and the menu bar popover so both surfaces sit on the same light.
public struct AmbientBackground: View {
    /// Popovers are small and short-lived; they get a calmer, tighter version of the canvas.
    public enum Scale {
        case window
        case popover

        var blobs: [(color: Color, size: CGFloat, center: CGPoint, drift: CGSize, duration: Double)] {
            switch self {
            case .window:
                [(Brand.light, 620, CGPoint(x: 0.04, y: 0.05), CGSize(width: 48, height: 26), 27),
                 (Color.white, 520, CGPoint(x: 0.88, y: 0.10), CGSize(width: -54, height: 34), 33),
                 (Brand.glow, 640, CGPoint(x: 0.46, y: 0.98), CGSize(width: 58, height: -40), 39)]
            case .popover:
                [(Brand.light, 300, CGPoint(x: 0.02, y: 0.02), CGSize(width: 22, height: 16), 31),
                 (Color.white, 260, CGPoint(x: 1.0, y: 0.9), CGSize(width: -26, height: -20), 37)]
            }
        }

        var opacity: Double {
            switch self {
            case .window: 0.26
            case .popover: 0.07
            }
        }
    }

    private let scale: Scale

    public init(_ scale: Scale = .window) {
        self.scale = scale
    }

    public var body: some View {
        ZStack {
            LinearGradient(colors: [Brand.canvasTop, Brand.canvasBottom],
                           startPoint: .top, endPoint: .bottom)
            ForEach(Array(scale.blobs.enumerated()), id: \.offset) { _, blob in
                Blob(color: blob.color, size: blob.size, relativeCenter: blob.center,
                     drift: blob.drift, duration: blob.duration, opacity: scale.opacity)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// One blurred color blob slowly ping-ponging around its anchor.
private struct Blob: View {
    let color: Color
    let size: CGFloat
    let relativeCenter: CGPoint
    let drift: CGSize
    let duration: Double
    let opacity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifted = false

    var body: some View {
        GeometryReader { proxy in
            Circle()
                .fill(color.opacity(opacity))
                .blur(radius: 90)
                .frame(width: size, height: size)
                .position(x: proxy.size.width * relativeCenter.x + (drifted ? drift.width : 0),
                          y: proxy.size.height * relativeCenter.y + (drifted ? drift.height : 0))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                drifted = true
            }
        }
    }
}

// MARK: - Glass surfaces

/// Liquid Glass for the app's small surfaces — icon tiles, pills, buttons. On macOS 26 this
/// is the real thing, so the surface refracts what is behind it and picks up its own
/// specular edge; older systems fall back to a tinted material that reads close enough.
///
/// The rim is drawn either way. It is what turns a translucent panel into something that
/// looks like it is made of metal-edged glass rather than frosted plastic.
public struct SilverGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let tintOpacity: Double
    let interactive: Bool
    let rimWidth: CGFloat

    public func body(content: Content) -> some View {
        surface(content)
            .overlay(shape.strokeBorder(Brand.rim, lineWidth: rimWidth))
    }

    @ViewBuilder
    private func surface(_ content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(shape.fill(Brand.plate.opacity(tintOpacity)))
                .glassEffect(glass, in: shape)
        } else {
            content
                .background(shape.fill(Brand.plate.opacity(tintOpacity)))
                .background(shape.fill(.ultraThinMaterial))
        }
    }

    @available(macOS 26, *)
    private var glass: Glass {
        let base = Glass.regular.tint(Brand.tint.opacity(tintOpacity * 0.5))
        return interactive ? base.interactive() : base
    }
}

public extension View {
    /// - Parameter interactive: opt in for anything the pointer can press, so the glass
    ///   lenses under the cursor instead of sitting there as a static plate.
    func silverGlass<S: InsettableShape>(
        in shape: S,
        tintOpacity: Double = 0.42,
        interactive: Bool = false,
        rimWidth: CGFloat = 1
    ) -> some View {
        modifier(SilverGlassModifier(shape: shape, tintOpacity: tintOpacity,
                                     interactive: interactive, rimWidth: rimWidth))
    }
}

/// A frosted pane floating over the ambient background. Panes stay `ultraThinMaterial`
/// rather than Liquid Glass: glass is for controls and chrome, and a window-sized sheet of
/// it washes out the content sitting on top.
public struct GlassCardModifier: ViewModifier {
    var corner: CGFloat

    /// Hue lock: raw `ultraThinMaterial` adopts whatever color sits behind the window, so a
    /// desktop wallpaper can drag the whole app off-palette. A thin veil keeps the glass
    /// neutral — thin enough that the ambient light still comes through, which is most of
    /// what makes the panes feel transparent rather than painted.
    /// Hue lock. `ultraThinMaterial` samples the desktop *behind the window*, not this app's
    /// own canvas, so a thin veil is not a style choice — over a bright window underneath,
    /// the panes wash out to white and the app becomes unreadable. This is the thinnest the
    /// veil can go and still hold the palette; the sheen and rim carry the glassiness that a
    /// thinner veil would have bought.
    private static let veil = Color(red: 0.075, green: 0.082, blue: 0.105).opacity(0.42)

    /// A sheen down the face of the pane. Without it a frosted rectangle reads as a slab;
    /// with it the pane reads as a sheet of glass catching the same light as the rim.
    private static let sheen = LinearGradient(
        colors: [.white.opacity(0.10), .white.opacity(0.02), .clear],
        startPoint: .top,
        endPoint: .bottom
    )

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return content
            .background(
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(Self.veil))
                    .overlay(shape.fill(Self.sheen))
            )
            .overlay(shape.strokeBorder(Brand.rim, lineWidth: 1))
            .shadow(color: .black.opacity(0.34), radius: 18, y: 8)
    }
}

public extension View {
    func glassCard(corner: CGFloat = 16) -> some View {
        modifier(GlassCardModifier(corner: corner))
    }
}

/// Hover lift + accent glow for clickable cards.
public struct HoverLiftModifier: ViewModifier {
    var glow: Color

    @State private var hovering = false

    public func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.015 : 1)
            .shadow(color: glow.opacity(hovering ? 0.4 : 0), radius: hovering ? 18 : 0, y: 5)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
    }
}

public extension View {
    func hoverLift(glow: Color = Brand.glow) -> some View {
        modifier(HoverLiftModifier(glow: glow))
    }
}

/// A circular glass button for the popover's icon-only actions.
public struct GlassIconButtonStyle: ButtonStyle {
    public var diameter: CGFloat = 30

    public init(diameter: CGFloat = 30) {
        self.diameter = diameter
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: diameter, height: diameter)
            .silverGlass(in: Circle(),
                         tintOpacity: configuration.isPressed ? 0.55 : 0.38,
                         interactive: true)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Shared atoms

/// Large rounded page title. A title stands alone — no explanatory subtitle underneath it.
public struct PageHeader: View {
    private let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(.system(size: 27, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
    }
}

/// The small all-caps label that names a group of cards.
public struct SectionLabel: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.6)
    }
}

/// A small gradient-tiled SF Symbol, the app's standard way of labelling anything.
public struct AccentIcon: View {
    private let systemName: String
    private let size: CGFloat
    private let glowing: Bool

    public init(_ systemName: String, size: CGFloat = 30, glowing: Bool = false) {
        self.systemName = systemName
        self.size = size
        self.glowing = glowing
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .silverGlass(in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous),
                         tintOpacity: glowing ? 0.62 : 0.44)
            .shadow(color: Brand.glow.opacity(glowing ? 0.35 : 0.10),
                    radius: glowing ? 9 : 2, y: 1)
            .accessibilityHidden(true)
    }
}

/// A horizontal quota meter: a track with a gradient level and a soft glow at the leading
/// edge of the fill.
public struct QuotaBar: View {
    private let fraction: Double
    private let tone: MeterTone
    private let height: CGFloat

    public init(fraction: Double, tone: MeterTone, height: CGFloat = 7) {
        self.fraction = min(1, max(0, fraction))
        self.tone = tone
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                if fraction > 0 {
                    Capsule()
                        .fill(Brand.tone(tone))
                        .overlay(alignment: .top) {
                            // A hairline along the top of the level: the highlight is what
                            // makes it read as liquid under glass instead of a flat bar.
                            Capsule()
                                .fill(.white.opacity(0.45))
                                .frame(height: max(1, height * 0.22))
                                .padding(.horizontal, height * 0.3)
                                .padding(.top, height * 0.14)
                        }
                        .frame(width: max(proxy.size.width * fraction, height))
                        .shadow(color: Brand.toneGlow(tone).opacity(0.45), radius: 5)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A small capsule that carries one piece of secondary metadata (a plan name, a countdown).
public struct InfoChip<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.62))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Brand.rim, lineWidth: 1))
    }
}
