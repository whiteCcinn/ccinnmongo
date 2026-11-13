// Renders the Grove app icon (all macOS iconset sizes) with AppKit.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func renderIcon(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let scale = CGFloat(pixels) / 1024
    let body = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let radius = 186 * scale

    // Drop shadow under the squircle.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSColor(srgbRed: 0.05, green: 0.35, blue: 0.26, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background gradient.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.20, green: 0.74, blue: 0.47, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.52, blue: 0.36, alpha: 1),
        NSColor(srgbRed: 0.03, green: 0.33, blue: 0.27, alpha: 1),
    ], atLocations: [0, 0.55, 1], colorSpace: .sRGB)
    gradient?.draw(in: shape, angle: -55)

    // Soft top highlight.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])
    highlight?.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)

    // Subtle concentric "growth rings".
    for ring in 0..<3 {
        let inset = CGFloat(ring) * 90 * scale
        let ringRect = NSRect(x: body.midX + 120 * scale - (420 * scale - inset), y: body.midY - 160 * scale - (420 * scale - inset),
                              width: 2 * (420 * scale - inset), height: 2 * (420 * scale - inset))
        let path = NSBezierPath(ovalIn: ringRect)
        path.lineWidth = 10 * scale
        NSColor.white.withAlphaComponent(0.06).setStroke()
        path.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Leaf glyph.
    let configuration = NSImage.SymbolConfiguration(pointSize: 470 * scale, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let glyphShadow = NSShadow()
        glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        glyphShadow.shadowBlurRadius = 18 * scale
        glyphShadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
        NSGraphicsContext.saveGraphicsState()
        glyphShadow.set()
        let size = tinted.size
        let origin = NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2)
        tinted.draw(in: NSRect(origin: origin, size: size))
        NSGraphicsContext.restoreGraphicsState()
    }
    return bitmap.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in sizes {
    guard let data = renderIcon(pixels: pixels) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}
print("wrote \(sizes.count) images to \(outputDirectory.path)")
