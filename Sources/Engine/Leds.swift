import Foundation
import CoreV2

public typealias RGB = (r: Int, g: Int, b: Int)

/// LED player: one place that owns every LED's color and talks to the Core at a bounded rate.
/// Layers, bottom to top: `base` (assigned / page color) → `live` (dial value band) → running `effects` (flash, wave, breathe…).
/// Every 80 ms it sends only the LEDs whose color changed, at most `budget` messages (the Core stalls on a message per tick).
public final class Leds {
    public struct LED { public let localId: Int, index: Int?, x: Double, y: Double, depth: Int } // depth = port hops from the Core (chain effect)
    public enum Kind { case flash, wave, ripple, chain, breathe, starlight }
    public struct Effect {
        public var kind: Kind, color: RGB, duration: Double // .infinity = loop until `stop`
        public var uuid: String? = nil                       // flash / breathe on one LED only
        public var origin: (x: Double, y: Double)? = nil     // ripple center
        public var direction = 1.0                           // wave: +1 left→right, −1 right→left
        public var count = 1                                 // flash repeats
        var start = Date()
    }
    static let budget = 8 // shortcut: messages per 80 ms tick, chosen from "every tick stalls"; measure on the Core and raise if it copes

    let send: ([String: Any]) -> Void
    private(set) var leds: [String: LED] = [:]
    var base: [String: RGB] = [:], live: [String: RGB] = [:]
    private var sent: [String: RGB] = [:], effects: [Effect] = [], sparks: [String: Date] = [:]
    private var timer: Timer?, queue: [String] = []
    private var brightnessSent: Int?
    /// Per-module white balance (localId → r, g, b gains): the LEDs are blue-heavy and differ by module, so every color is scaled on the way out.
    /// shortcut: `neutral` is one by-eye reading on Dial3x; the user tunes each module in 환경설정.
    public static let neutral = [1, 0.59, 0.27]
    var balance: [Int: [Double]] = [:] { didSet { if balance != oldValue { sent = [:]; schedule() } } }
    /// Packed r | g<<8 | b<<16 as the firmware takes it: balanced, then rescaled so the strongest channel keeps its level (pure blue stays bright).
    func wire(_ c: RGB, _ id: Int) -> Int {
        let g = balance[id] ?? Self.neutral, v = [Double(c.r) * g[0], Double(c.g) * g[1], Double(c.b) * g[2]], top = v.max()!
        guard top > 0 else { return 0 }
        let k = Double(max(c.r, c.g, c.b)) / top, o = v.map { Int(($0 * k).rounded()) }
        return o[0] | o[1] << 8 | o[2] << 16
    }
    public var onFrame: (([String: RGB]) -> Void)? // what the Core shows now (board preview / tests)

    init(send: @escaping ([String: Any]) -> Void) { self.send = send }
    convenience init(device: CoreDevice) { self.init { device.send($0) } }

    /// New hardware layout: forget everything sent before.
    func reset(_ table: [String: LED]) { leds = table; sent = [:]; live = [:]; base = [:]; wash = nil; effects = []; sparks = [:]; queue = [] }
    func set(_ uuid: String, live c: RGB?) { live[uuid] = c; schedule() }
    /// 데코레이션: one color over every LED except `owner` (which keeps its own value color); nil takes it away.
    private var wash: RGB?, washOwner: String?
    func wash(_ c: RGB?, owner: String? = nil) { wash = c; washOwner = owner; schedule() }
    func flush() { schedule() }
    func play(_ e: Effect) {
        effects.removeAll { $0.kind == e.kind && $0.uuid == e.uuid } // one of each kind at a time
        effects.append(e); schedule()
    }
    func stop(_ kind: Kind, uuid: String? = nil) { effects.removeAll { $0.kind == kind && (uuid == nil || $0.uuid == uuid) }; schedule() }
    public var playing: Bool { !effects.isEmpty }
    /// Module LEDs and the Core backlight alike. shortcut: the firmware range is unverified (service never sends it), so up to 255 is let through for the user to try.
    func brightness(_ v: Int) { let v = max(0, min(255, v)); guard v != brightnessSent else { return }; brightnessSent = v; send(["set_brightness": [v, v]]) }

    private func schedule() { if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.tick() }; tick() } }

    func tick() {
        let now = Date()
        effects.removeAll { now.timeIntervalSince($0.start) > $0.duration }
        var frame: [String: RGB] = [:]
        for (u, led) in leds {
            var c = (u != washOwner ? wash : nil) ?? live[u] ?? base[u] ?? (255, 255, 255)
            for e in effects { let k = intensity(e, u, led, now); if k > 0 { c = mix(c, e.color, k) } }
            frame[u] = c
        }
        onFrame?(frame)
        // changed LEDs go out grouped by module: one whole-module message when all its LEDs agree, else per index + commit
        let dirty = frame.filter { sent[$0.key] == nil || sent[$0.key]! != $0.value }
        queue = (queue.filter { dirty[$0] != nil } + dirty.keys.filter { !queue.contains($0) }).sorted { leds[$0]!.localId < leds[$1]!.localId }
        var n = 0
        while let u = queue.first, n < Self.budget {
            let id = leds[u]!.localId, group = queue.filter { leds[$0]!.localId == id }
            let all = leds.filter { $0.value.localId == id }.keys
            if group.contains(where: { leds[$0]!.index == nil }) || (Set(group) == Set(all) && Set(group.map { "\(frame[$0]!)" }).count == 1) {
                let c = frame[u]!
                send(["set_module": [id, 0x02, wire(c, id)]]); n += 1
                for g in all { sent[g] = c }
                queue.removeAll { leds[$0]!.localId == id }
            } else {
                for g in group { let c = frame[g]!; send(["set_module": [id, 0x05, wire(c, id) | leds[g]!.index! << 24]]); sent[g] = c; n += 1 }
                send(["set_module": [id, 0x05, 0x7f << 24]]); n += 1
                queue.removeAll { leds[$0]!.localId == id }
            }
        }
        if queue.isEmpty, effects.isEmpty { timer?.invalidate(); timer = nil }
    }

    private func mix(_ a: RGB, _ b: RGB, _ k: Double) -> RGB {
        (Int(Double(a.r) + (Double(b.r) - Double(a.r)) * k), Int(Double(a.g) + (Double(b.g) - Double(a.g)) * k), Int(Double(a.b) + (Double(b.b) - Double(a.b)) * k))
    }
    /// 0…1 how much of the effect color this LED shows at `now`.
    private func intensity(_ e: Effect, _ u: String, _ led: LED, _ now: Date) -> Double {
        let t = now.timeIntervalSince(e.start), p = e.duration.isFinite ? t / e.duration : t
        switch e.kind {
        case .flash: // `count` short pulses of 80 ms each, 80 ms apart
            guard e.uuid == nil || e.uuid == u else { return 0 }
            let slot = Int(t / 0.08); return slot < e.count * 2 && slot % 2 == 0 ? 1 : 0
        case .wave: // a band 30 % wide crosses the board along x (direction follows the sign)
            let xs = leds.values.map(\.x), lo = xs.min() ?? 0, hi = xs.max() ?? 1
            var pos = hi > lo ? (led.x - lo) / (hi - lo) : 0.5; if e.direction < 0 { pos = 1 - pos }
            return max(0, 1 - abs(pos - (p * 1.6 - 0.3)) / 0.3)
        case .ripple: // ring spreading from `origin`, 1 cell per 0.15 s
            let o = e.origin ?? (0, 0), d = ((led.x - o.x) * (led.x - o.x) + (led.y - o.y) * (led.y - o.y)).squareRoot()
            return max(0, 1 - abs(d - t / 0.15) / 1.2) * max(0, 1 - p)
        case .chain: // lights up by port hops from the Core, one hop per 25 % of the duration, then fades out together
            let hops = Double(leds.values.map(\.depth).max() ?? 0) + 1
            let on = p * hops * 1.3 - Double(led.depth); return on < 0 ? 0 : min(1, on) * (p < 0.7 ? 1 : max(0, (1 - p) / 0.3))
        case .breathe:
            guard e.uuid == nil || e.uuid == u else { return 0 }
            return 0.5 - 0.5 * cos(t * .pi / 1.2) // 2.4 s per breath
        case .starlight: // up to two random LEDs sparkle at a time, 0.4 s each
            if sparks.values.filter({ now.timeIntervalSince($0) < 0.4 }).count < 2, Int.random(in: 0..<6) == 0, let r = leds.keys.randomElement() { sparks[r] = now }
            return sparks[u].map { max(0, 1 - now.timeIntervalSince($0) / 0.4) } ?? 0
        }
    }
}
