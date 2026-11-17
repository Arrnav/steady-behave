// Draws the Steady app icon at every size iconutil needs.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

func drawIcon(pixels: Int) -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        fail("could not create a \(pixels) px bitmap")
    }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)

    // macOS icon grid: the rounded square fills about 80% of the canvas.
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Soft drop shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Calm teal-to-indigo gradient.
    guard let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.72, blue: 0.74, alpha: 1),
        NSColor(calibratedRed: 0.33, green: 0.47, blue: 0.80, alpha: 1),
        NSColor(calibratedRed: 0.40, green: 0.35, blue: 0.72, alpha: 1)
    ]) else { fail("could not create the background gradient") }
    gradient.draw(in: shape, angle: -60)

    // Subtle top highlight.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    if let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)]) {
        highlight.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    }
    NSGraphicsContext.restoreGraphicsState()

    // Eye mark: an almond outline with a solid iris, centred on the tile.
    let cx = s / 2, cy = s / 2
    let w = rect.width * 0.62, h = rect.width * 0.36
    let eye = NSBezierPath()
    eye.move(to: NSPoint(x: cx - w / 2, y: cy))
    eye.curve(to: NSPoint(x: cx + w / 2, y: cy),
              controlPoint1: NSPoint(x: cx - w / 4, y: cy + h * 0.78),
              controlPoint2: NSPoint(x: cx + w / 4, y: cy + h * 0.78))
    eye.curve(to: NSPoint(x: cx - w / 2, y: cy),
              controlPoint1: NSPoint(x: cx + w / 4, y: cy - h * 0.78),
              controlPoint2: NSPoint(x: cx - w / 4, y: cy - h * 0.78))
    eye.close()
    eye.lineWidth = max(1, rect.width * 0.045)
    eye.lineJoinStyle = .round
    NSColor.white.setStroke()
    eye.stroke()

    let irisR = h * 0.36
    let iris = NSBezierPath(ovalIn: NSRect(x: cx - irisR, y: cy - irisR, width: irisR * 2, height: irisR * 2))
    NSColor.white.setFill()
    iris.fill()

    // Small calm "settled" line under the eye.
    let line = NSBezierPath()
    line.move(to: NSPoint(x: cx - w * 0.22, y: cy - h * 0.82))
    line.line(to: NSPoint(x: cx + w * 0.22, y: cy - h * 0.82))
    line.lineWidth = max(1, rect.width * 0.035)
    line.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.75).setStroke()
    line.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("could not encode PNG") }
    return png
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, px) in sizes {
    let url = URL(fileURLWithPath: output).appendingPathComponent("\(name).png")
    do {
        try drawIcon(pixels: px).write(to: url)
    } catch {
        fail("could not write \(url.path): \(error.localizedDescription)")
    }
}
