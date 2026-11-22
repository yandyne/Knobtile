// Draws the app icon (rounded square + dial glyph) and writes build/icon.iconset/*.png. Run via make-app.sh.
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let img = NSImage(size: NSSize(width: px, height: px), flipped: false) { r in
        let s = CGFloat(px), inset = s * 0.08
        let path = NSBezierPath(roundedRect: r.insetBy(dx: inset, dy: inset), xRadius: s * 0.2, yRadius: s * 0.2)
        NSGradient(starting: NSColor(red: 0.16, green: 0.17, blue: 0.22, alpha: 1), ending: NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1))!.draw(in: path, angle: -90)
        let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .regular)
        if let sym = NSImage(systemSymbolName: "dial.medium", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let tinted = NSImage(size: sym.size, flipped: false) { rr in
                sym.draw(in: rr); NSColor(red: 1, green: 0.59, blue: 0.27, alpha: 1).set(); rr.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: (s - sym.size.width) / 2, y: (s - sym.size.height) / 2, width: sym.size.width, height: sym.size.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px)); NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
