import Foundation
import AppKit
import CoreV2

/// Core V2 240×240 display: profile icon (140 px, top) and title (y≈180, 32 px white), RGB565 big-endian,
/// sent in 4-row chunks between invoke_display 3 (off) and 4 (on) like the service's WRITE_DISPLAY.
enum Screen {
    static let size = 240

    static func render(title: String, icon: NSImage?, rotation: Int) -> Data {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            NSColor.black.setFill(); rect.fill()
            if let icon {
                icon.draw(in: NSRect(x: 50, y: 25, width: 140, height: 140))
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 28, weight: .medium), .foregroundColor: NSColor.white]
            let s = NSAttributedString(string: title, attributes: attrs)
            let w = min(s.size().width, 236)
            s.draw(with: NSRect(x: (240 - w) / 2, y: 178, width: w, height: 40), options: [.usesLineFragmentOrigin])
            return true
        }
        var rect = CGRect(x: 0, y: 0, width: size, height: size)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        ctx.translateBy(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
        ctx.rotate(by: CGFloat(rotation) * .pi / 180)
        ctx.draw(cg, in: CGRect(x: -size / 2, y: -size / 2, width: size, height: size))
        guard let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return Data() }
        var out = Data(count: size * size * 2)
        for i in 0..<(size * size) {
            let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
            let v = (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)
            out[i * 2] = UInt8(v >> 8); out[i * 2 + 1] = UInt8(v & 0xff)
        }
        return out
    }

    static func write(_ bitmap: Data, to dev: CoreDevice, liveRefresh: Bool = false) {
        guard bitmap.count == size * size * 2 else { return }
        var msgs: [[String: Any]] = liveRefresh ? [] : [["invoke_display": 3]]
        let rows = 4, chunk = size * rows * 2
        for (i, off) in stride(from: 0, to: bitmap.count, by: chunk).enumerated() {
            msgs.append(["write_display_slow": [true, 0, i * rows, size, (i + 1) * rows, bitmap[off..<min(off + chunk, bitmap.count)]]])
        }
        msgs.append(["invoke_display": 4])
        dev.sendScreen(msgs)
    }
}
