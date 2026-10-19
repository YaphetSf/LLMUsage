#!/usr/bin/env swift

import AppKit

let arguments = CommandLine.arguments.dropFirst()
let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let outputURL = URL(fileURLWithPath: arguments.first
    ?? projectRoot.appendingPathComponent("Packaging/AppIcon.icns").path)
let markURL = projectRoot.appendingPathComponent(
    "Sources/LLMUsageUI/Resources/BrandMark/LLMUsageMark.svg")

let tileTop = NSColor(srgbRed: 0.168, green: 0.178, blue: 0.205, alpha: 1)
let tileBottom = NSColor(srgbRed: 0.043, green: 0.047, blue: 0.060, alpha: 1)

func drawIcon(canvas: CGFloat) {
    NSGraphicsContext.current?.imageInterpolation = .high

    let inset = canvas * 0.08
    let tile = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let radius = tile.width * 0.225
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    NSGradient(colors: [tileTop, tileBottom])!.draw(in: tilePath, angle: -55)

    let border = NSBezierPath(roundedRect: tile.insetBy(dx: canvas * 0.006, dy: canvas * 0.006),
                              xRadius: radius, yRadius: radius)
    border.lineWidth = max(0.5, canvas * 0.012)
    NSColor.white.withAlphaComponent(0.11).setStroke()
    border.stroke()

    let side = tile.width * 0.84
    guard let mark = NSImage(contentsOf: markURL) else {
        FileHandle.standardError.write(Data("cannot load brand mark at \(markURL.path)\n".utf8))
        exit(1)
    }
    mark.size = NSSize(width: side, height: side)
    mark.draw(in: CGRect(x: tile.midX - side / 2, y: tile.midY - side / 2, width: side, height: side),
              from: .zero, operation: .sourceOver, fraction: 1.0)
}

func png(size: Int) throws -> Data {
    let canvas = CGFloat(size)
    let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
        drawIcon(canvas: canvas)
        return true
    }
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

let iconset: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

let staging = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("LLMUsageAppIcon-\(UUID().uuidString)")
    .appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }

for (filename, size) in iconset {
    try png(size: size).write(to: staging.appendingPathComponent(filename))
}

try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", staging.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote \(outputURL.path)")
