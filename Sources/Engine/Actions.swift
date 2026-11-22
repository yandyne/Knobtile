import Foundation

/// What a module setting does when actuated. `value` is ticks (nudge), 0…255 position (set) or unused (pulse).
public typealias Action = (_ value: Double) -> Void
public enum ActionKind { case pulse, nudge, set }

/// Decodes preset/assignment setting JSON into executable actions, following the service's
/// *Setting.decode rules: macro → system (volume/brightness/scroll/cursor/media) → key/click → dispatch/ui → native app input.
struct ActionDecoder {
    let catalog: Catalog
    let appId: String
    let appLink: AppLink
    let dispatch: (String) -> Void       // NEXT_PROFILE / PREVIOUS_PROFILE
    let ui: (String) -> Void             // SHOW_LAYOUT_PREVIEW / HIDE_LAYOUT_PREVIEW
    var fail: (String) -> Void = { NSLog("%@", $0) } // something that could not be done (developer log)

    /// 다이얼 가속: multiplier for a turn of `ticks` that came `dt` seconds after the previous one. Slow turning stays 1 (one step per tick), fast goes up to 4.
    /// shortcut: 30 ticks/s as "slow" is a guess from 96 ticks per turn, not measured on a dial; tune the divisor if 가속 kicks in too early or too late.
    static func accel(ticks: Double, dt: Double) -> Double { min(4, max(1, abs(ticks) / max(dt, 0.005) / 30)) }

    func decode(_ json: Any?, kind: ActionKind) -> Action? {
        guard let json, !(json is NSNull) else { return nil }
        if let d = json as? [String: Any] {
            if let macro = d["macro"] as? [Any] {
                let interval = num(d["interval"]) ?? 300
                let items = macro.compactMap { decode($0, kind: kind) }
                return { v in
                    for (i, a) in items.enumerated() { // same argument to every step, `interval` ms apart
                        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(interval) * i)) { a(v) }
                    }
                }
            }
            if let platform = d["mac"] { return decode(platform, kind: kind) }
            if kind == .nudge, d["accel"] as? Bool == true { // 가속: the wire's own check, off unless set
                var plain = d; plain["accel"] = nil
                guard let a = decode(plain, kind: kind) else { return nil }
                var last = Date.distantPast
                return { v in let now = Date(), f = Self.accel(ticks: v, dt: now.timeIntervalSince(last)); last = now; a(v * f) }
            }
            // 실행·글자·패널: one-shot only, so a turn or a tilt can never start an app per tick
            if let b = d["open"] as? String { return kind != .pulse ? nil : { _ in if !System.open(b) { fail(L("찾을 수 없음: \(b)")) } } }
            if let n = d["shortcut"] as? String { return kind != .pulse ? nil : { _ in System.shortcut(n, failed: fail) } }
            if let t = d["text"] as? String { return kind != .pulse ? nil : { _ in System.type(t) } }
            if let p = d["panel"] as? String { return kind != .pulse ? nil : { _ in dispatch("PANEL:" + p) } }
            // a line the plugin announced at run time ("@function": a develop preset by uuid)
            if let line = d["send"] as? String { let app = d["app"] as? String ?? appId, link = appLink; return kind != .pulse ? nil : { _ in link.send(app: app, input: line, operation: "", params: [], range: nil) } }
            let step = num(d["step"]) ?? 1, invert = d["invert"] as? Bool ?? false
            let sign = invert ? -1.0 : 1.0
            let input = d["input"] as? String ?? ""
            let scroll = d["scroll"] as? String ?? (input == "scroll_vertical" ? "vertical" : input == "scroll_horizontal" ? "horizontal" : "")
            if scroll == "vertical" || scroll == "horizontal" {
                let mods = d["modifiers"] as? [String] ?? []
                return { v in let n = Int(-v * step * sign); System.scroll(x: scroll == "horizontal" ? n : 0, y: scroll == "vertical" ? n : 0, mods: mods) }
            }
            if let axis = d["cursor"] as? String, axis == "x" || axis == "y" {
                return { v in let n = Int(v * step * sign); System.moveCursor(dx: axis == "x" ? n : 0, dy: axis == "y" ? n : 0) }
            }
            if input == "system.volume" {
                let range = (d["range"] as? [Any])?.compactMap(num) ?? [0, 100]
                switch kind {
                case .nudge: return { System.adjustVolume(by: $0 * step * sign) }
                case .set: return { System.setVolume(percent: range[0] + (range[1] - range[0]) * $0 / 255) }
                case .pulse: return { _ in System.adjustVolume(by: d["action"] as? String == "decrement" ? -5 : 5) }
                }
            }
            if input == "system.brightness" {
                return kind == .pulse ? { _ in System.adjustBrightness(by: d["action"] as? String == "decrement" ? -1 : 1) } : { System.adjustBrightness(by: $0 * step * sign) }
            }
            if System.mediaKeys[input] != nil { return { _ in System.mediaTap(input) } }
            if let id = d["keys"] as? String { // (51) a named shortcut: its key is looked up when it fires, so a re-key applies at once
                return { _ in if let k = Keymap.find(id) { System.keyTap(k.key, k.mods) } else { NSLog("unknown shortcut %@", id) } }
            }
            if let key = d["key"] as? String {
                let mods = d["modifiers"] as? [String] ?? []
                return { _ in System.keyTap(key, mods) }
            }
            if let click = d["click"] as? String {
                let double = d["double"] as? Bool ?? false
                return { _ in System.click(click, double: double) }
            }
            if let a = d["dispatch"] as? [String: Any], let t = a["type"] as? String { return { _ in dispatch(t) } }
            if let a = d["ui"] as? [String: Any], let t = a["type"] as? String { return { _ in ui(t) } }
            if !input.isEmpty {
                return native(input, action: d["action"] as? String ?? "__default", app: d["app"] as? String ?? appId,
                              step: num(d["step"]), invert: invert, range: (d["range"] as? [Any])?.compactMap(num),
                              param: (d["param"] as? [Any])?.first.map { "\($0)" }, kind: kind)
            }
            return nil
        }
        if let s = json as? String { return native(s, action: "__default", app: appId, step: nil, invert: false, range: nil, param: nil, kind: kind) }
        if let a = json as? [Any], a.count == 2, let i = a[0] as? String, let act = a[1] as? String {
            return native(i, action: act, app: appId, step: nil, invert: false, range: nil, param: nil, kind: kind)
        }
        return nil
    }

    /// A plugin's function (sent over its connection).
    private func native(_ name: String, action: String, app: String, step: Double?, invert: Bool, range: [Double]?, param: String?, kind: ActionKind) -> Action? {
        guard let appDef = catalog.app(app), let input = appDef.inputs[name] else { NSLog("unknown input '%@' for app '%@'", name, app); return nil }
        let link = appLink
        func send(_ op: String, _ params: [Any], range: [Double]? = nil) { link.send(app: app, input: name, operation: op, params: params, range: range) }
        switch action {
        case "reset":
            guard let r = input.reset else { return nil }
            return { _ in send("=", r) }
        case "increment", "decrement":
            guard let s = input.step else { return nil }
            return { _ in send("+", [action == "increment" ? s : -s]) }
        case "apply":
            let p = param ?? input.options?.first ?? ""
            return { _ in send("=", [p]) }
        default:
            switch kind {
            case .pulse: return { _ in send("", []) }
            case .nudge:
                guard let s = step ?? input.step else { return { _ in send("", []) } }
                let stepMin = input.stepMin ?? 0, sign = invert ? -1.0 : 1.0
                var acc = 0.0
                return { ticks in
                    guard ticks != 0 else { return }
                    acc += (s * ticks * 10000).rounded() / 10000 * sign
                    if abs(acc) >= stepMin { send("+", [acc], range: range); acc = 0 } // the wire's own 범위 (nil = the input's default) rides along; Lightroom clamps to it
                }
            case .set:
                guard let r = range ?? input.range, r.count == 2 else { return nil }
                return { to in send("=", [r[0] + (r[1] - r[0]) * to / 255], range: r) } // shortcut: non-linear scales (lightroomTemperature) treated as linear
            }
        }
    }
}
