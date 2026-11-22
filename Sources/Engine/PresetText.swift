import Foundation

/// What the wiring screen says about a preset: its section (first label segment), the screens it is meant for, and a
/// one-line description of what each gesture does. Pure functions over the plugins' lists.
public enum PresetText {
    public static func section(_ label: String) -> String { label.contains(".") ? label.components(separatedBy: ".")[0] : "" }
    /// Label without its section: ("White Balance: As Shot") or ("Flag", "Toggle Pick") when a sub-group sits between.
    public static func name(_ label: String) -> (group: String, name: String) {
        let parts = label.components(separatedBy: ".")
        guard parts.count > 1 else { return ("", label) }
        return (parts.dropFirst().dropLast().joined(separator: " · "), parts.last!)
    }

    /// Screens (Engine.screens keys) a preset belongs to, as its function's `screens` says; [] = works anywhere (앱 어디서나). nil = app without screens.
    public static func screens(app: String, label: String) -> [String]? {
        guard let a = Catalog.shared.app(app), !a.screens.isEmpty else { return nil }
        return a.labelScreens[label] ?? []
    }

    /// The plugin's starting points for a screen ("" = profile without a screen), shown as ★ 추천 in the wiring search row.
    public static func recommended(app: String, screen: String) -> [String] {
        guard let r = Catalog.shared.app(app)?.recommended else { return [] }
        return r[screen] ?? r[""] ?? []
    }

    /// "돌리기 ±1 · 누르고 돌리기 ±10 · 누름 리셋" for a dial; "⌘E" for a shortcut button; "범위 2400~12000" for a slider.
    public static func describe(_ p: [String: Any], type: String) -> String {
        var parts: [String] = []
        func add(_ title: String, _ v: Any?, label: Bool = true) {
            guard let v, let a = action(v, step: title.contains(L("돌리기"))), !a.isEmpty else { return }
            parts.append(title.isEmpty || !label ? a : title + " " + a)
        }
        switch type {
        case "dial":
            add(L("돌리기"), p["turn"]); add(L("누르고 돌리기"), p["pressAndTurn"])
            if let l = p["leftTurn"], let r = p["rightTurn"] { parts.append("← \(action(l) ?? "") · → \(action(r) ?? "")") }
            add(L("누름"), p["press"]); add(L("더블탭"), p["doubleTap"])
        case "button": // label already names plain inputs; only shortcuts, macros and steps add information
            if let d = p["press"] as? [String: Any], d["input"] != nil { break }
            add("", p["press"])
        case "slider":
            if let r = (p["pose"] as? [String: Any])?["range"] as? [Any], r.count == 2 { parts.append(L("범위 \(fmt(r[0]))~\(fmt(r[1]))")) }
        case "orbiter":
            for (t, k) in [("↔", "tiltX"), ("↕", "tiltY"), (L("돌리기"), "turn")] { if let d = p[k] as? [String: Any], let i = d["input"] as? String { parts.append("\(t) \(inputName(i))") } }
        default: break
        }
        return parts.joined(separator: " · ")
    }

    /// One gesture's effect: a step ("±1"), a value ("리셋", "다음 사진", "Auto"), a key chord ("⇧⌘S") or a macro.
    static func action(_ v: Any, step: Bool = false) -> String? {
        if let d = v as? [String: Any] {
            if let k = d["key"] as? String { return chord(k, d["modifiers"] as? [String] ?? []) }
            if let id = d["keys"] as? String { return Keymap.find(id)?.label ?? id }
            if d["macro"] != nil { return L("매크로") }
            if let s = d["step"], step { return "±\(fmt(s))" }
            if let i = d["input"] as? String { return i.contains(" = ") ? value(i.components(separatedBy: " = ").last!) : (step ? "" : inputName(i)) }
            return nil
        }
        if let a = v as? [Any], a.count == 2, let op = a[1] as? String { return value(op) }
        if let s = v as? String { return inputName(s) }
        return nil
    }
    static func value(_ s: String) -> String {
        switch s.trimmingCharacters(in: .whitespaces).lowercased() {
        case "", "toggle": return L("토글")
        case "reset": return L("리셋"); case "increment": return L("+1 단계"); case "decrement": return L("−1 단계")
        case "nextphoto": return L("다음 사진"); case "previousphoto": return L("이전 사진")
        default: return s.trimmingCharacters(in: .whitespaces)
        }
    }
    static func inputName(_ i: String) -> String { i.components(separatedBy: " = ")[0].components(separatedBy: ".").last ?? i }
    static func chord(_ key: String, _ mods: [String]) -> String {
        let m = ["ctrl": "⌃", "control": "⌃", "alt": "⌥", "option": "⌥", "shift": "⇧", "meta": "⌘", "cmd": "⌘", "command": "⌘"]
        return ["ctrl", "alt", "shift", "meta"].filter { k in mods.contains { m[$0.lowercased()] == m[k] } }.map { m[$0]! }.joined() + (key.count == 1 ? key.uppercased() : key)
    }
    static func fmt(_ v: Any) -> String { let d = num(v) ?? 0; return d == d.rounded() ? String(Int(d)) : String(d) }
}
