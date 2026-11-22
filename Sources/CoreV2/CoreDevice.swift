import Foundation

/// Core V2 ("Condor") link: HDLC-style frames (0x7E flag, 0x7D escape ^0x20) carrying MessagePack maps.
/// Mirrors what the Monogram service sends and expects, observed from its wire traffic.
public final class CoreDevice {
    public enum State: Equatable { case closed, open }
    /// One module actuation: `i` = local id in tree order, `v` = raw value bytes.
    public struct Input { public let localId: Int; public let values: [Int]; public let noop: Bool }

    public var onState: ((State) -> Void)?
    public var onLayout: (([String: Any]) -> Void)?
    public var onInputs: (([Input]) -> Void)?
    public var onVersion: (([String: Any]) -> Void)?
    public var onFirmwareError: ((Int) -> Void)?
    public var onRaw: (([String: Any]) -> Void)? // every decoded frame, for debugging/comparison

    static let trace = ProcessInfo.processInfo.environment["COREV2_TRACE"] != nil
    public private(set) var state = State.closed
    public private(set) var layout: [String: Any]?
    public private(set) var version: [String: Any]?
    /// Local ids in tree (preorder) order, as the firmware numbers them.
    public var localIds: [Int] { layout.map(Self.ids) ?? [] }
    static func ids(_ n: [String: Any]) -> [Int] {
        [n["i"] as? Int].compactMap { $0 } + (n["c"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.flatMap(ids)
    }

    public let queue = DispatchQueue(label: "corev2")
    private var port: SerialPort?
    private var rx = Data()
    private var layoutTime: Any?
    private var timer: DispatchSourceTimer?

    public init() {}

    /// Keeps looking for the device every 2 s, reconnects after unplug.
    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 2)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel(); timer = nil
        queue.async { self.port?.close() }
    }

    private func tick() {
        if port != nil { send(["get_check": true]); return } // also triggers the firmware's layout consistency check
        guard let path = SerialPort.findCore(), let p = try? SerialPort(path: path, queue: queue) else { return }
        p.onData = { [weak self] in self?.receive($0) }
        p.onClose = { [weak self] in
            guard let self else { return }
            self.port = nil; self.layout = nil; self.version = nil
            self.set(.closed)
        }
        port = p
        set(.open)
        send(["get_check": true]) // first message may be lost while the firmware buffer settles
        send(["get_version": true])
        send(["get_layout": true])
    }

    private func set(_ s: State) { state = s; onState?(s) }

    // MARK: - Commands (same shapes the service encodes)

    public func send(_ msg: [String: Any]) {
        queue.async { [self] in
            if Self.trace { NSLog("tx %@", msg.description.prefix(160).description) }
            port?.write(Self.frame(msg))
        }
    }
    /// One screen image: replaces an image still being sent, and other messages go ahead of its chunks.
    public func sendScreen(_ msgs: [[String: Any]]) {
        queue.async { [self] in port?.writeScreen(msgs.map(Self.frame)) }
    }
    static func frame(_ msg: [String: Any]) -> Data {
        var f = Data([0x7e])
        for b in MsgPack.encode(msg) {
            if b == 0x7d || b == 0x7e { f.append(0x7d); f.append(b ^ 0x20) } else { f.append(b) }
        }
        f.append(0x7e)
        return f
    }

    public func getLayout() { send(["get_layout": true]) }
    public func getState(localId: Int) { send(["get_state": localId]) }
    public func setBrightness(moduleLED: Int, backlight: Int) { send(["set_brightness": [moduleLED, backlight]]) }
    /// `submodule` = index inside a 3x module or Core button; nil colors the whole module.
    public func setColor(localId: Int, r: Int, g: Int, b: Int, submodule: Int? = nil) {
        var v = r | g << 8 | b << 16
        if let s = submodule { v |= s << 24 }
        send(["set_module": [localId, submodule == nil ? 0x02 : 0x05, v]])
    }
    public func commitColor(localId: Int) { send(["set_module": [localId, 0x05, 0x7f << 24]]) }
    public func flip(localId: Int, _ flipped: Bool) { send(["set_module": [localId, 0xB1, flipped ? 1 : 0]]) }
    /// Orbiter: the Core computes tilt itself; 0xB2 = tilt sensitivity 1…5, 0xB5 = axis blend mode 0…2 (service's SET_OWL_OTHER_PROPERTIES)
    public func setOrbiter(localId: Int, sensitivity: Int, blend: Int) { send(["set_module": [localId, 0xB2, sensitivity]]); send(["set_module": [localId, 0xB5, blend]]) }
    public func setPowerMode(noAppStandby: Bool) { send(["set_power_mode": noAppStandby ? 1 : 0]) }
    public func clearActions(localIds: [Int]) { for id in localIds { send(["clear_action": id]) } }
    /// Firmware-side HID action (10 config bytes, see service's corev2-protocol encoders).
    public func addAction(localId: Int, config: [UInt8]) { send(["add_action": [localId, config.map(Int.init)]]) }

    // MARK: - Receive

    private func receive(_ d: Data) {
        rx.append(d)
        while let flag = rx.firstIndex(of: 0x7e) {
            let frame = rx[rx.startIndex..<flag]
            rx.removeSubrange(rx.startIndex...flag)
            if frame.isEmpty { continue }
            var raw = Data(); var esc = false
            for b in frame { if b == 0x7d { esc = true } else { raw.append(esc ? b ^ 0x20 : b); esc = false } }
            guard let m = (try? MsgPack.decode(raw)) as? [String: Any] else { NSLog("corev2: undecodable frame %@", raw.base64EncodedString()); continue }
            handle(m)
        }
    }

    private func handle(_ m: [String: Any]) {
        onRaw?(m)
        if let l = m["l"] as? [String: Any] {
            layout = l; layoutTime = m["l_time"]
            onLayout?(l)
        } else if let t = m["l_time"], let known = layoutTime, "\(known)" != "\(t)" {
            getLayout() // firmware layout changed behind our back (e.g. after sleep)
        }
        var inputs: [Input] = []
        for (key, noop) in [("in", false), ("in_noop", true)] {
            for case let a as [String: Any] in m[key] as? [Any] ?? [] { // Core pads with nulls
                if let i = a["i"] as? Int, let v = a["v"] as? [Int] { inputs.append(Input(localId: i, values: v, noop: noop)) }
            }
        }
        if !inputs.isEmpty { onInputs?(inputs) }
        if m["version_core"] != nil { version = m; onVersion?(m) }
        if let e = m["err"] as? Int { onFirmwareError?(e) }
    }
}
