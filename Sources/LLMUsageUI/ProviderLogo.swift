import AppKit
import SwiftUI

/// NSImage's bundled SVG rasterizer collapses thin strokes when the requested render size is
/// small (e.g. the menu bar's 16pt provider marks). Pre-rendering each SVG into a large bitmap
/// at load time lets SwiftUI's normal image-resampling pipeline handle every downstream
/// downscale cleanly, which is what keeps the official MiniMax waveform readable at menu-bar
/// sizes and the brand mark crisp in the About pane.
enum VectorArtwork {
    static func rasterize(at url: URL, pixelSize: CGFloat, pointSize: CGFloat? = nil) -> NSImage? {
        let renderedSize = pointSize ?? pixelSize
        guard let vector = NSImage(contentsOf: url) else { return nil }
        vector.size = NSSize(width: pixelSize, height: pixelSize)
        guard let tiff = vector.tiffRepresentation,
              let src = NSBitmapImageRep(data: tiff),
              let srcCG = src.cgImage else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(pixelSize), height: Int(pixelSize),
            bitsPerComponent: 8,
            bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(srcCG, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: renderedSize, height: renderedSize))
    }
}

/// Provider wordmarks, shipped as template SVGs so they tint with the surrounding text and
/// stay legible in a light or dark menu bar.
public struct ProviderLogoView: View {
    private let providerID: String

    public init(providerID: String) {
        self.providerID = providerID
    }

    public var body: some View {
        if let image = ProviderLogoLibrary.image(for: providerID) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
        } else {
            Image(systemName: ProviderLogoLibrary.fallbackSymbol(for: providerID))
                .resizable()
                .scaledToFit()
        }
    }
}

@MainActor
public enum ProviderLogoLibrary {
    private static var cache: [String: NSImage] = [:]

    /// Installed bundles carry the icons flattened into `Contents/Resources/ProviderIcons`;
    /// `Bundle.module` is the path that works during `swift test` and `swift run`.
    public static func image(for providerID: String) -> NSImage? {
        if let image = cache[providerID] { return image }
        let packagedURL = Bundle.main.url(
            forResource: providerID,
            withExtension: "svg",
            subdirectory: "ProviderIcons"
        )
        let resourceURL = packagedURL ?? Bundle.module.url(
            forResource: providerID,
            withExtension: "svg",
            subdirectory: "Resources/ProviderIcons"
        )
        guard let url = resourceURL,
              let image = VectorArtwork.rasterize(at: url, pixelSize: 128) else { return nil }
        image.isTemplate = true
        cache[providerID] = image
        return image
    }

    public static func fallbackSymbol(for providerID: String) -> String {
        switch providerID {
        case "claude": "sparkle"
        case "codex": "circle.hexagongrid"
        case "zai": "gauge.medium"
        case "minimax": "m.circle.fill"
        default: "app.dashed"
        }
    }
}

/// A provider wordmark on a gradient tile, used wherever a provider is named on glass.
public struct ProviderBadge: View {
    private let providerID: String
    private let size: CGFloat

    public init(providerID: String, size: CGFloat = 30) {
        self.providerID = providerID
        self.size = size
    }

    public var body: some View {
        ProviderLogoView(providerID: providerID)
            .foregroundStyle(.white)
            .frame(width: size * 0.58, height: size * 0.58)
            .frame(width: size, height: size)
            .silverGlass(in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .shadow(color: Brand.glow.opacity(0.18), radius: 5, y: 2)
            .accessibilityHidden(true)
    }
}
