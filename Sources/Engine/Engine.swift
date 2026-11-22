import Foundation
import AppKit
import CoreV2
import ApplicationServices

/// Native replacement for the Monogram service: Core driver + profiles + action execution + app links.
public final class Engine {
    public let device = CoreDevice()
    public let catalog = Catalog.shared
    public let store: Store
    public let appLink: AppLink
    public var onPreview: ((Bool) -> Void)?          // SHOW/HIDE_LAYOUT_PREVIEW from Core buttons
    /// 화면 패널 (OSD): open while a control is held (a wire's {"panel": kind}, or the older dispatch PROFILE_SWITCHER); its release picks.
    /// kind: "profiles" (묶음 in sidebar order), "pages", "stack:<host>", "list:<name>" (직접 만든 목록, Store.panels), "map" (no items: the board, read only).
    public struct Panel: Equatable {
        public struct Item: Equatable { public let label: String; public var note = ""; public var app: String? = nil } // app: draw this app's icon
        public let kind, title: String; public let items: [Item]; public let index: Int
    }
    public private(set) var panel: Panel? { didSet { if panel != oldValue { onPanel?(panel) } } }
    public var onPanel: ((Panel?) -> Void)?
    private var panelRun: [() -> Void] = []                      // what picking each item does
    private var panelOwner: ModuleRuntime?                       // the held control; its release commits
    private var panelTicks = 0                                   // the owner dial's turn since the last step
    public static func shortcutNames() -> [String] { System.shortcuts() } // blocks for a moment: call off the main thread
    public static let modSymbols = ["command": "⌘", "meta": "⌘", "shift": "⇧", "alt": "⌥", "option": "⌥", "control": "⌃", "ctrl": "⌃"]
    /// Develop presets our Lightroom plugin listed (uuid, "folder / name"), for the function picker. Empty until the plugin answered.
    /// Functions a plugin announced at run time ("@function": Lightroom's develop presets), by plugin id. A wire sends `line` back as it is.
    public private(set) var functions: [String: [(line: String, label: String)]] = [:]
    // 번갈아 실행 ({"alternate": [A, B]}): wires whose next press runs B, per profile, for this run of the app ("profileId|uuid|slot")
    private var alternated: Set<String> = []
    private var altLed: [String: (slot: String, on: RGB?, base: RGB)] = [:] // uuid → its alternate wire's slot, B 차례 색, assigned color
    private var keyTap: CFMachPort?                              // ← → esc while the switcher is open
    public var onLayout: (([String: Any]?) -> Void)?
    public var onInput: (([CoreDevice.Input]) -> Void)?   // debugging hook
    /// 디자인 모드: everything runs inside Knobtile, nothing is sent to the Mac or an app (System.sink). Not saved: a restart is 실행.
    public var designMode = false { didSet { System.design = designMode } }
    public var onActive: ((String, Bool) -> Void)?  // submodule uuid, true while a button is held / false on release; dial ticks send true only
    public var onDialValue: ((String, Double, Double) -> Void)?  // submodule uuid, 0…1 inside the range its turn is bound to, the value itself: where the app says it is now
    public var onDisplay: ((String, NSImage?) -> Void)?           // what the Core display is told to show (title, icon), also while unplugged
    public var onPose: ((String, Int, Double, Double) -> Void)?  // dial/orbiter indicator: uuid, ring ticks this report, tilt x, tilt y (−1…1)
    public var onRaw: ((String, [Int]) -> Void)?                 // developer view: decoded raw per submodule, every non-noop report
    public var onEvent: ((Event) -> Void)?                       // developer log: every runtime event, bound or not
    public struct Event { public let time = Date(); public let uuid, name: String; public let value: Double; public let action: String? } // action = bound setting as text, nil if none
    private var actionText: [String: [String: String]] = [:]     // submodule uuid → event → text of the bound setting
    /// Slots in effect per submodule after root inheritance, and which of them came from the root (for the inspector).
    public private(set) var effective: [String: [String: Any]] = [:]
    public private(set) var inheritedSlots: [String: Set<String>] = [:]
    public var onStoreChange: (() -> Void)?                // after profiles/preferences changed and were applied

    var runtimes: [String: ModuleRuntime] = [:]          // submodule uuid → runtime
    private var byLocalId: [Int: (uuid: String, typeId: Int, subs: [Submodule])] = [:]
    private var led: [String: (localId: Int, index: Int?)] = [:]   // submodule uuid → where its LED lives
    private var activeProfileId = ""
    // 켜짐 방식 (모듈 설정 buttonMode: "toggle" 켜짐 유지 / "one" 하나만 켜짐): which buttons are on, per profile, for this run of the app.
    // shortcut: the app's real state is not read back, so a tool changed by mouse leaves the light stale; press the button again to match.
    private(set) var lit: Set<String> = []        // "profileId|uuid"
    private var litColor: [String: RGB] = [:]     // full color of the active profile's stateful buttons (off shows it dimmed)
    private var offAction: [String: Action] = [:] // 끌 때
    private func litKey(_ u: String) -> String { (store.activeProfile["id"] as? String ?? "") + "|" + u }
    private func relight() {
        for (u, c) in litColor { leds.base[u] = lit.contains(litKey(u)) ? c : (c.r / 8, c.g / 8, c.b / 8) }
        for (u, a) in altLed { // B's turn: the wire's second color, or without one the assigned color dimmed
            let b = alternated.contains(litKey(u) + "|" + a.slot)
            leds.base[u] = !b ? a.base : a.on ?? (a.base.r / 8, a.base.g / 8, a.base.b / 8)
        }
        leds.flush()
    }
    private func buttonMode(_ node: String, _ assignments: [String: Any], _ appId: String) -> String {
        resolveSettings(assignments[node], type: "", appId: appId)["buttonMode"] as? String ?? "each"
    }
    private var holdOwner: ModuleRuntime?                        // control holding a 누르는 동안 page
    private var heldReturn: String?                              // profile to return to when it is released
    private var heldStack: (host: String, index: Int)?           // 스택 member to return to when it is released
    public let leds: Leds
    private var lastInput = Date(), idling = false, ledTimer: Timer?, hourShown = -1

    /// `storeURL`: alternate state.json (tests); nil = the user's own.
    public init(storeURL: URL? = nil) {
        leds = Leds(device: device)
        store = Store(catalog: catalog, url: storeURL)
        appLink = AppLink(catalog: catalog)
        appLink.onFunction = { [weak self] id, line, label in DispatchQueue.main.async { if self?.functions[id]?.contains(where: { $0.line == line }) != true { self?.functions[id, default: []].append((line, label)) } } }
        appLink.onScreen = { [weak self] id, key in DispatchQueue.main.async { self?.screenDetected(app: id, key) } }
        appLink.onValue = { [weak self] id, name, v, own in DispatchQueue.main.async { // a value the app reports: developer log, and the dials that turn it
            guard let self else { return }
            self.onEvent?(Event(uuid: id, name: name, value: v, action: nil))
            for (uuid, s) in self.effective {
                guard let t = s["turn"] as? [String: Any], let input = t["input"] as? String, input.components(separatedBy: "=")[0].trimmingCharacters(in: .whitespaces) == name,
                      let r = own ?? (t["range"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }) ?? self.catalog.app(id)?.inputs[input]?.range, r.count == 2, r[0] != r[1] else { continue }
                self.onDialValue?(uuid, (v - r[0]) / (r[1] - r[0]), v)
            }
        } }
        store.onChange = { [weak self] in
            if let s = self, s.boardTurn != s.lastTurn { s.layoutChanged(s.lastLayout) } // redecodes the modules and redraws the Core display
            self?.profileChanged(); self?.onStoreChange?() }
        device.onLayout = { [weak self] l in DispatchQueue.main.async { self?.layoutChanged(l) } }
        device.onInputs = { [weak self] ins in DispatchQueue.main.async { self?.inputs(ins) } }
        device.onState = { [weak self] s in DispatchQueue.main.async { if s == .closed { self?.layoutChanged(nil) } } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard System.dry == nil, let b = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            self?.frontmost(bundle: b)
        }
    }

    // MARK: Screen-linked profiles (Lightroom module / Resolve page ↔ profile `screen`)

    /// Per plugin id: the app's screens (Lightroom module, Resolve page) as its plugin.json lists them.
    public static var screens: [String: [(key: String, names: [String])]] { Catalog.shared.screens }
    private var screenTimer: Timer?
    private var screenDriven = false              // the poll is activating a profile: don't echo the switch back to the app
    private var seenScreen: String?, lastFront: String?
    private var screenWant: (key: String, until: Date)? // we told the app to switch: reads of any other screen are stale until it arrives (or 5 s pass)
    /// Asks the plugin of the app in front which screen it shows; the answer ("@screen") arrives at screenDetected.
    private func pollScreen() {
        guard System.dry == nil, let b = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        for a in catalog.apps(forBundle: b) where !a.screens.isEmpty { appLink.control(app: a.id, "@screen\t?", quiet: true) }
    }
    /// What the poll last saw: app id + screen key (shown in the sidebar bundle). nil until an app with screens is in front.
    public private(set) var screen: (app: String, key: String)? { didSet { if screen?.app != oldValue?.app || screen?.key != oldValue?.key { onScreen?() } } }
    public var onScreen: (() -> Void)?
    func screenDetected(app: String, _ key: String) {
        if let w = screenWant, Date() < w.until { if w.key != key { return } }
        screenWant = nil
        screen = (app, key)
        // Follow page changes, not the page itself: a page-less profile (the 묶음's default) picked while on a page with its own
        // profile must stay until the user moves to another page, or a new app comes forward.
        guard seenScreen != app + "/" + key else { return }
        seenScreen = app + "/" + key
        // Pages move only inside the active 묶음: a profile the user picked for another app stays put (the original never
        // follows the app either; crossing apps is autoProfileSwitchingEnabled's job in frontmost()).
        guard store.app(of: store.activeProfile) == app, store.activeProfile["screen"] as? String != key,
              let p = store.profile(app: app, screen: key), p["id"] as? String != store.activeProfile["id"] as? String else { return }
        screenDriven = true; store.activate(p["id"] as! String); screenDriven = false
    }
    /// The user picked a profile with a screen: the plugin brings its app to it.
    private func showScreen(of p: [String: Any]) {
        guard let app = p["app"] as? String, let key = p["screen"] as? String, Self.screens[app]?.contains(where: { $0.key == key }) == true,
              appLink.control(app: app, "@screen\t" + key) else { return }
        screenWant = (key, Date() + 5)
    }

    public func start() {
        screenTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pollScreen() }
        // Synthesized keystrokes/clicks need Accessibility; this prompts once.
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        device.start()
        if let b = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { frontmost(bundle: b) }
        ledTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.ledTick() }
    }

    // MARK: LED scenes, brightness, idle (preferences["led"]; see 계획.md LED 고급 색 / 장면)

    public static let ledDefaults: [String: Any] = ["brightness": 100, "night": 0, "idleMinutes": 5, "idleMode": "dim", "awayDim": true, "boot": true,
                                                    "welcome": true, "page": true, "pressFlash": true, "ripple": false, "hourly": false, "holdBreathe": true, "plug": true]
    private func led(_ key: String) -> Any? { (store.preferences["led"] as? [String: Any])?[key] ?? Self.ledDefaults[key] }
    private func ledOn(_ key: String) -> Bool { led(key) as? Bool ?? false }
    private var away: Bool { // the profile's app is not in front
        let p = store.activeProfile
        return !(p["app"] as? String ?? "").isEmpty && !store.compatibleBundles(p).contains(store.focus)
    }
    /// Base brightness, dimmed at night (22–07), while idle, or while the profile's app is not frontmost; the strongest dimming wins.
    private func applyBrightness() {
        var b = Int(num(led("brightness")) ?? 100)
        let h = Calendar.current.component(.hour, from: Date()), night = Int(num(led("night")) ?? 0)
        if night > 0, h >= 22 || h < 7 { b = min(b, night) }
        if idling, led("idleMode") as? String == "dim" { b = min(b, 20) }
        if ledOn("awayDim"), away { b = min(b, 30) }
        leds.brightness(b)
        let saved = led("balance") as? [String: Any] ?? [:] // 색 맞춤: hardware uuid → [r, g, b]
        leds.balance = byLocalId.reduce(into: [:]) { o, n in if let g = (saved[n.value.uuid] as? [Any])?.compactMap(num), g.count == 3 { o[n.key] = g } }
    }
    private func ledTick() {
        guard device.state == .open else { return }
        let minutes = num(led("idleMinutes")) ?? 5, mode = led("idleMode") as? String ?? "dim"
        if !idling, mode != "keep", Date().timeIntervalSince(lastInput) > minutes * 60 {
            idling = true
            if mode == "starlight" { leds.play(.init(kind: .starlight, color: (255, 255, 255), duration: .infinity)) }
            if mode == "breathe" { leds.play(.init(kind: .breathe, color: (0, 0, 0), duration: .infinity)) }
        }
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        if ledOn("hourly"), now.minute == 0, now.hour != hourShown { // 정시: one spark per hour on the clock
            hourShown = now.hour!; leds.play(.init(kind: .starlight, color: (255, 255, 255), duration: Double(max(1, now.hour! % 12 == 0 ? 12 : now.hour! % 12)) * 0.5))
        }
        applyBrightness()
    }
    private func wake() {
        lastInput = Date()
        guard idling else { return }
        idling = false; leds.stop(.starlight); leds.stop(.breathe, uuid: nil); applyBrightness()
    }
    /// Average color of the app's icon: the welcome sweep's color when the profile has none.
    static func dominant(_ image: NSImage?) -> RGB? {
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil), let d = cg.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return nil }
        var s = (r: 0, g: 0, b: 0, n: 0)
        let bpp = cg.bitsPerPixel / 8
        for y in stride(from: 0, to: cg.height, by: 4) { for x in stride(from: 0, to: cg.width, by: 4) {
            let i = y * cg.bytesPerRow + x * bpp
            guard p[i + 3] > 128 else { continue } // skip transparent corners
            let (r, g, b) = cg.bitmapInfo.contains(.byteOrder32Little) ? (p[i + 2], p[i + 1], p[i]) : (p[i], p[i + 1], p[i + 2])
            if max(r, g, b) - min(r, g, b) < 30 { continue } // greys don't count as the icon's color
            s.r += Int(r); s.g += Int(g); s.b += Int(b); s.n += 1
        } }
        return s.n > 0 ? (s.r / s.n, s.g / s.n, s.b / s.n) : nil
    }

    // MARK: Hardware

    /// 전체 돌리기: quarter turns clockwise of the whole assembly on the desk (one value for everything). Inputs, LED order and the Core display follow it.
    private var boardTurn: Int { Int(num(store.preferences["boardRotation"]) ?? 0) }
    private var lastLayout: [String: Any]?, lastTurn = 0
    private func layoutChanged(_ layout: [String: Any]?) {
        runtimes = [:]; byLocalId = [:]; led = [:]; store.hardware = [:]; lastTurn = boardTurn
        var nodes: [(Int, String, Int)] = []
        func walk(_ n: [String: Any], path: String) {
            if let u = n["u"] as? String, let i = n["i"] as? Int, let t = n["t"] as? Int {
                store.hardware[path] = (u, t)
                nodes.append((i, u, t))
            }
            for case let (k, c as [String: Any]) in (n["c"] as? [Any] ?? []).enumerated() { walk(c, path: path.isEmpty ? "\(k)" : path + "/\(k)") }
        }
        if let layout { walk(layout, path: "") }
        lastLayout = layout
        var board = Board.empty(coreU: store.hardware[""]?.u ?? "v:core", coreT: store.hardware[""]?.t ?? 25), table: [String: Leds.LED] = [:]
        for (path, h) in store.hardware.sorted(by: { $0.key.count < $1.key.count }) where !path.isEmpty { if let p = board.pose(at: path, t: h.t, u: h.u) { board.modules.append(p) } }
        for (i, u, t) in nodes {
                let subs = submodules(node: u, typeId: t, turn: (board.modules.first { $0.u == u }?.r ?? 1) + boardTurn)
                byLocalId[i] = (u, t, subs)
                for s in subs {
                    let rt = ModuleRuntime(s); runtimes[s.uuid] = rt; led[s.uuid] = (i, s.ledIndex)
                    // preference "activateAppOnInput": a control used while the profile's app is behind brings that app forward first
                    rt.willExec = { [weak self] in
                        guard let self, store.preferences["activateAppOnInput"] as? Bool == true, let a = store.activeProfile["app"] as? String, !a.isEmpty else { return false }
                        return bringForward(a)
                    }
                    rt.onExec = { [weak self] k, v, _ in guard let self, let h = onEvent else { return }; h(Event(uuid: s.uuid, name: k, value: v, action: actionText[s.uuid]?[k])) }
                }
        }
        // LED coordinates in board cells from the port paths (3x modules: three LEDs along the long axis), depth = hops from the Core
        for (path, h) in store.hardware {
            guard let i = byLocalId.first(where: { $0.value.uuid == h.u })?.key, let pose = board.modules.first(where: { $0.u == h.u }) else { continue }
            let depth = path.isEmpty ? 0 : path.split(separator: "/").count
            for s in byLocalId[i]!.subs {
                let d = Double((s.ledIndex ?? 1) - 1) * 0.6, off = [(0.0, d), (-d, 0.0), (0.0, -d), (d, 0.0)][pose.r % 4]
                table[s.uuid] = Leds.LED(localId: i, index: s.ledIndex, x: Double(pose.x) + Double(pose.w) / 2 + off.0, y: Double(pose.y) + Double(pose.h) / 2 + off.1, depth: depth)
            }
        }
        let wasOff = leds.leds.isEmpty, before = Set(leds.leds.keys)
        leds.reset(table)
        onLayout?(layout)
        activeProfileId = ""
        profileChanged()
        if layout != nil, wasOff, ledOn("boot") { leds.play(.init(kind: .chain, color: (255, 255, 255), duration: 2)) } // 부팅: Core → ports → their ports
        else if layout != nil, !wasOff, ledOn("plug"), let new = table.first(where: { !before.contains($0.key) })?.value { // 모듈 꽂기: 새 모듈 자리에서 물결
            leds.play(.init(kind: .ripple, color: (255, 255, 255), duration: 0.8, origin: (new.x, new.y)))
        }
    }

    private func inputs(_ ins: [CoreDevice.Input]) {
        onInput?(ins)
        if ins.contains(where: { !$0.noop }) { wake() }
        for i in ins {
            guard let node = byLocalId[i.localId] else { continue }
            for s in node.subs { handle(s, s.read(i.values), noop: i.noop) }
        }
    }
    /// One control's decoded report (ScenarioTests feeds these directly).
    func handle(_ s: Submodule, _ raw: [Int], noop: Bool) {
        let wasDown = runtimes[s.uuid]?.isPressed ?? false
        if let p = panel, p.kind != "map", !noop, s.kind == .button, raw[0] != 0, let rt = runtimes[s.uuid], rt !== panelOwner { // the other button steps the panel instead of its own action (맵 보기 leaves every control alone)
            // button 1 steps back, any other forward (with button 1 holding the list, every other one steps forward)
            if !wasDown { dispatch(s.uuid.hasSuffix("button1") && !(panelOwner?.sub.uuid ?? "").hasSuffix("button1") ? "SWITCHER_PREVIOUS" : "SWITCHER_NEXT") }
            return
        }
        // a list held open by a button: every dial and the Orbiter turn through it instead of doing their own thing (rehearsal 2026-11-15: they kept
        // scrolling and changing the volume under the list, and one button could only step backwards)
        if let p = panel, p.kind != "map", !noop, s.kind == .dial || s.kind == .orbiter, panelOwner?.sub.kind == .button {
            panelTicks += s.kind == .dial ? raw[1] : raw[0]
            while abs(panelTicks) >= 8 { dispatch(panelTicks > 0 ? "SWITCHER_NEXT" : "SWITCHER_PREVIOUS"); panelTicks -= panelTicks > 0 ? 8 : -8 }
            return
        }
        if panel != nil, !noop, s.kind == .dial, let rt = runtimes[s.uuid], rt === panelOwner { // 누른 채 돌리기: the owner dial steps through the list
            // shortcut: 8 ticks per item (30° if a turn is 96 ticks) is not checked on a dial; change the divisor if the list moves too fast or too slow
            panelTicks += raw[1]
            while abs(panelTicks) >= 8 { dispatch(panelTicks > 0 ? "SWITCHER_NEXT" : "SWITCHER_PREVIOUS"); panelTicks -= panelTicks > 0 ? 8 : -8 }
        }
        runtimes[s.uuid]?.actuate(raw, noop: noop)
        if let o = holdOwner, o === runtimes[s.uuid], raw[0] == 0 { holdOwner = nil; dispatch("RELEASE_SCREEN") }
        if let o = panelOwner, o === runtimes[s.uuid], raw[0] == 0 { panelOwner = nil; o.muted = false; dispatch("SWITCHER_COMMIT") }
        if !noop, s.kind == .button || s.kind == .dial, raw[0] != 0, !wasDown, let l = leds.leds[s.uuid] { // 누름 플래시 / 물결
            if ledOn("pressFlash") { leds.play(.init(kind: .flash, color: (255, 255, 255), duration: 0.16, uuid: s.uuid)) }
            if ledOn("ripple") { leds.play(.init(kind: .ripple, color: (255, 255, 255), duration: 0.6, origin: (l.x, l.y))) }
        }
        if !noop, s.kind != .slider { onActive?(s.uuid, raw.prefix(3).contains { $0 != 0 }) } // shortcut: sliders need a previous value to detect motion, add when one is owned
        if !noop { onRaw?(s.uuid, raw) }
        if !noop, s.kind == .dial { onPose?(s.uuid, raw[1], 0, 0) } else if s.kind == .orbiter, let t = runtimes[s.uuid]?.tilt { onPose?(s.uuid, raw[0], t.x, t.y) }
    }

    // MARK: Profile → module settings, LEDs, screen

    /// Asks the app where each dial's function is now, so the on-screen pointers start at the real values (profile load, plugin connect).
    /// `force`: ask although nothing changed (the plugin just connected). Otherwise only when the dials' functions changed: the store changes far more often than that.
    public func askValues(force: Bool = true) {
        let appId = store.activeProfile["app"] as? String ?? ""
        guard let app = catalog.app(appId) else { return }
        var inputs: [String: String] = [:] // uuid: input, sliders only: a command must never run from a question
        for (uuid, s) in effective {
            if let t = s["turn"] as? [String: Any], let input = t["input"] as? String, t["range"] != nil || app.inputs[input]?.range != nil { inputs[uuid] = input }
        }
        let now = [appId: inputs]
        if !force && now == asked { return }
        if now != asked { asked = now; onValuesReset?() }
        for input in Set(inputs.values) { appLink.send(app: appId, input: input, operation: "?", params: [], range: nil) }
    }
    private var asked: [String: [String: String]] = [:]
    public var onValuesReset: (() -> Void)? // the dials' functions changed: values shown for the old ones are stale

    /// Brings the app (catalog id or bundle id) forward if it runs and is not in front. True when it had to.
    @discardableResult private func bringForward(_ appId: String) -> Bool {
        let ids = Set((catalog.app(appId)?.processIdentifiers ?? []) + [appId.lowercased()])
        guard !ids.contains(System.frontBundle?.lowercased() ?? ""),
              let app = NSWorkspace.shared.runningApplications.first(where: { ids.contains($0.bundleIdentifier?.lowercased() ?? "") }) else { return false }
        if let dry = System.sink { dry("activate " + (app.bundleIdentifier ?? "")) }
        else if let u = app.bundleURL { NSWorkspace.shared.openApplication(at: u, configuration: .init()) } // not app.activate(): from a background app macOS 14+ ignores it
        return true
    }
    private var lastProfileId: String?
    private func profileChanged() {
        defer { askValues(force: false) }
        let p = store.activeProfile
        let appId = p["app"] as? String ?? ""
        // preference "activateAppOnProfile": a profile picked on the console brings its app forward, if it runs. Not at start, and not while
        // our own window is in front (picking a profile there is editing it).
        let pid = p["id"] as? String
        if let last = lastProfileId, last != pid, store.preferences["activateAppOnProfile"] as? Bool == true, !appId.isEmpty,
           System.frontBundle != Bundle.main.bundleIdentifier { bringForward(appId) }
        lastProfileId = pid
        let assignments = store.assignments(p)
        let decoder = self.decoder(appId)
        let rootAssignments = store.rootAssignments()
        litColor = [:]; offAction = [:]; altLed = [:]
        for (uuid, rt) in runtimes {
            let type = rt.sub.kind.rawValue
            let (settings, inherited) = merge(assignments[uuid], root: rootAssignments[uuid], kind: rt.sub.kind, appId: appId)
            effective[uuid] = settings; inheritedSlots[uuid] = inherited
            rt.settings = [:]
            for (key, kind) in Self.settingKinds[rt.sub.kind]! {
                var a = decoder.decode(settings[key], kind: kind)
                if kind == .pulse, let d = settings[key] as? [String: Any], let alt = d["alternate"] as? [Any], alt.count == 2 { // 번갈아 실행: A, then B, then A …
                    let ab = alt.map { decoder.decode($0, kind: .pulse) }, k = litKey(uuid) + "|" + key
                    if altLed[uuid] == nil { altLed[uuid] = (key, (d["color"] as? String).map(Self.ledColor), (255, 255, 255)) }
                    a = { [weak self] v in
                        guard let self else { return }
                        ab[alternated.contains(k) ? 1 : 0]?(v)
                        if alternated.remove(k) == nil { alternated.insert(k) }
                        relight()
                    }
                }
                guard let a else { continue }
                // 실행 후: right after the function is sent, this control's own display goes where the wire says (nothing is guessed from the function's name)
                if kind == .pulse, let then = (settings[key] as? [String: Any])?["then"] as? [String: Any] {
                    rt.settings[key] = { [weak self] v in a(v); self?.after(uuid, then, appId: appId) }
                } else { rt.settings[key] = a }
            }
            actionText[uuid] = Dictionary(uniqueKeysWithValues: Self.settingKinds[rt.sub.kind]!.compactMap { k, _ in settings[k].map { (k, Self.describe($0)) } })
            rt.sensitivity = Int(num(settings["sensitivity"]) ?? num(settings["turnSensitivity"]) ?? 9)
            // 데코레이션: the dial's position tints its own LED along the band the designer picked for this control (settings.deco: built-in or custom); not tied to the function.
            // Near the middle (the default value) the assigned color shows instead; a wire's 실행 후 (then.value) recenters the ring.
            if store.preferences["dynamicColorEnabled"] as? Bool ?? true, let band = Self.colorBand(settings["deco"]), led[uuid] != nil {
                let inner = rt.settings["pose"]
                rt.settings["pose"] = { [weak self] v in
                    inner?(v)
                    // 16 steps along the band: a new color on every tick floods the Core (other modules and the Core itself flicker).
                    // No red flash at the ends: a dial is endless, so its band position is not the function's real limit.
                    let t = (v / 16).rounded() / 16, c = (r: Int(band.0.r + (band.1.r - band.0.r) * t), g: Int(band.0.g + (band.1.g - band.0.g) * t), b: Int(band.0.b + (band.1.b - band.0.b) * t))
                    self?.leds.set(uuid, live: t == 0.5 ? nil : c)
                }
            }
            rt.nudgeSpeedMs = num(settings["nudgeSpeedMs"]) ?? 50
            rt.tiltDeadzone = (num(settings["tiltDeadzone"]) ?? 0) / 100; rt.tiltSmoothing = (num(settings["tiltSmoothing"]) ?? 0) / 100
            rt.autorepeat = settings["autorepeat"] as? Bool ?? false
            rt.holdDelay = (num(settings["holdDelay"]) ?? 500) / 1000
            rt.doubleDelay = (num(store.preferences["doubleDelay"]) ?? 250) / 1000
            if rt.sub.kind == .button, let node = byLocalId.values.first(where: { n in n.subs.contains { $0.uuid == uuid } }) {
                let mode = buttonMode(node.uuid, assignments, appId), on = rt.settings["press"]
                offAction[uuid] = rt.settings["pressOff"]; rt.settings["pressOff"] = nil
                if mode == "toggle" || mode == "one" {
                    let group = mode == "one" ? node.subs.map(\.uuid).filter { $0 != uuid } : []
                    rt.settings["press"] = { [weak self] v in
                        guard let self else { return }
                        if mode == "toggle", lit.contains(litKey(uuid)) { lit.remove(litKey(uuid)); offAction[uuid]?(v) }
                        else {
                            for g in group where lit.remove(litKey(g)) != nil { offAction[g]?(v) } // the others go off first
                            lit.insert(litKey(uuid)); on?(v) // 하나만 켜짐: pressing the lit one runs 켤 때 again (re-syncs the app)
                        }
                        relight()
                    }
                }
            }
            rt.simplePress = ["pressAndHold", "pressDown", "pressUp", "doublePress"].allSatisfy { rt.settings[$0] == nil }
            // 누르는 동안 페이지: the hold switches the page; the release of the same control (whatever the new page assigns it) switches back. The held control breathes meanwhile.
            for (key, v) in settings { // 패널: the control that opens one owns it until it is released
                guard let d = v as? [String: Any], d["panel"] != nil || ((d["dispatch"] as? [String: Any])?["type"] as? String) == "PROFILE_SWITCHER", let inner = rt.settings[key] else { continue }
                rt.settings[key] = { [weak self, weak rt] v in if self?.panel == nil { self?.panelOwner = rt }; inner(v) }
            }
            if let h = settings["pressAndHold"] as? [String: Any], let t = (h["dispatch"] as? [String: Any])?["type"] as? String, t.hasPrefix("HOLD_") {
                let inner = rt.settings["pressAndHold"]
                rt.settings["pressAndHold"] = { [weak self, weak rt] v in
                    self?.holdOwner = rt; inner?(v)
                    if self?.ledOn("holdBreathe") == true { self?.leds.play(.init(kind: .breathe, color: (255, 255, 255), duration: .infinity, uuid: uuid)) }
                }
            }
        }
        if device.state == .open {
            let pageColor = p["color"] as? String // 페이지 색: controls without their own color follow the profile
            for (localId, node) in byLocalId { // LED colors through the player: it diffs and paces the messages
                let parent = resolveSettings(assignments[node.uuid], type: "", appId: appId)
                for s in node.subs {
                    leds.base[s.uuid] = Self.ledColor(resolveSettings(assignments[s.uuid], type: s.kind.rawValue, appId: appId)["color"] as? String ?? parent["color"] as? String ?? pageColor)
                    altLed[s.uuid]?.base = leds.base[s.uuid]!
                    if s.kind == .button, buttonMode(node.uuid, assignments, appId) != "each" { litColor[s.uuid] = leds.base[s.uuid] }
                }
                if node.typeId & 0x1f == 24 { // Orbiter tilt is shaped by the Core itself
                    let s = resolveSettings(assignments[node.uuid], type: "orbiter", appId: appId)
                    device.setOrbiter(localId: localId, sensitivity: Int(num(s["tiltSensitivity"]) ?? 3), blend: Int(num(s["tiltMode"]) ?? 1))
                }
            }
            if p["id"] as? String != activeProfileId {
                if !screenDriven, !activeProfileId.isEmpty { showScreen(of: p) }
                drawScreen(title: p["title"] as? String ?? "", icon: icon(for: p))
                if !activeProfileId.isEmpty { // 장면: welcome sweep when the app changed, a short wave between pages of one 묶음
                    let prevApp = store.profile(activeProfileId)?["app"] as? String ?? ""
                    let tint = pageColor.map(Self.ledColor)
                    if prevApp != appId, ledOn("welcome") { leds.play(.init(kind: .wave, color: tint ?? Self.dominant(icon(for: p)) ?? (255, 255, 255), duration: 1.5)) }
                    else if prevApp == appId, ledOn("page") { leds.play(.init(kind: .wave, color: tint ?? (255, 255, 255), duration: 0.6, direction: pageDirection)) }
                }
            }
            relight(); applyBrightness()
        }
        pageDirection = 1
        activeProfileId = p["id"] as? String ?? ""
        appLink.tryConnect(app: appId)
    }
    private var pageDirection = 1.0 // Previous Page waves right→left

    private func decoder(_ appId: String) -> ActionDecoder {
        ActionDecoder(catalog: catalog, appId: appId, appLink: appLink, dispatch: { [weak self] t in self?.dispatch(t) }, ui: { [weak self] t in self?.onPreview?(t == "SHOW_LAYOUT_PREVIEW") },
                      fail: { [weak self] t in self?.onEvent?(Event(uuid: "", name: t, value: 0, action: nil)) })
    }
    private func showPanelOnCore() {
        guard let p = panel, p.items.indices.contains(p.index) else { return }
        let i = p.items[p.index]
        drawScreen(title: "◀ " + i.label + " ▶", icon: i.app.flatMap(appIcon) ?? icon(for: store.activeProfile))
    }
    /// Builds the list for `what` and shows it. Nothing opens when there is nothing to pick, or when the control that asked is not held
    /// (a wire that fires on release would leave a panel nobody can close).
    private func openPanel(_ what: String) {
        guard panel == nil, panelOwner?.isPressed != false else { return }
        var items: [Panel.Item] = [], run: [() -> Void] = [], start = 0, title = ""
        let cur = store.activeProfile, app = cur["app"] as? String ?? ""
        func recent(_ list: [[String: Any]]) -> Int { // the one used before the current: opening and letting go at once goes back to it
            list.indices.filter { list[$0]["id"] as? String != cur["id"] as? String }.max { num(list[$0]["lastActivated"]) ?? 0 < num(list[$1]["lastActivated"]) ?? 0 } ?? 0
        }
        switch what {
        case "map": title = [catalog.app(app)?.name, cur["title"] as? String].compactMap { $0 }.joined(separator: " · ")
        case "profiles":
            let apps = store.bundleApps()
            guard let c = apps.firstIndex(of: app) else { return }
            items = apps.map { a in Panel.Item(label: a.isEmpty ? L("모든 앱") : catalog.app(a)?.name ?? a.components(separatedBy: ".").last ?? a, app: a) } // as the sidebar names them: the catalog calls "" Universal and does not know Photoshop
            run = apps.map { a in { [weak self] in self?.store.activateBundle(a) } }
            start = store.previousApp.flatMap { apps.firstIndex(of: $0) } ?? (c + 1) % max(apps.count, 1)
        case "pages":
            let pages = store.bundle(app)
            title = catalog.app(app)?.name ?? L("페이지")
            items = pages.map { Panel.Item(label: $0["title"] as? String ?? "") }
            run = pages.map { p in { [weak self] in self?.store.activate(p["id"] as? String ?? "") } }
            start = recent(pages)
        case _ where what.hasPrefix("stack:"):
            let h = String(what.dropFirst(6)), s = store.stack(h)
            title = store.moduleName(h).isEmpty ? L("스택") : store.moduleName(h)
            items = s.members.enumerated().map { Panel.Item(label: s.names[$1] ?? L("\($0 + 1)번")) }
            run = s.members.indices.map { i in { [weak self] in self?.store.switchStack(h, to: i) } }
            start = (s.index + 1) % s.members.count
        case _ where what.hasPrefix("list:"):
            title = String(what.dropFirst(5))
            let list = store.panels.first { $0["name"] as? String == title }?["items"] as? [[String: Any]] ?? []
            items = list.map { d in
                let named = (d["keys"] as? String).flatMap(Keymap.find)
                let chord = named?.chord ?? (d["key"] as? String).map { (d["modifiers"] as? [String] ?? []).compactMap { Self.modSymbols[$0] }.joined() + $0.uppercased() }
                return Panel.Item(label: d["label"] as? String ?? named?.label ?? Self.describe(d), note: chord ?? (d["shortcut"] != nil ? L("단축어") : d["open"] != nil ? L("앱") : ""), app: d["open"] as? String)
            }
            run = list.map { d in { [weak self] in guard let self else { return }; decoder(store.activeProfile["app"] as? String ?? "").decode(d, kind: .pulse)?(0) } } // decoded when picked: an app function goes to the app of the profile active then
        default: NSLog("unknown panel %@", what); return
        }
        guard what == "map" || items.count > (what.hasPrefix("list:") ? 0 : 1) else { return }
        panelRun = run; panelTicks = 0; panelOwner?.muted = true
        panel = Panel(kind: what, title: title, items: items, index: start); startKeyTap(); showPanelOnCore()
    }
    deinit { if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: false); CFMachPortInvalidate(keyTap) } } // the tap's callback holds this object unretained
    /// Swallows ← → esc for the switcher; everything else passes. Needs Accessibility (already requested for key taps). Created once, enabled while open.
    private func startKeyTap() {
        if keyTap == nil {
            let cb: CGEventTapCallBack = { _, type, event, info in
                let e = Unmanaged<Engine>.fromOpaque(info!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let t = e.keyTap, e.panel != nil { CGEvent.tapEnable(tap: t, enable: true) }; return Unmanaged.passUnretained(event) }
                guard e.panel != nil, type == .keyDown else { return Unmanaged.passUnretained(event) }
                switch event.getIntegerValueField(.keyboardEventKeycode) {
                case 123: e.dispatch("SWITCHER_PREVIOUS"); return nil
                case 124: e.dispatch("SWITCHER_NEXT"); return nil
                case 53: e.dispatch("SWITCHER_CANCEL"); return nil
                default: return Unmanaged.passUnretained(event)
                }
            }
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                              callback: cb, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { NSLog("switcher: key tap refused (Accessibility off); arrows unavailable"); return }
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            keyTap = tap
        }
        CGEvent.tapEnable(tap: keyTap!, enable: true)
    }

    public typealias Band = ((r: Double, g: Double, b: Double), (r: Double, g: Double, b: Double))
    /// Built-in 데코레이션 bands (value 0 → 255), picked by name in the control's editor.
    public static var bands: [(id: String, name: String, band: Band)] { [ // computed: the names follow the language
        ("temp", L("색온도 (파랑 ↔ 주황)"), ((40, 110, 255), (255, 190, 40))),
        ("tint", L("색조 (초록 ↔ 자홍)"), ((40, 220, 80), (240, 60, 220))),
        ("exposure", L("노출 (어두움 ↔ 밝음)"), ((20, 12, 6), (255, 240, 200))),
        ("contrast", L("대비 (회색 ↔ 흰색)"), ((110, 110, 110), (255, 255, 255))),
        ("saturation", L("채도 (회색 ↔ 빨강)"), ((120, 120, 120), (255, 40, 40))),
        ("hue", L("색상 (빨강 ↔ 파랑)"), ((255, 40, 40), (40, 40, 255))),
        ("highlight", L("밝은 영역 (어두운 흰색 ↔ 흰색)"), ((90, 85, 70), (255, 255, 255))),
        ("shadow", L("어두운 영역 (꺼짐 ↔ 회색)"), ((0, 0, 0), (120, 120, 130))),
        ("clarity", L("선명도 (따뜻한 흰색 ↔ 파랑)"), ((255, 240, 200), (60, 140, 255))),
        ("volume", L("음량 (어두운 초록 ↔ 초록)"), ((10, 30, 10), (40, 255, 80))),
    ] }
    /// 데코레이션 band the profile's designer picked for this control: `settings.deco` = a built-in id, or `[lowHex, highHex]` (사용자 정의); nil = none.
    static func colorBand(_ deco: Any?) -> Band? {
        if let id = deco as? String { return bands.first { $0.id == id }?.band }
        guard let d = deco as? [String], d.count == 2 else { return nil }
        let c = d.map { h -> (r: Double, g: Double, b: Double) in let c = ledColor(h); return (Double(c.r), Double(c.g), Double(c.b)) }
        return (c[0], c[1])
    }
    /// One line for the developer log: `input (action) step 0.01 invert`.
    public static func describe(_ v: Any) -> String {
        guard let d = v as? [String: Any] else { return "\(v)" }
        var parts = [d["input"] as? String ?? d["keystroke"] as? String ?? d["type"] as? String ?? (d["open"] ?? d["shortcut"] ?? d["text"] ?? d["panel"] ?? d["send"] ?? d["key"] ?? d["keys"]).map { "\($0)" } ?? "{…}"]
        if let a = d["action"] as? String { parts.append("(\(a))") }
        if let s = num(d["step"]) { parts.append("step \(s)") }
        if d["invert"] as? Bool == true { parts.append("invert") }
        return parts.joined(separator: " ")
    }
    /// Developer card: the runtime's current position (0…255) and sensitivity.
    public func runtimeState(_ uuid: String) -> (position: Double, sensitivity: Int)? { runtimes[uuid].map { ($0.position, $0.sensitivity) } }

    /// The profile's slots over the root's, and the ones that came from the root.
    private func merge(_ own: Any?, root: Any?, kind: Submodule.Kind, appId: String) -> ([String: Any], Set<String>) {
        let type = kind.rawValue
        var settings = resolveSettings(own, type: type, appId: appId)
        // A ui-only slot the preset shipped (Next Profile's 길게 = 앱 창 보이기) counts as empty, so the root shows through; a value the person picked stays.
        var bare = own; if var d = bare as? [String: Any] { d["settings"] = nil; bare = d }
        let shipped = resolveSettings(bare, type: type, appId: appId)
        for (k, v) in settings where (v as? [String: Any])?["ui"] != nil && (v as? NSDictionary) == (shipped[k] as? NSDictionary) { settings[k] = nil }
        var inherited: Set<String> = []
        for (k, v) in resolveSettings(root, type: type, appId: "") where settings[k] == nil && Self.settingKinds[kind]!.contains(where: { $0.0 == k }) { settings[k] = v; inherited.insert(k) }
        return (settings, inherited)
    }
    /// Slots in effect for a control and the ones from the root: a connected one from the runtime, a board-only (unplugged) one
    /// worked out the same way, so the board and the wiring screen show the root's wiring without the hardware. `type` = button, dial, …
    public func effective(_ uuid: String, type: String) -> (settings: [String: Any], inherited: Set<String>)? {
        if let s = effective[uuid] { return (s, inheritedSlots[uuid] ?? []) }
        guard !store.editingRoot, let kind = Submodule.Kind(rawValue: type) else { return nil }
        let (s, i) = merge(store.assignments(store.activeProfile)[uuid], root: store.rootAssignments()[uuid], kind: kind, appId: store.activeProfile["app"] as? String ?? "")
        return s.isEmpty ? nil : (s, i)
    }
    /// assignment forms: {preset, settings}, "presetName", ["presetName", {...overrides}], or raw settings
    /// The root's slots for a submodule (the inspector's "루트 값 쓰기"), connected or board-only.
    public func rootSettings(_ uuid: String, type: String? = nil) -> [String: Any] {
        resolveSettings(store.rootAssignments()[uuid], type: runtimes[uuid]?.sub.kind.rawValue ?? type ?? "", appId: "")
    }
    func resolveSettings(_ a: Any?, type: String, appId: String) -> [String: Any] {
        guard let a else { return [:] }
        if let d = a as? [String: Any] {
            if let s = d["settings"] as? [String: Any] { return s }
            if let name = d["preset"] as? String { return preset(name, type: type, appId: d["app"] as? String ?? appId) }
            return d
        }
        if let name = a as? String { return preset(name, type: type, appId: appId) }
        if let arr = a as? [Any], let name = arr.first as? String {
            return preset(name, type: type, appId: appId).merging(arr.dropFirst().first as? [String: Any] ?? [:]) { $1 }
        }
        return [:]
    }
    private func preset(_ name: String, type: String, appId: String) -> [String: Any] {
        catalog.app(appId)?.preset(type, named: name) ?? catalog.app("")?.preset(type, named: name) ?? [:]
    }

    /// 실행 후 of one wire. value "default": the function on this control's 회전 is back at its catalog default, so ring, band color and pointer go there.
    /// Display only; nothing more is sent to the app, and an app that reports the value overrides it.
    private func after(_ uuid: String, _ then: [String: Any], appId: String) {
        if then["value"] as? String == "default" {
            runtimes[uuid]?.recenter(); leds.set(uuid, live: nil)
            if let t = effective[uuid]?["turn"] as? [String: Any], let input = t["input"] as? String,
               let i = catalog.app([t["app"] as? String, appId].compactMap { $0 }.first { !$0.isEmpty } ?? "")?.inputs[input], let d = i.reset?.first,
               let r = (t["range"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.doubleValue }) ?? i.range, r.count == 2, r[0] != r[1] {
                onPointer?(uuid, (d - r[0]) / (r[1] - r[0]))
            }
        }
        if then["led"] as? String == "assigned" { leds.set(uuid, live: nil) }
        if then["flash"] as? Bool == true { leds.play(.init(kind: .flash, color: (255, 255, 255), duration: 0.5, uuid: uuid, count: 3)) } // three blinks: one looks the same as the press flash
    }
    public var onPointer: ((String, Double) -> Void)? // submodule uuid, 0…1 inside the range: where 실행 후 put the pointer (not a reported value)

    static let settingKinds: [Submodule.Kind: [(String, ActionKind)]] = [
        .button: [("press", .pulse), ("pressOff", .pulse), ("doublePress", .pulse), ("pressAndHold", .pulse), ("pressDown", .pulse), ("pressUp", .pulse)],
        .dial: [("turn", .nudge), ("pressAndTurn", .nudge), ("press", .pulse), ("doublePress", .pulse), ("doubleTap", .pulse), ("leftTurn", .pulse), ("rightTurn", .pulse),
                ("pressAndLeftTurn", .pulse), ("pressAndRightTurn", .pulse), ("pressDown", .pulse), ("pressUp", .pulse), ("pose", .set)],
        .slider: [("pose", .set)],
        .orbiter: [("turn", .nudge), ("leftTurn", .pulse), ("rightTurn", .pulse), ("tiltX", .nudge), ("tiltY", .nudge)], // shortcut: tiltLeft/Right/Up/Down (tilt as keys) not ported
    ]

    /// Setting slots of a module type, in inspector order (the UI's 동작별 할당 표).
    public static func slots(_ type: String) -> [String] { Submodule.Kind(rawValue: type).flatMap { settingKinds[$0] }?.map(\.0) ?? [] }

    /// Profile's own icon file, else the icon of the first installed app the profile's app id maps to.
    /// Redraw the active profile on the Core, e.g. after the screen or board rotation changed.
    public func redrawScreen() { let p = store.activeProfile; drawScreen(title: p["title"] as? String ?? "", icon: icon(for: p)) }
    private func drawScreen(title: String, icon: NSImage?) {
        onDisplay?(title, icon)
        guard device.state == .open else { return }
        Screen.write(Screen.render(title: title, icon: icon, rotation: Int(num(store.preferences["screenRotation"]) ?? 0) + boardTurn * 90), to: device) // screenRotation = the display's angle with the board unturned; 270 = upright on the Core held level
    }
    func icon(for p: [String: Any]) -> NSImage? {
        if let path = p["icon"] as? String, let i = NSImage(contentsOfFile: path) { return i }
        return appIcon(p["app"] as? String)
    }
    public func appIcon(_ app: String?) -> NSImage? {
        for b in catalog.app(app)?.processIdentifiers ?? [app ?? ""] { // no integration (Photoshop): the id is the bundle id
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) { return NSWorkspace.shared.icon(forFile: u.path) }
        }
        return nil
    }

    static func ledColor(_ hex: String?) -> (r: Int, g: Int, b: Int) {
        // shortcut: "#000000" is what CommandPost presets store before the app recolors them live over its socket;
        // that socket isn't ported, so treat black as unset until dynamic color exists.
        guard let h = hex?.trimmingCharacters(in: CharacterSet(charactersIn: "#")), h.count == 6, let v = Int(h, radix: 16), v != 0 else { return (255, 255, 255) }
        // Screen color → LED drive: gamma 2.2 (LEDs are linear, so raw sRGB washes hues out toward white), at full strength
        // (an LED has no "dark" hue; dimming is the brightness setting). The per-module white balance is applied in `Leds.wire`.
        let c = [v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff].map { pow(Double($0) / 255, 2.2) }, k = 255 / c.max()!
        return (Int((c[0] * k).rounded()), Int((c[1] * k).rounded()), Int((c[2] * k).rounded()))
    }

    // MARK: Profile switching

    public func dispatch(_ type: String) {
        let auto = store.preferences["autoProfileSwitchingEnabled"] as? Bool ?? true
        switch type {
        case "NEXT_PROFILE": store.nextProfile(autoSwitch: auto)
        case "PREVIOUS_PROFILE": store.previousProfile(autoSwitch: auto)
        case "NEXT_SCREEN": store.nextScreen(by: 1)
        case "PREVIOUS_SCREEN": pageDirection = -1; store.nextScreen(by: -1)
        case _ where type.hasPrefix("ACTIVATE_PROFILE:"): store.activate(String(type.dropFirst(17)))
        case _ where type.hasPrefix("ACTIVATE_BUNDLE:"): store.activateBundle(String(type.dropFirst(16))) // 프로필 묶음(앱)으로: its most recently used profile; "" = 앱 없음
        case _ where type.hasPrefix("HOLD_SCREEN:"):
            if heldReturn == nil { heldReturn = store.activeProfile["id"] as? String }
            store.activate(String(type.dropFirst(12)))
        case "RELEASE_SCREEN":
            leds.stop(.breathe)
            if let h = heldReturn { heldReturn = nil; store.activate(h) }
            if let s = heldStack { heldStack = nil; store.switchStack(s.host, to: s.index) }
        // 스택 (2층): the action names the member to attach (or the host for "next"); a member that is gone does nothing
        case _ where type.hasPrefix("STACK_NEXT:"): let h = String(type.dropFirst(11)); store.switchStack(h, to: store.stack(h).index + 1)
        case _ where type.hasPrefix("STACK:"): if let m = store.stack(ofMember: String(type.dropFirst(6))) { store.switchStack(m.host, to: m.index) }
        case _ where type.hasPrefix("HOLD_STACK:"):
            guard let m = store.stack(ofMember: String(type.dropFirst(11))) else { return }
            if heldStack == nil { heldStack = (m.host, store.stack(m.host).index) }
            store.switchStack(m.host, to: m.index)
        case _ where type.hasPrefix("HOLD_STACK_NEXT:"): // 누르는 동안 다음 층: one step on while held, back on release
            let h = String(type.dropFirst(16)), i = store.stack(h).index
            if heldStack == nil { heldStack = (h, i) }
            store.switchStack(h, to: i + 1)
        // 패널: the other button / the owner dial / ← → step, release commits, esc cancels
        case "PROFILE_SWITCHER": openPanel("profiles")
        case _ where type.hasPrefix("PANEL:"): openPanel(String(type.dropFirst(6)))
        case "SWITCHER_NEXT", "SWITCHER_PREVIOUS":
            guard let s = panel, !s.items.isEmpty else { return }
            panel = Panel(kind: s.kind, title: s.title, items: s.items, index: (s.index + (type == "SWITCHER_NEXT" ? 1 : s.items.count - 1)) % s.items.count); showPanelOnCore()
        case "SWITCHER_COMMIT", "SWITCHER_CANCEL":
            guard let s = panel else { return }
            panel = nil; if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: false) }
            let p = store.activeProfile; drawScreen(title: p["title"] as? String ?? "", icon: icon(for: p)) // the chosen 묶음 redraws it again if it differs
            if type == "SWITCHER_COMMIT", panelRun.indices.contains(s.index) { panelRun[s.index]() }
            panelRun = []
        case "TOGGLE_MAP": store.setPreference("mapPinned", !(store.preferences["mapPinned"] as? Bool ?? false)) // 상시 맵: the app shows or hides it on the store change
        case "PLAY_SCENE": leds.play(.init(kind: .wave, color: store.activeProfile["color"].flatMap { Self.ledColor($0 as? String) } ?? (255, 255, 255), duration: 1.5)) // 장면 버튼
        default: NSLog("unknown dispatch %@", type)
        }
    }

    func frontmost(bundle: String) {
        let b = bundle.lowercased()
        guard b != Bundle.main.bundleIdentifier?.lowercased() else { return }
        if b != lastFront { seenScreen = nil; lastFront = b } // back from our own window is not a new app
        let ids = catalog.apps(forBundle: b).map(\.id)
        for id in ids { appLink.tryConnect(app: id) }
        if store.preferences["autoProfileSwitchingEnabled"] as? Bool ?? true { store.activateApps(ids + [b], focused: b) } else { store.focus = b }
        if device.state == .open { applyBrightness() }
    }
}
