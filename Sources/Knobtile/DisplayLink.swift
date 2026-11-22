import SwiftUI
import Combine
import CoreV2

/// 보조 디스플레이: a Waveshare ESP32-S3 4.3″ board (800×480) on USB shows the 상시 맵 all the time.
/// The Mac draws, the board only blits: changed 16-row bands go over as RLE, protocol in monogram/Display/firmware/src/main.cpp.
/// Any ESP32-S3 shows up as 303A:1001, so frames go out only after the board answers hello with "H knobtile-display".
@MainActor final class DisplayLink {
    static let shared = DisplayLink()
    nonisolated static let width = 800, height = 480, band = 16

    private var port: SerialPort?, ready = false, heard = ""
    private var last: [UInt16] = [] // what the board shows once `queue` is through; empty = unknown, send everything
    private var queue: [Data] = [], waiting = 0 // bands still to send; > 0 while one is out and its "A" not back (the number tells timeouts apart)
    private var due = false, stale = false, subs: [AnyCancellable] = [], window: NSWindow?
    private let readQueue = DispatchQueue(label: "display.read")

    func start(_ service: ServiceClient) {
        guard subs.isEmpty else { return }
        subs = [service.objectWillChange.sink { [weak self] _ in self?.schedule() },
                service.live.objectWillChange.sink { [weak self] _ in self?.schedule() }]
        // A view kept alive in a never-shown window: LayoutView fits itself in onAppear / onChange, which a one-shot ImageRenderer never runs.
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width / 2, height: Self.height / 2), styleMask: .borderless, backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: ZStack { Color.black; MapView() }.environment(\.noActiveFill, true).environmentObject(service).environmentObject(service.live))
        window = w
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in Task { @MainActor in DisplayLink.shared.open() } } // plugged in later, or again
        open()
    }

    private func open() {
        guard port == nil, let path = SerialPort.find(vendor: 0x303A, product: 0x1001), let p = try? SerialPort(path: path, queue: readQueue) else { return }
        p.onData = { d in let s = String(decoding: d, as: UTF8.self); Task { @MainActor in DisplayLink.shared.heard(s) } }
        p.onClose = { Task { @MainActor in let l = DisplayLink.shared; l.port = nil; l.ready = false } }
        port = p; ready = false; heard = ""; reset()
        p.write(Self.frame(cmd: 0, y: 0, h: 0, Data()))
    }
    private func reset() { last = []; queue = []; waiting = 0 }

    /// Board → Mac text lines. shortcut: touch ("T x y" / "U") is read but not used yet; route it to the map when 터치 is wanted (flip it: x → 799 - x, y → 479 - y, the picture is turned 180°).
    private func heard(_ s: String) {
        heard += s
        while let nl = heard.firstIndex(where: \.isNewline) { // the board ends lines with \r\n, one Character in Swift
            let line = heard[..<nl].trimmingCharacters(in: .whitespacesAndNewlines)
            heard = String(heard[heard.index(after: nl)...])
            if line.hasPrefix("H knobtile-display") { ready = true; reset(); schedule() } // also after the board restarts: its screen is blank again
            else if line == "A", waiting > 0 { waiting = 0; pump() }
        }
        if heard.count > 4096 { heard = "" }
    }

    /// At most 10 frames a second: a dial turning changes Live many times that.
    private func schedule() {
        guard ready, !due else { return }
        due = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in due = false; send() }
    }

    /// One band at a time, the next after the board's "A": its USB receive buffer drops what does not fit, and a lost byte misaligns the rest.
    private func pump() {
        guard let port, waiting == 0 else { return }
        guard !queue.isEmpty else { if stale { stale = false; schedule() }; return } // through: pick up what changed meanwhile
        port.write(queue.removeFirst())
        let n = Int.random(in: 1...Int.max); waiting = n
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in if waiting == n { reset(); schedule() } } // no answer: the board drops the half frame after 200 ms, so start over
    }

    private func send() {
        guard ready else { return }
        guard queue.isEmpty, waiting == 0 else { stale = true; return }
        guard let v = window?.contentView,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Self.width, pixelsHigh: Self.height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: Self.width * 4, bitsPerPixel: 32),
              let px = rep.bitmapData else { return }
        rep.size = v.bounds.size // 2 px per point: the 10 pt map labels come out readable on a 4.3″ panel
        v.layoutSubtreeIfNeeded()
        v.cacheDisplay(in: v.bounds, to: rep)
        var now = [UInt16](repeating: 0, count: Self.width * Self.height)
        for i in now.indices {
            let r = UInt16(px[i * 4]), g = UInt16(px[i * 4 + 1]), b = UInt16(px[i * 4 + 2])
            now[now.count - 1 - i] = (r >> 3) << 11 | (g >> 2) << 5 | b >> 3 // turned 180°: the board stands upside down (USB on top, 2026-11-17)
        }
        queue = Self.frames(now, since: last)
        last = now
        if !queue.isEmpty { queue.append(Self.frame(cmd: 2, y: 0, h: 0, Data())); pump() } // commit: the board shows the bands together, not wiping in
    }

    /// The bands of `now` that differ from `old`, each as one frame. Runs may cross rows: the board fills its band linearly.
    nonisolated static func frames(_ now: [UInt16], since old: [UInt16]) -> [Data] {
        var out: [Data] = []
        for y in stride(from: 0, to: height, by: band) {
            let r = y * width..<min(y + band, height) * width
            if old.count == now.count, old[r] == now[r] { continue }
            var rle = Data(), i = r.lowerBound
            while i < r.upperBound {
                let c = now[i]; var n = 1
                while n < 255, i + n < r.upperBound, now[i + n] == c { n += 1 }
                rle.append(contentsOf: [UInt8(n), UInt8(c & 0xff), UInt8(c >> 8)])
                i += n
            }
            out.append(frame(cmd: 1, y: y, h: r.count / width, rle))
        }
        return out
    }

    nonisolated static func frame(cmd: UInt8, y: Int, h: Int, _ payload: Data) -> Data {
        var d = Data("KT".utf8) + [cmd, UInt8(y & 0xff), UInt8(y >> 8), UInt8(h & 0xff), UInt8(h >> 8)]
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { d += $0 }
        return d + payload
    }
}
