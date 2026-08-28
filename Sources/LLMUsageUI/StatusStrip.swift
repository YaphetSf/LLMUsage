import AppKit
import LLMUsagePreferences
import SwiftUI

/// One provider's contribution to the menu bar strip.
public struct StatusMetric: Sendable {
    public let id: String
    public let displayName: String
    public let value: String
    public let secondaryValue: String?
    public let percent: Int?
    public let sessionBlockedByWeeklyLimit: Bool

    public init(
        id: String,
        displayName: String,
        value: String,
        secondaryValue: String? = nil,
        percent: Int?,
        sessionBlockedByWeeklyLimit: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.value = value
        self.secondaryValue = secondaryValue
        self.percent = percent
        self.sessionBlockedByWeeklyLimit = sessionBlockedByWeeklyLimit
    }

    public var accessibilitySummary: String {
        var components = [displayName, value]
        if let secondaryValue { components.append(secondaryValue) }
        if sessionBlockedByWeeklyLimit {
            components.append("5-hour quota blocked by exhausted weekly quota")
        }
        return components.joined(separator: " ")
    }
}

@MainActor
public enum StatusStripRenderer {
    public static func image(
        metrics: [StatusMetric],
        displayMode: MenuBarDisplayMode = .capacity,
        colorScheme: ColorScheme = .light
    ) -> NSImage? {
        let renderer = ImageRenderer(content: MenuBarStrip(
            metrics: metrics,
            displayMode: displayMode
        )
        .environment(\.colorScheme, colorScheme))
        renderer.scale = 2
        guard let rendered = renderer.cgImage else { return nil }
        let cgImage = trimmedToVisibleContent(rendered) ?? rendered
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(
                width: CGFloat(cgImage.width) / renderer.scale,
                height: CGFloat(cgImage.height) / renderer.scale
            )
        )
        image.isTemplate = true
        image.accessibilityDescription = metrics
            .map(\.accessibilitySummary)
            .joined(separator: ", ")
        return image
    }

    private static func trimmedToVisibleContent(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &alpha,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var maxX = -1
        var minY = height
        var maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where alpha[row + x] != 0 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX else { return nil }
        return image.cropping(to: CGRect(
            x: minX,
            y: minY,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        ))
    }
}

/// The strip exactly as the menu bar draws it. Public so the control center can show a live
/// preview instead of describing the modes in words.
///
/// Everything here stays monochrome (`.primary`) so the rendered image ships as a template
/// image and adapts to the menu bar.
public struct MenuBarStrip: View {
    private let metrics: [StatusMetric]
    private let displayMode: MenuBarDisplayMode

    public init(
        metrics: [StatusMetric],
        displayMode: MenuBarDisplayMode
    ) {
        self.metrics = metrics
        self.displayMode = displayMode
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(metrics, id: \.id) { metric in
                HStack(spacing: 2) {
                    ProviderLogoView(providerID: metric.id)
                        .frame(width: 16, height: 16)
                    metricView(metric)
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 1)
        .padding(.vertical, 1)
        .fixedSize()
    }

    @ViewBuilder
    private func metricView(_ metric: StatusMetric) -> some View {
        switch displayMode {
        case .sessionNumber:
            Text(metric.value)
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .dashedStrike(active: metric.sessionBlockedByWeeklyLimit)
        case .sessionAndWeeklyNumbers:
            if let secondaryValue = metric.secondaryValue {
                VStack(alignment: .trailing, spacing: -2) {
                    Text(metric.value)
                        .dashedStrike(active: metric.sessionBlockedByWeeklyLimit)
                    Text(secondaryValue)
                }
                .font(.system(size: 9, weight: .semibold))
                .monospacedDigit()
                .fixedSize()
            } else {
                Text(metric.value)
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .dashedStrike(active: metric.sessionBlockedByWeeklyLimit)
            }
        case .capacity:
            if let percent = metric.percent {
                if metric.sessionBlockedByWeeklyLimit {
                    BlockedCapacityRectangle()
                } else {
                    VerticalUsageRectangle(percent: percent)
                }
            } else {
                Text(metric.value)
                    .font(.system(size: 10, weight: .bold))
            }
        }
    }
}

private struct DashedStrikeModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                GeometryReader { proxy in
                    Path { path in
                        let y = proxy.size.height / 2
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    }
                    .stroke(
                        Color.primary,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .butt, dash: [3, 1.5])
                    )
                }
                .allowsHitTesting(false)
            }
        }
    }
}

private extension View {
    func dashedStrike(active: Bool) -> some View {
        modifier(DashedStrikeModifier(active: active))
    }
}

private struct BlockedCapacityRectangle: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: -0.75, y: 0))
            path.addLine(to: CGPoint(x: 5.75, y: 0))
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: 16))
            path.move(to: CGPoint(x: 5, y: 0))
            path.addLine(to: CGPoint(x: 5, y: 16))
            path.move(to: CGPoint(x: -0.75, y: 16))
            path.addLine(to: CGPoint(x: 5.75, y: 16))
        }
        .stroke(
            Color.primary,
            style: StrokeStyle(lineWidth: 1.5, lineCap: .butt, lineJoin: .miter, dash: [3, 1.5])
        )
        .frame(width: 5, height: 16)
        .clipped()
    }
}

private struct VerticalUsageRectangle: View {
    let percent: Int

    private var fraction: CGFloat {
        CGFloat(min(100, max(0, percent))) / 100
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.24))
                if fraction > 0 {
                    Rectangle()
                        .fill(fillColor)
                        .frame(height: max(1, proxy.size.height * fraction))
                }
            }
        }
        .frame(width: 5, height: 16)
    }

    /// Monochrome so the rendered strip ships as a template image and matches the menu bar.
    private var fillColor: Color {
        .primary
    }
}
