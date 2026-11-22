import Foundation

/// A function a plugin offers (functions.json `inputs`, Docs/plugin-spec-v1.md).
public struct AppInput {
    public let name: String
    public let step: Double?, stepMin: Double?, range: [Double]?, reset: [Double]?, options: [String]?, screens: [String]?
    init?(_ j: Any) {
        if let s = j as? String { name = s; step = nil; stepMin = nil; range = nil; reset = nil; options = nil; screens = nil; return }
        guard let d = j as? [String: Any], let n = d["name"] as? String else { return nil }
        name = n
        step = num(d["step"]); stepMin = num(d["stepMin"])
        range = (d["range"] as? [Any])?.compactMap(num)
        reset = num(d["reset"]).map { [$0] } // shortcut: multi-axis (x/y/z) inputs are not supported
        options = d["options"] as? [String]
        screens = d["screens"] as? [String]
    }
}

public struct AppDef {
    public let id: String, name: String
    public let processIdentifiers: [String]  // bundle ids / exe names, lowercased
    public let connections: [[String: Any]]
    public let presets: [String: [[String: Any]]] // "button" | "dial" | "slider" | "orbiter"
    public let inputs: [String: AppInput]
    public let screens: [(key: String, names: [String])] // the app's own screens (Lightroom module, Resolve page), in the plugin's order
    public let recommended: [String: [String]]           // screen key ("" = no screen, or a screen without a list): preset labels to offer first
    public let labelScreens: [String: [String]]          // preset label: screens its function works on ([] or missing = anywhere)
    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? ""
        name = d["name"] as? String ?? id
        processIdentifiers = (d["processIdentifiers"] as? [String] ?? []).map { $0.lowercased() }
        connections = d["connections"] as? [[String: Any]] ?? []
        presets = d["presets"] as? [String: [[String: Any]]] ?? [:]
        var ins: [String: AppInput] = [:]
        if let dict = d["inputs"] as? [String: Any] { for (k, v) in dict { if let i = AppInput(v) { ins[k] = i } } }
        else if let arr = d["inputs"] as? [Any] { for v in arr { if let i = AppInput(v) { ins[i.name] = i } } }
        inputs = ins
        let sc = d["screens"] as? [[String: Any]] ?? []
        screens = sc.compactMap { s in (s["key"] as? String).map { ($0, [s["name"] as? String ?? $0]) } }
        var rec = ["": d["recommended"] as? [String] ?? []]
        for s in sc { if let k = s["key"] as? String, let r = s["recommended"] as? [String] { rec[k] = r } }
        recommended = rec
        var ls: [String: [String]] = [:]
        for p in presets.values.joined() {
            guard let label = p["label"] as? String, let i = p.values.lazy.compactMap({ ($0 as? [String: Any])?["input"] as? String }).first(where: { ins[$0]?.screens != nil }) else { continue }
            ls[label] = ins[i]?.screens
        }
        labelScreens = ls
    }
    public func preset(_ type: String, named: String) -> [String: Any]? { presets[type]?.first { $0["name"] as? String == named } }
}

func num(_ v: Any?) -> Double? { (v as? NSNumber).map { $0.doubleValue } }

/// Every plugin folder (Docs/plugin-spec-v1.md): the ones shipped inside the app, then the user's, which replace a shipped one with the same id.
/// The host has no app list of its own; what it can control is what these folders say.
public final class Catalog {
    public static let specVersion = 1
    public static let userDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Knobtile/Plugins")
    /// Only "system" ships inside the app; every app plugin (the repo's Plugins/ folder) is installed by copying its folder into userDir.
    public static var dirs: [URL] = [Bundle.module.resourceURL!.appendingPathComponent("Plugins"), userDir]
    /// The installed plugins, read once. What has no engine at hand (shortcut names, screen tables) reads this one. (var: the tests load the repo's Plugins/ instead of the user's.)
    public static var shared = Catalog()
    public private(set) var apps: [AppDef] = []
    public private(set) var raw: [[String: Any]] = []   // as loaded, for the UI's preset browser
    public private(set) var keys: [String: [[String: Any]]] = [:] // plugin id: its keys.json

    public init(dirs: [URL] = Catalog.dirs) {
        for root in dirs {
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for dir in folders.sorted(by: { $0.path < $1.path }) {
                guard let d = Self.plugin(dir), let id = d["id"] as? String else { continue }
                apps.removeAll { $0.id == id }; raw.removeAll { $0["id"] as? String == id }
                apps.append(AppDef(d)); raw.append(d); keys[id] = d["keys"] as? [[String: Any]]
            }
        }
    }

    /// One plugin folder as an app definition, or nil when it is not a plugin this host can read.
    /// What is installed in the user's folder right now (the running app still uses what it read at launch): folder, id, name.
    public static var installed: [(dir: URL, id: String, name: String)] {
        ((try? FileManager.default.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }.compactMap { d in
            plugin(d).flatMap { p in (p["id"] as? String).map { (d, $0, p["name"] as? String ?? $0) } }
        }
    }
    /// Copies a plugin folder into `to` (the user's folder), replacing an installed one with the same id. Nil = not a plugin this version can read.
    @discardableResult public static func install(_ folder: URL, to: URL = userDir) -> String? {
        let fm = FileManager.default
        guard let p = plugin(folder), let id = p["id"] as? String, !id.isEmpty, folder.deletingLastPathComponent().standardizedFileURL != to.standardizedFileURL else { return nil } // "" is System: never replaced from outside
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        for d in (try? fm.contentsOfDirectory(at: to, includingPropertiesForKeys: nil)) ?? [] where d.lastPathComponent == folder.lastPathComponent || plugin(d)?["id"] as? String == id { try? fm.removeItem(at: d) }
        do { try fm.copyItem(at: folder, to: to.appendingPathComponent(folder.lastPathComponent)) } catch { NSLog("plugin install: %@", "\(error)"); return nil }
        return p["name"] as? String ?? id
    }

    static func plugin(_ dir: URL) -> [String: Any]? {
        func json(_ n: String) -> Any? { (try? Data(contentsOf: dir.appendingPathComponent(n))).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("plugin.json").path) else { return nil }
        guard let p = json("plugin.json") as? [String: Any], let id = p["id"] as? String, let spec = (p["spec"] as? NSNumber)?.intValue, spec <= specVersion else {
            NSLog("plugin %@: plugin.json unreadable, without id, or written for a newer spec", dir.lastPathComponent); return nil
        }
        var d: [String: Any] = ["id": id, "name": p["name"] as? String ?? id, "processIdentifiers": p["apps"] as? [String] ?? [],
                                "screens": p["screens"] ?? [], "recommended": p["recommended"] ?? []]
        if let c = p["connect"] as? [String: Any] {
            if c["type"] as? String == "run" { d["connections"] = [["name": "run", "type": "run", "command": c["command"] ?? [], "dir": dir.path]] }
            else if c["type"] as? String == "tcp", let port = c["port"] {
                d["connections"] = [["name": "main", "type": "tcp", "port": port]] + ((c["valuesPort"]).map { [["name": "values", "type": "tcp", "port": $0, "receive": true]] } ?? [])
            }
        }
        let f = json("functions.json") as? [String: Any] ?? [:]
        let inputs = (f["inputs"] as? [[String: Any]] ?? []).filter { ($0["name"] as? String)?.contains(where: { $0 == "\t" || $0 == "\n" }) == false }
        var presets = f["presets"] as? [String: [[String: Any]]] ?? [:]
        // Presets are optional: an input no preset of a kind names gets the plain one (dial and slider with a range, button without).
        func named(_ type: String) -> Set<String> { Set((presets[type] ?? []).flatMap { $0.values.compactMap { ($0 as? [String: Any])?["input"] as? String } }) }
        let dials = named("dial"), sliders = named("slider"), buttons = named("button")
        for i in inputs {
            guard let name = i["name"] as? String else { continue }
            let label = i["label"] as? String ?? name
            if let r = i["range"] as? [Any], r.count == 2 {
                let step = num(i["step"]) ?? 1
                var dial: [String: Any] = ["name": name, "label": label, "turn": ["input": name, "step": step], "pressAndTurn": ["input": name, "step": step * 10]]
                if i["reset"] != nil { dial["press"] = ["input": name, "action": "reset"] }
                if !dials.contains(name) { presets["dial", default: []].append(dial) }
                if !sliders.contains(name) { presets["slider", default: []].append(["name": name, "label": label, "pose": ["input": name, "range": r]]) }
            } else if !buttons.contains(name) {
                if let o = i["options"] as? [String] { for v in o { presets["button", default: []].append(["name": name + "=" + v, "label": label + ": " + v, "press": ["input": name, "action": "apply", "param": [v]]]) } }
                else { presets["button", default: []].append(["name": name, "label": label, "press": ["input": name]]) }
            }
        }
        d["inputs"] = Dictionary(inputs.compactMap { i in (i["name"] as? String).map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
        d["presets"] = presets
        if let k = json("keys.json") as? [[String: Any]] { d["keys"] = k }
        // optional: profiles to begin with, in the app's own export format; "starter.ko.json" is the same in the user's language, when there is one
        if let s = (json("starter.\(Language.code).json") ?? json("starter.json")) as? [String: Any] { d["starter"] = s }
        return d
    }

    public func app(_ id: String?) -> AppDef? { apps.first { $0.id == (id ?? "") } }
    /// True when the profile uses a function of an app whose plugin is not installed: those controls do nothing until it is.
    /// Keys, scrolling and System functions work without one, so a keys-only profile (Photoshop) is not marked.
    /// shortcut: reads the {"input": …} form, "send" and a named preset; the bare-string and ["name", "action"] forms only occur inside plugin presets today.
    public func missing(_ profile: [String: Any]) -> Bool { missingApp(profile) != nil }
    /// The id of that app (a control can name another app than the profile's own).
    public func missingApp(_ profile: [String: Any]) -> String? {
        func walk(_ o: Any, _ app: String) -> String? {
            if let a = o as? [Any] { return a.lazy.compactMap { walk($0, app) }.first }
            guard let d = o as? [String: Any] else { return nil }
            let a = (d["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? app // "" = the profile's own app, as the decoder reads it
            if !a.isEmpty, self.app(a) == nil {
                if let i = d["input"] as? String, self.app("")?.inputs[i] == nil, System.mediaKeys[i] == nil { return a }
                if d["send"] is String || !(d["preset"] as? String ?? "").isEmpty { return a }
            }
            return d.values.lazy.compactMap { walk($0, a) }.first
        }
        return walk(profile["assignments"] ?? [:], profile["app"] as? String ?? "")
    }
    public func apps(forBundle bundle: String) -> [AppDef] { apps.filter { $0.processIdentifiers.contains(bundle.lowercased()) } }
    public var screens: [String: [(key: String, names: [String])]] { Dictionary(uniqueKeysWithValues: apps.filter { !$0.screens.isEmpty }.map { ($0.id, $0.screens) }) }
}
