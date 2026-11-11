// Draws the app icon into an .iconset directory: swift make-icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Trill.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let rect = NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: NSColor(calibratedRed: 0.45, green: 0.38, blue: 0.95, alpha: 1),
               ending: NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1))?
        .draw(in: path, angle: -60)
    if let sym = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))) {
        let sz = sym.size
        sym.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    guard let data = render(px) else { exit(1) }
    try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name + ".png"))
}
