import AppKit
import SwiftUI

/// LLMUsage's mark: the integral sign, loaded from a single SVG source
/// (`Resources/BrandMark/LLMUsageMark.svg`). The app integrates token usage over time, and the
/// stroke is one tennis-ball seam laid flat. Every surface that shows the logo renders this one
/// file — the About pane, the control center header, the tracker panel — and
/// `scripts/generate-app-icon.swift` rasterizes it onto a graphite tile for the Dock. Swap the
/// SVG and the whole product follows.
public struct LLMUsageMark: View {
    public init() {}

    public var body: some View {
        Group {
            if let image = BrandMarkLibrary.image() {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Loads the brand mark's SVG and caches the raster. Mirrors `ProviderLogoLibrary`'s two-path
/// lookup: installed bundles carry the file flattened into `Contents/Resources/BrandMark`,
/// `Bundle.module` is the path that works during `swift test` and `swift run`.
@MainActor
public enum BrandMarkLibrary {
    private static var cache: NSImage?

    public static func image() -> NSImage? {
        if let image = cache { return image }
        let packagedURL = Bundle.main.url(
            forResource: "LLMUsageMark",
            withExtension: "svg",
            subdirectory: "BrandMark"
        )
        let resourceURL = packagedURL ?? Bundle.module.url(
            forResource: "LLMUsageMark",
            withExtension: "svg",
            subdirectory: "Resources/BrandMark"
        )
        guard let url = resourceURL,
              let image = VectorArtwork.rasterize(at: url, pixelSize: 1024, pointSize: 256) else {
            return nil
        }
        cache = image
        return image
    }
}

/// The wordmark: "LLM" in the accent gradient, "Usage" in white, set in the rounded face the
/// rest of the app uses for anything display-sized.
public struct Wordmark: View {
    private let size: CGFloat

    public init(size: CGFloat = 34) {
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 0) {
            Text("LLM")
                .foregroundStyle(Brand.chrome)
            Text("Usage")
                .foregroundStyle(.white)
        }
        .font(.system(size: size, weight: .heavy, design: .rounded))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("LLMUsage")
    }
}
