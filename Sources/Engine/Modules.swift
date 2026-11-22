import Foundation
import CoreV2

/// Input decoding per module type id (t & 0x1f), from the service's module classes.
/// Each physical node yields submodules addressed as `<uuid>` or `<uuid>::<name>`.
struct Submodule {
    enum Kind: String { case button, dial, slider, orbiter }
    let uuid: String, kind: Kind, ledIndex: Int?
    /// Pull this submodule's raw state from the node's `v` bytes: button → [pressed]; dial → [pressed, ticks, tapped]; slider → [pos]; orbiter → [ringTicks, tiltX, tiltY] (tilt −127…127, Core-computed)
    let read: ([Int]) -> [Int]
}

/// `turn` = quarter turns clockwise as the module lies on the desk (board pose + 전체 돌리기); 1 = connector on the left, the body's own order.
/// "판에 보이는 대로": names count left→right / top→bottom and the Orbiter tilts in screen axes, whichever way the module is plugged in.
func submodules(node uuid: String, typeId: Int, turn: Int = 1) -> [Submodule] {
    let e = (turn % 4 + 4) % 4, flip = e == 0 || e == 3 // control 1 is at the connector end (verified): connector at the bottom or right reads backwards
    func at(_ i: Int) -> Int { flip ? 2 - i : i }
    func slide(_ v: Int) -> Int { flip ? 255 - v : v } // shortcut: "a slider grows away from its connector" is assumed, no slider owned; check on one and drop the flip if wrong
    func bit(_ v: [Int], _ b: Int) -> Int { (v.first ?? 0) >> b & 1 }
    func signed(_ x: Int) -> Int { x > 128 ? x - 256 : x }
    switch typeId & 0x1f {
    case 0, 25: return (0..<2).map { i in Submodule(uuid: "\(uuid)::button\(i + 1)", kind: .button, ledIndex: nil) { [bit($0, i)] } }
    case 1: return [Submodule(uuid: uuid, kind: .button, ledIndex: nil) { [$0.first ?? 0] }]
    case 2: return [Submodule(uuid: uuid, kind: .dial, ledIndex: nil) { v in [v[0], v[1] == 0 ? v[2] : -v[1], v.count > 5 ? v[5] : 0] }]
    case 3: return [Submodule(uuid: uuid, kind: .slider, ledIndex: nil) { [slide($0.first ?? 0)] }]
    case 8: return (0..<3).map { i in Submodule(uuid: "\(uuid)::button\(i + 1)", kind: .button, ledIndex: at(i)) { [bit($0, at(i))] } }
    case 9: return (0..<3).map { i in Submodule(uuid: "\(uuid)::dial\(i + 1)", kind: .dial, ledIndex: at(i)) { v in [bit(v, at(i)), signed(v[at(i) + 1]), bit(v, at(i) + 4)] } }
    case 10: return (0..<3).map { i in Submodule(uuid: "\(uuid)::slider\(i + 1)", kind: .slider, ledIndex: at(i)) { [slide($0[at(i) + 1])] } }
    case 24: return [Submodule(uuid: uuid, kind: .orbiter, ledIndex: nil) { v in
        // tilt out as (screen right, screen up). The sensor axes are the screen axes with the connector at the top (user report 2026-11-14: connector at the bottom read a quarter turn off with the earlier table). shortcut: only that one direction was looked at on the device
        let x = signed(v[5]), y = signed(v[6]), t = [(-x, -y), (-y, x), (x, y), (y, -x)][e]
        return [signed(v[0]), t.0, t.1] }] // Owl: v[1..4] raw magnet field unused, v[7] always 0
    default: NSLog("unsupported module type %d (%@)", typeId, uuid); return [] // shortcut: FalconMini not ported yet
    }
}

/// Runtime state machine for one submodule, driven by raw actuations. Timing constants are the service's.
final class ModuleRuntime {
    let sub: Submodule
    var settings: [String: Action] = [:]
    var sensitivity = 9           // dial: threshold = 1 << (9 - sensitivity) ticks per event
    var simplePress = true        // button: press fires on down when no hold/down/up handlers exist
    var autorepeat = false
    var doubleDelay = 0.25        // seconds a single press waits for a second one (preference "doubleDelay", ms)
    var holdDelay = 0.5           // button: seconds before pressAndHold fires (service: 500 ms)
    var nudgeSpeedMs = 50.0       // orbiter: tilt nudges are batched at this rate (service default 50, presets usually 15)

    private var pressed = false, tapped = false
    var isPressed: Bool { pressed }
    private var holdTimer: Timer?, repeatTimer: Timer?, holdFired = false
    private(set) var position = 128.0 // dials are endless: start mid-band so a changing LED color has room both ways (a slider reports its own)
    /// A reset preset ran: the app's value is back at its default, so the ring's own position is too (keeps the value-band color honest).
    func recenter() { position = 128 }
    private var nudgeAcc = 0, numTicksWhilePressed = 0, pressAndTurn = false, postPressPause = false
    private var lastTap: Date?
    private var pressTimer: Timer? // doublePress: a single press waits 250 ms for a second one
    var tiltDeadzone = 0.0, tiltSmoothing = 0.0 // 0…1, applied before nudges so the app sees the same tilt the indicator shows
    private(set) var tilt = (x: 0.0, y: 0.0)
    private var tiltAcc = (x: 0.0, y: 0.0), tiltTimer: Timer?, sinceNudge = 0.0

    init(_ sub: Submodule) { self.sub = sub }

    var onExec: ((String, Double, Bool) -> Void)? // event name, value, whether an action was bound (developer log)
    var muted = false // 패널 open on this control: its turns and its release pick in the panel, its own functions stay quiet
    var willExec: (() -> Bool)? // true: the profile's app is only now coming forward, the function waits for it
    func exec(_ key: String, _ v: Double = 0) {
        if muted { return }
        if let f = settings[key], willExec?() == true { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { f(v) } } else { settings[key]?(v) }
        onExec?(key, v, settings[key] != nil)
    }

    func actuate(_ raw: [Int], noop: Bool) {
        switch sub.kind {
        case .button: button(raw[0] != 0, noop: noop)
        case .dial: dial(pressed: raw[0] != 0, ticks: raw[1], tapped: raw[2], noop: noop)
        case .slider: slider(raw[0], noop: noop)
        case .orbiter: orbiter(ticks: raw[0], x: Double(raw[1]) / 127, y: Double(raw[2]) / 127, noop: noop)
        }
    }

    private func button(_ isPressed: Bool, noop: Bool) {
        guard isPressed != pressed, !noop else { return }
        pressed = isPressed
        if isPressed {
            holdFired = false
            exec("pressDown")
            if simplePress { exec("press") }
            holdTimer = Timer.scheduledTimer(withTimeInterval: holdDelay, repeats: false) { [weak self] t in
                // Decide behind whatever already waits on the main queue: when the app was busy, the release of a short press sits there,
                // and the overdue timer used to fire first and call it a hold (seen with holdDelay 0.8 s, 2026-11-15).
                DispatchQueue.main.async { [weak self] in
                    guard let self, pressed, holdTimer === t else { return }
                    holdFired = true; exec("pressAndHold")
                    if autorepeat { repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in self?.exec("press") } }
                }
            }
        } else {
            holdTimer?.invalidate(); repeatTimer?.invalidate()
            exec("pressUp")
            if !simplePress && !holdFired { press() }
        }
    }

    /// `press`, or with a doublePress handler: the first release arms a `doubleDelay` timer, a second release inside it fires doublePress instead.
    private func press() {
        guard settings["doublePress"] != nil, !muted else { exec("press"); return }
        if pressTimer != nil { pressTimer?.invalidate(); pressTimer = nil; exec("doublePress"); return }
        pressTimer = Timer.scheduledTimer(withTimeInterval: doubleDelay, repeats: false) { [weak self] _ in self?.pressTimer = nil; self?.exec("press") }
    }

    private func dial(pressed isPressed: Bool, ticks rawTicks: Int, tapped isTapped: Int, noop: Bool) {
        guard !noop else { return }
        let wasPressed = pressed, wasTapped = tapped
        pressed = isPressed; tapped = isTapped != 0
        var ticks = postPressPause ? 0 : rawTicks
        position = min(255, max(0, position + Double(ticks)))
        if tapped && !wasTapped {
            if let t = lastTap, Date().timeIntervalSince(t) < 0.6 { exec("doubleTap"); lastTap = nil } else { lastTap = Date() }
        }
        if ticks != 0 {
            exec("pose", position)
            nudgeAcc += ticks
            let threshold = 1 << (9 - min(9, max(0, sensitivity)))
            guard abs(nudgeAcc) >= threshold else { return }
            ticks = nudgeAcc / threshold; nudgeAcc -= ticks * threshold
        }
        if pressed {
            if !wasPressed { numTicksWhilePressed = 0; pressAndTurn = false; exec("pressDown") }
            if !pressAndTurn { numTicksWhilePressed += ticks; if abs(numTicksWhilePressed) > 2 { pressAndTurn = true } }
            if ticks != 0 && pressAndTurn { exec("pressAndTurn", Double(ticks)); exec(ticks < 0 ? "pressAndLeftTurn" : "pressAndRightTurn") }
        } else {
            if wasPressed {
                exec("pressUp")
                if !pressAndTurn { press() }
                postPressPause = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.postPressPause = false }
            }
            if ticks != 0 { exec("turn", Double(ticks)); exec(ticks < 0 ? "leftTurn" : "rightTurn") }
        }
    }

    /// Ring turns like a dial without a press; tilt is converted to dial-equivalent ticks every 10 ms (service's Owl nanny) and flushed every nudgeSpeedMs.
    private func orbiter(ticks: Int, x: Double, y: Double, noop: Bool) {
        guard !noop else { return }
        if ticks != 0 {
            nudgeAcc += ticks
            let threshold = 1 << (9 - min(9, max(0, sensitivity)))
            if abs(nudgeAcc) >= threshold { let t = nudgeAcc / threshold; nudgeAcc -= t * threshold; exec("turn", Double(t)); exec(t < 0 ? "leftTurn" : "rightTurn") }
        }
        func f(_ a: Double, _ prev: Double) -> Double { let v = prev + ((abs(a) < tiltDeadzone ? 0 : a) - prev) * (1 - tiltSmoothing); return abs(v) < 0.01 ? 0 : v }
        tilt = (f(x, tilt.x), f(y, tilt.y))
        if tiltTimer == nil, x != 0 || y != 0 {
            tiltTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                func toTicks(_ a: Double) -> Double { abs(a) <= 0.02 ? 0 : (4 * a * a + 1) * a / 0.3 * 0.1 } // Owl._scaledValToTicks at a 10 ms rate
                tiltAcc.x += toTicks(tilt.x); tiltAcc.y += toTicks(tilt.y); sinceNudge += 10
                guard sinceNudge >= nudgeSpeedMs else { return }
                sinceNudge = 0
                if tiltAcc.x != 0 { exec("tiltX", tiltAcc.x) }; if tiltAcc.y != 0 { exec("tiltY", tiltAcc.y) }
                tiltAcc = (0, 0)
                if tilt.x == 0 && tilt.y == 0 { t.invalidate(); tiltTimer = nil } // hardware already applied its deadzone: 0 means at rest
            }
        }
    }

    private func slider(_ raw: Int, noop: Bool) {
        let pos = raw == 1 ? 0 : raw == 254 ? 255 : raw // older sliders miss the extremes
        guard Double(pos) != position else { return }
        position = Double(pos)
        if !noop { exec("pose", position) }
    }
}
