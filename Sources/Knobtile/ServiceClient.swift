import AppKit
import Foundation
import Combine
import Engine

/// What the window shows and does, on top of the engine (the name is from when this talked to a separate service).
@MainActor
final class ServiceClient: ObservableObject {
    enum Status: Equatable { case disconnected, connecting, connected, failed(String) }

    @Published var status: Status = .disconnected { didSet { if status != oldValue { NSLog("service status: %@", String(describing: status)) } } }
    @Published var profiles: [JSON] = []
    /// 루트 프로필 편집: the inspector and cards show/edit the root; the Core keeps the active profile.
    @Published var editingRoot = false { didSet { engine?.store.editingRoot = editingRoot } }
    @Published var designMode = false { didSet { engine?.designMode = designMode } }
    @Published var preferences: JSON = .null
    @Published var apps: [JSON] = []
    @Published var layout: JSON = .null
    @Published var coreState = "unknown"
    @Published var firmware: JSON = .null
    @Published var activeApp: JSON = .null
    @Published var screen: (app: String, key: String)?  // native: LrC module / Resolve page the engine last saw
    @Published var linkedApps: [String: Bool] = [:]   // native: app id → plugin socket connected
    @Published var display: (title: String, icon: NSImage?)?  // what the Core display shows now (changes on profile switches only)
    @Published var mapFlash: Set<String> = []          // 상시 맵: stack hosts whose layer just changed, outlined for 3 s
    @Published var previewRequests = 0                 // SHOW_LAYOUT_PREVIEW from a Core button: bring the window up
    @Published var panel: Engine.Panel?                // 화면 패널 (OSD) while a control is held
    @Published var shortcutNames: [String]?            // Shortcuts app's list; nil until read once (a missing name is only known after that)
    /// Reads the shortcut list again in the background (picker opened, app started).
    func loadShortcuts() { DispatchQueue.global().async { let n = Engine.shortcutNames(); DispatchQueue.main.async { if n != self.shortcutNames { self.shortcutNames = n } } } }
    func functions(_ app: String) -> [(line: String, label: String)] { engine?.functions[app] ?? [] } // announced by the plugin at run time
    var panelLists: [JSON] { (engine?.store.panels ?? []).map(JSON.init(any:)) }
    func setPanelLists(_ p: [[String: Any]]) { engine?.store.setPanels(p) }
    var keymaps: [String: Any] { engine?.store.keymaps ?? [:] }
    func setKeymaps(_ k: [String: Any]) { engine?.store.setKeymaps(k) }
    func renamePanelList(_ old: String, _ new: String) { engine?.store.renamePanel(old, to: new) }
    @Published var editingPanel: String? // 패널 목록 open in the right sidebar (PanelWiringView); the board rings the controls that open it
    let live = Live() // per-event hardware state lives apart, so a turning dial redraws only the small views that show it
    var logPaused = false

    var engine: Engine? // not private: the view tests hand in one with a temporary store
    // MARK: connection

    func connect() {
        // the window's onAppear calls this every time the window opens again. Each call made one more engine: all of them read the same serial port
        // (a release went to another engine = long press on a click) and fought for Lightroom's single socket (link down, no values) (2026-11-15)
        if engine != nil { return }
        status = .connecting
        startNative()
    }

    private func startNative() {
        let e = Engine()
        engine = e
        apps = e.catalog.raw.map(JSON.init(any:))
        let sync = { [weak self] in
            guard let self, let e = self.engine else { return }
            self.profiles = e.store.profiles.map(JSON.init(any:))
            self.preferences = JSON(any: e.store.preferences)
            MapPanel.shared.update(self)
        }
        e.onValuesReset = { [weak self] in DispatchQueue.main.async { self?.live.value = [:] } }
        var shownProfile = e.store.activeProfile["id"] as? String
        e.onStoreChange = { [weak self] in if Thread.isMainThread { self?.memo = Memo() }; DispatchQueue.main.async {
            let id = e.store.activeProfile["id"] as? String
            if id != shownProfile { shownProfile = id; self?.live.pose = [:]; self?.toast("", e.store.activeProfile["title"] as? String ?? "") } // another profile: pointers start over, the app's answers put the assigned ones back
            sync() } } // drop the memo at once: the handler that changed the store may read it back before sync runs
        e.onScreen = { [weak self] in DispatchQueue.main.async { self?.screen = e.screen } }
        e.onLayout = { [weak self] l in self?.layout = l.map(JSON.init(any:)) ?? .null }
        let engineState = e.device.onState // keep the engine's own handler (it clears runtimes on unplug)
        e.device.onState = { [weak self] s in engineState?(s); DispatchQueue.main.async { self?.coreState = s == .open ? "open" : "closed" } }
        e.device.onVersion = { [weak self] v in DispatchQueue.main.async { self?.firmware = JSON(any: ["currentVersion": v["version_core"] ?? "", "hardwareVersion": "core-v2.0"]) } }
        e.onActive = { [weak self] uuid, on in self?.ui {
            guard let self else { return }
            if !on { self.live.active[uuid] = nil; return }
            MapPanel.shared.wake()
            let until = Date(timeIntervalSinceNow: 0.3)
            self.live.active[uuid] = uuid.contains("button") ? .distantFuture : until // dial ticks flash, buttons stay lit while held
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if self.live.active[uuid] == until { self.live.active[uuid] = nil } }
        } }
        e.onPose = { [weak self] uuid, ticks, x, y in self?.ui {
            let old = self?.live.pose[uuid] ?? (0, 0, 0)
            let told = self?.live.value[uuid] != nil // the app reports this dial's value: the pointer waits for the answer, ticks would only make it shake
            self?.live.pose[uuid] = (told ? old.angle : old.angle + Double(ticks) * 3.75, x, y) // shortcut: 96 ticks per turn assumed, check against the device
        } }
        e.onPointer = { [weak self] uuid, f in self?.ui { // 실행 후: pointer only; live.value stays empty so ticks keep moving it
            let old = self?.live.pose[uuid] ?? (0, 0, 0)
            self?.live.pose[uuid] = ((min(max(f, 0), 1) - 0.5) * 270, old.x, old.y)
        } }
        e.onDisplay = { [weak self] t, i in DispatchQueue.main.async { self?.display = (t, i) } }
        e.onDialValue = { [weak self] uuid, f, v in self?.ui { // the pointer shows the app's value: range low = −135°, middle = up, high = +135°
            let old = self?.live.pose[uuid] ?? (0, 0, 0)
            self?.live.pose[uuid] = ((min(max(f, 0), 1) - 0.5) * 270, old.x, old.y)
            self?.live.value[uuid] = v
        } }
        e.leds.onFrame = { [weak self] f in self?.ui { self?.live.ledFrame = f } }
        e.onRaw = { [weak self] uuid, raw in self?.ui { self?.live.raw[uuid] = raw } }
        e.onEvent = { [weak self] ev in self?.ui {
            guard let self else { return }
            if ev.action != nil, ["turn", "pressAndTurn", "pose", "tiltX", "tiltY"].contains(ev.name) { self.toast(ev.uuid, ev.name) }
            guard !self.logPaused else { return }
            self.live.events.insert(ev, at: 0); if self.live.events.count > 300 { self.live.events.removeLast() }
        } }
        e.onPreview = { [weak self] show in if show { DispatchQueue.main.async { self?.previewRequests += 1 } } }
        e.onPanel = { [weak self] s in DispatchQueue.main.async { guard let self else { return }; self.panel = s; if s != nil { SwitcherPanel.shared.show(self) } else { SwitcherPanel.shared.hide() } } } // shown from here, not from the window's view: with the window closed no view was left to react
        loadShortcuts()
        e.appLink.onConnected = { [weak self, weak e] id, ok in DispatchQueue.main.async { self?.linkedApps[id] = ok; if ok { e?.askValues() } } }
        sync()
        status = .connected
        coreState = "closed"
        e.start()
    }
    private var uiPending: [() -> Void] = []
    /// Console input reaches the window at most once a frame: per dial tick it redrew the sidebar, pointers and log in between the next reports.
    private func ui(_ f: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            uiPending.append(f); guard uiPending.count == 1 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
                guard let self else { return }
                let q = uiPending; uiPending = []; q.forEach { $0() }
            }
        }
    }
    func disconnect() {
        engine?.device.stop(); engine = nil
        status = .disconnected
    }

    // MARK: commands

    func dispatch(_ type: String, _ fields: [String: Any] = [:]) {
        if let e = engine { nativeDispatch(e, type, fields) }
    }

    private func nativeDispatch(_ e: Engine, _ type: String, _ f: [String: Any]) {
        let s = e.store
        let id = f["profileId"] as? String ?? ""
        switch type {
        case "ACTIVATE_PROFILE": s.activate(id)
        case "UPDATE_PROFILE": s.updateProfile(id, f.filter { $0.key != "profileId" })
        case "CLOSE_PROFILE": s.closeProfile(id)
        case "ADD_PROFILE":
            let p = f["profile"] as? [String: Any] ?? [:]
            let id = s.addProfile(title: p["title"] as? String ?? L("새 프로필"), app: p["app"] as? String ?? "")
            let extra = p.filter { ["assignments", "icon", "tags", "layout", "screen", "stacks", "moduleNames"].contains($0.key) }
            if !extra.isEmpty { s.updateProfile(id, extra) } // imported or duplicated profile
        case "REORDER_PROFILES": s.reorder(f["order"] as? [String] ?? [])
        case "ASSIGN_MODULE": s.assign(f["uuid"] as? String ?? "", f["assignment"] as? [String: Any])
        case "CLEAR_MODULE": s.assign(f["uuid"] as? String ?? "", nil)
        case "UNDO": s.undo()
        case "ROTATE_SCREEN": s.setPreference("screenRotation", ((s.preferences["screenRotation"] as? Int ?? 0) + 90) % 360); engine?.redrawScreen()
        case "UPDATE_PREFERENCE":
            if let u = f["update"] as? [String: Any], let k = u["type"] as? String, let v = u["value"] { s.setPreference(k, v); if k == "boardRotation" { engine?.redrawScreen() } }
        case "NEXT_PROFILE", "PREVIOUS_PROFILE", "NEXT_SCREEN", "PREVIOUS_SCREEN", "PROFILE_SWITCHER", "SWITCHER_NEXT", "SWITCHER_PREVIOUS", "SWITCHER_COMMIT", "SWITCHER_CANCEL", "TOGGLE_MAP": e.dispatch(type)
        case _ where type.hasPrefix("STACK") || type.hasPrefix("PANEL:"): e.dispatch(type) // STACK_NEXT:<host> / STACK:<member> / PANEL:<kind>
        default: NSLog("native: unsupported action %@", type)
        }
    }

    /// 값 알림 (환경설정, 기본 꺼짐): the moved control's function and, when the app reports it, its value; shown for a moment at the bottom of the screen.
    /// uuid "" = plain text (profile or page changed).
    private var toastKey = ""
    private func toast(_ uuid: String, _ slot: String) {
        guard preferences["osdValues"].bool == true, panel == nil else { return }
        if uuid + slot != toastKey || live.toast == nil { // the label is worked out once per control, not per tick
            toastKey = uuid + slot
            let a = assignment(uuid)
            let name = a["settings"]["name"].string.flatMap { $0.isEmpty ? nil : $0 }
            live.toast = (uuid, uuid.isEmpty ? slot : name ?? SlotText.describe(JSON(any: engine?.effective[uuid]?[slot] as Any), service: self, appId: activeProfile?["app"].string ?? "", presetApp: a["app"].string ?? ""))
        }
        ToastPanel.shared.show(self)
    }

    func runtimeState(_ uuid: String) -> (position: Double, sensitivity: Int)? { engine?.runtimeState(uuid) }

    // MARK: derived

    var activeProfile: JSON? { profiles.max { ($0["lastActivated"].int ?? 0) < ($1["lastActivated"].int ?? 0) } }

    func app(id: String) -> JSON? { apps.first { $0["id"].string == id } }
    /// Display name; an app the catalog doesn't name (e.g. an uninstalled CommandPost target) shows its last id part, not the whole bundle id.
    @Published var showPrefs = false
    /// The profile needs a plugin that is not installed (Catalog.missing).
    func missingPlugin(_ p: JSON?) -> Bool { missingApp(p) != nil }
    func missingApp(_ p: JSON?) -> String? { (p?.any as? [String: Any]).flatMap { engine?.catalog.missingApp($0) } }
    func showPlugins() { UserDefaults.standard.set(4, forKey: "prefsTab"); showPrefs = true } // 환경설정 › 플러그인
    func appIcon(_ id: String) -> NSImage? { engine?.appIcon(id) }
    func appName(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return L("모든 앱") }
        return app(id: id)?["name"].string ?? id.components(separatedBy: ".").last ?? id
    }

    /// Flatten the layout tree (u = uuid, t & 0x1f = type id, c = children by port).
    /// Type ids and submodule names come from the service's module classes (Core, Button3x, Dial3x, …).
    /// Assignment for a connected (or remembered) module: the engine matches by position + type, so a swapped module of the same kind keeps its assignment.
    // Views ask for the board, the shown modules and assignments dozens of times per redraw (once per control); each used to re-parse the
    // profile and re-key every assignment, which made resizing and live updates stutter. Computed once, dropped on any change.
    private struct Memo { var shown: [Shown]?; var hw: [String: (u: String, t: Int, i: Int?)]?; var board: Board?; var assignments: [String: Any]? }
    private var memo = Memo()
    private var memoSink: AnyCancellable?
    private func memoized<T>(_ k: WritableKeyPath<Memo, T?>, _ make: () -> T) -> T {
        if memoSink == nil { memoSink = objectWillChange.sink { [weak self] _ in self?.memo = Memo() } } // any published change (profiles, layout, root editing…)
        if let v = memo[keyPath: k] { return v }
        let v = make(); memo[keyPath: k] = v; return v
    }
    private func assignmentsNow(_ e: Engine) -> [String: Any] { memoized(\.assignments) { editingRoot ? e.store.rootAssignments() : e.store.assignments(e.store.activeProfile) } }
    func assignment(_ uuid: String) -> JSON {
        guard let e = engine else { return activeProfile?["assignments"][uuid] ?? .null }
        return JSON(any: assignmentsNow(e)[uuid] as Any)
    }
    /// Slots in effect after root inheritance, the ones that came from the root, and the root's own value for a slot.
    func effective(_ m: Module) -> JSON { JSON(any: engine?.effective(m.uuid, type: m.type)?.settings as Any) } // also for a board-only module
    func inherited(_ m: Module) -> Set<String> { engine?.effective(m.uuid, type: m.type)?.inherited ?? [] }
    func rootSlot(_ m: Module, _ slot: String) -> JSON { JSON(any: engine?.rootSettings(m.uuid, type: m.type)[slot] as Any) }
    /// Connected hardware by port path from the device layout JSON (also without the engine, for the legacy service).
    var hardwarePaths: [String: (u: String, t: Int, i: Int?)] { memoized(\.hw) { computeHardwarePaths() } }
    private func computeHardwarePaths() -> [String: (u: String, t: Int, i: Int?)] {
        var out: [String: (u: String, t: Int, i: Int?)] = [:]
        func walk(_ n: JSON, _ path: String) {
            guard let u = n["u"].string, u != "INVLD" else { return }
            out[path] = (u, n["t"].int ?? 0, n["i"].int)
            for (k, c) in n["c"].array.enumerated() { walk(c, path.isEmpty ? "\(k)" : path + "/\(k)") }
        }
        walk(layout, ""); return out
    }
    enum Link: Equatable { case connected, missing, mismatch(Int), temp, loose, turned } // turned: lies on a connected module of its type, facing another way // mismatch: the type id actually connected there
    /// One module on the board as the user sees it.
    struct Shown: Identifiable {
        let pose: Pose           // u = the connected module's uuid when the profile's module is connected, else the profile's own
        let path: String?        // port path when connected to the Core geometrically
        var link: Link
        let boardIndex: Int?     // index in the profile's board; nil for a temp (connected, not yet applied) module
        let localId: Int?
        var id: String { pose.u + "@" + (path ?? "~") } // the same physical module can be on the board and plugged in elsewhere at once
    }
    var board: Board { memoized(\.board) { engine.map { $0.store.board($0.store.activeProfile) } ?? .empty(coreU: hardwarePaths[""]?.u ?? "v:core") } }
    /// The profile's modules plus connected modules the profile has not applied yet (temp, drawn dashed; they vanish with the hardware).
    var shown: [Shown] { memoized(\.shown) { computeShown() } }
    private func computeShown() -> [Shown] {
        let hw = hardwarePaths
        var b = board
        let paths = b.paths()
        var out: [Shown] = []
        for (i, p) in b.modules.enumerated() {
            let path = paths[i]
            var pose = p, link = Link.loose
            if let path, let h = hw[path] {
                if i == 0 || Store.sameType(h.t, p.t) { pose.u = h.u; link = .connected } else { link = .mismatch(h.t) }
            } else if path != nil { link = .missing }
            out.append(Shown(pose: pose, path: path, link: link, boardIndex: i, localId: path.flatMap { hw[$0]?.i }))
        }
        let covered = Set(paths.values)
        for path in hw.keys.filter({ !covered.contains($0) }).sorted(by: { $0.count < $1.count || ($0.count == $1.count && $0 < $1) }) {
            // connected hardware cannot overlap itself, so an overlap is with a module that is not there now (missing): still show it, on top
            guard let h = hw[path], let p = b.pose(at: path, t: h.t, u: h.u) else { continue }
            b.modules.append(p) // an applied module keeps its place even when the same physical module is plugged in elsewhere (that shows as temp too)
            // the profile's module put on this place but facing another way stands for it, marked as a problem; nothing is corrected for the user
            // same rule as placing (LayoutView.fits): a design module on a plugged-in one is red; with the same shape it covers it,
            // a different shape (plugged in after it was laid out) leaves both drawn. The hardware's own direction is never changed.
            if let j = out.firstIndex(where: { $0.link == .loose && Board(modules: [$0.pose]).overlaps(p) }) {
                out[j].link = Store.sameType(out[j].pose.t, p.t) ? .turned : .mismatch(h.t)
                if out[j].pose.x == p.x && out[j].pose.y == p.y && out[j].pose.w == p.w && out[j].pose.h == p.h { continue }
            }
            out.append(Shown(pose: p, path: path, link: .temp, boardIndex: nil, localId: h.i))
        }
        return out
    }
    /// (matched, remembered) module counts for the header.
    var matchCount: (Int, Int) {
        let remembered = shown.filter { $0.boardIndex != nil && $0.boardIndex != 0 && $0.path != nil }
        return (remembered.filter { $0.link == .connected }.count, remembered.count)
    }
    func setBoard(_ b: Board) { engine?.store.setBoard(b) }
    func exportBundle(app: String?, root: Bool) -> [String: Any] { engine?.store.bundle(app: app, root: root) ?? [:] }
    @discardableResult func importFile(_ f: [String: Any], replace: Bool, root: Bool) -> Bool { engine?.store.restore(f, replace: replace, root: root) ?? false }
    @discardableResult func adopt(_ path: String) -> Int? { engine?.store.adopt(path) }
    /// "문제 해결" for a 방향 다름 module: turn it in place to the rotation that plugs into the port the hardware is on. Only on the user's request.
    func fixDirection(_ bi: Int) {
        let b = board, sh = shown, geo = Board(modules: sh.map(\.pose))
        for k in 1...3 {
            var t = b; t.modules[bi].r = (b.modules[bi].r + k) % 4
            // same rule as dragging and turning: it may cover a plugged-in module of its shape only, never overlap another
            if let path = t.paths()[bi], hardwarePaths[path] != nil, LayoutView.fits(t.modules[bi], moving: bi, sh, geo) { setBoard(t); return }
        }
        NSSound.beep()
    }

    // MARK: 스택 (2층)

    /// The profile's own module behind a shown box (stacks are keyed by it); nil for a temp module until it is applied.
    func host(of s: Shown) -> String? { s.boardIndex.flatMap { i in let b = board; return i < b.modules.count ? b.modules[i].u : nil } }
    func stack(_ host: String) -> Store.Stack { engine?.store.stack(host) ?? Store.Stack(members: [host]) }
    static func kindName(_ p: Pose) -> String { p.isCore ? "Core" : LayoutView.typeNames[p.t & 0x1f] ?? L("모듈") }
    struct StackEntry { let host, shownId, letter, kind, title: String; let stack: Store.Stack
        func name(_ i: Int) -> String { stack.names[stack.members[i]] ?? "\(kind) \(i + 1)" } }
    /// The 묶음's stacks in board order, lettered A, B, … with the module's position and kind.
    var stackList: [StackEntry] { stackList(shown) }
    func stackList(_ shown: [Shown]) -> [StackEntry] {
        guard let e = engine else { return [] }
        let mods = board.modules
        let all = e.store.stacks(e.store.activeProfile)
        var out: [StackEntry] = []
        for s in shown {
            guard let i = s.boardIndex, i < mods.count, let st = all[mods[i].u] else { continue }
            let h = mods[i].u
            let letter = String(UnicodeScalar(UInt8(65 + out.count % 26))), kind = Self.kindName(s.pose)
            let pos = s.path.map { $0.isEmpty ? "Core" : "P" + $0 } ?? L("떠 있음")
            out.append(StackEntry(host: h, shownId: s.id, letter: letter, kind: kind, title: L("스택 \(letter) · ") + (moduleName(h).isEmpty ? (pos == kind ? kind : pos + " " + kind) : moduleName(h)), stack: st)) // the 1층 name the person gave wins over position and kind
        }
        return out
    }
    /// "스택 A › 밝은 영역" for a member, "스택 A" for a host; says so when the target is gone.
    func stackLabel(_ u: String, member: Bool) -> String {
        guard let e = stackList.first(where: { member ? $0.stack.members.contains(u) : $0.host == u }) else { return L("스택 (대상 없음)") }
        let head = L("스택 \(e.letter)") + (moduleName(e.host).isEmpty ? "" : " · " + moduleName(e.host))
        guard member, let i = e.stack.members.firstIndex(of: u) else { return head }
        return "\(head) › \(e.name(i))"
    }
    @discardableResult func stackAdd(_ host: String) -> String? { engine?.store.addStackMember(host) }
    /// The profile's module behind a control (or module) uuid as the board shows it.
    func moduleHost(_ uuid: String) -> String? { let b = uuid.components(separatedBy: "::")[0]; return shown.first { $0.pose.u == b }.flatMap(host(of:)) }
    func moduleName(_ host: String) -> String { engine?.store.moduleName(host) ?? "" }
    func setModuleName(_ host: String, _ name: String) { engine?.store.setModuleName(host, name) }
    func stackRemove(_ host: String, _ u: String) { engine?.store.removeStackMember(host, u) }
    func stackRename(_ host: String, _ u: String, _ name: String) { engine?.store.renameStackMember(host, u, name.trimmingCharacters(in: .whitespaces)) }
    func stackSwitch(_ host: String, to i: Int) { engine?.store.switchStack(host, to: i) }
    /// 스택에 넣기, then attach the module just put in, so the board and the 연결 화면 still show what was moved.
    func stackInto(_ host: String, _ u: String) {
        engine?.store.stackInto(host, u)
        if let i = stack(host).members.firstIndex(of: u) { stackSwitch(host, to: i) }
    }
    /// "P3 다이얼 · 톤 · 스택 2" for the 스택에 넣기 menu and question.
    func boardName(_ p: Pose) -> String {
        let n = stack(p.u).members.count
        return ([address(p.u).components(separatedBy: " ")[0] + " " + Self.kindName(p), moduleName(p.u)] + (n > 1 ? [L("스택 \(n)")] : [])).filter { !$0.isEmpty }.joined(separator: " · ")
    }
    func stackTakeOut(_ host: String, _ u: String) { engine?.store.takeOutOfStack(host, u) }
    /// Board modules of `u`'s type it could join (C: 스택에 넣기 menu, A: drop onto one).
    func stackTargets(of u: String) -> [Pose] {
        let b = board
        guard let p = b.modules.first(where: { $0.u == u }), !p.isCore else { return [] }
        return b.modules.filter { $0.u != u && $0.t & 0x1f == p.t & 0x1f }
    }
    /// The one shown module that is real hardware right now: putting it in a stack leaves its place as a 임시 module.
    func isPlugged(_ u: String) -> Bool { shown.contains { $0.pose.u == u && $0.link == .connected } }

    func modules() -> [Module] { shown.flatMap(modules(for:)) }
    /// The same control after the hardware changed: a profile module's controls carry the hardware uuid while connected and the
    /// board id while unplugged, so a held pick follows its board module (else it showed 미할당 after an unplug). A temp one that left is gone.
    func refreshed(_ m: Module) -> Module? {
        let all = modules(), sub = m.uuid.components(separatedBy: "::").dropFirst()
        if let h = m.host, let x = all.first(where: { $0.host == h && $0.uuid.components(separatedBy: "::").dropFirst() == sub }) { return x }
        return all.first { $0.uuid == m.uuid }
    }
    /// The controls of one shown module box.
    /// Developer-theme address: "Core", "P0", "P0/3" by port path, plus "①②③" for the n-th control of a 3x module.
    func address(_ uuid: String) -> String {
        let base = uuid.components(separatedBy: "::")[0]
        let path = shown.first { $0.pose.u == base }?.path ?? hardwarePaths.first { $0.value.u == base }?.key
        let m = path.map { $0.isEmpty ? "Core" : "P" + $0 } ?? String(base.prefix(8))
        return Self.controlNumber(uuid).map { m + " " + String(UnicodeScalar(0x2460 + $0 - 1)!) } ?? m
    }
    static func controlNumber(_ uuid: String) -> Int? { uuid.components(separatedBy: "::").dropFirst().first.flatMap { Int($0.filter(\.isNumber)) } }

    func modules(for s: Shown) -> [Module] {
            var out: [Module] = []
            let u = s.pose.u, subs: [(String, String)]
            switch s.pose.t & 0x1f {
            case 0, 25: subs = [("::button1", "button"), ("::button2", "button")]      // Palette core / Condor core
            case 1: subs = [("", "button")]
            case 2: subs = [("", "dial")]
            case 3: subs = [("", "slider")]
            case 8: subs = (1...3).map { ("::button\($0)", "button") }               // Essential Keys
            case 9: subs = (1...3).map { ("::dial\($0)", "dial") }
            case 10: subs = (1...3).map { ("::slider\($0)", "slider") }
            case 24: subs = [("", "orbiter")]                                       // Orbiter: ring + tilt pad in one assignment (preset type "orbiter")
            default: subs = []                                                        // FalconMini etc.
            }
            // Core ports verified on hardware: female pogo ports numbered clockwise from the USB side: c[0] top-left, c[1] top-right, c[2] right, c[3] bottom-right, c[4] bottom-left.
            // shortcut: modules chained behind another module keep the port of the one plugged into the Core
            let port = s.path.flatMap { $0.isEmpty ? nil : Int($0.split(separator: "/")[0]) }
            let depth = s.path.map { $0.isEmpty ? 0 : $0.split(separator: "/").count } ?? 1
            let ghost = s.link == .missing || s.link == .loose || s.link == .turned || { if case .mismatch = s.link { return true }; return false }()
            let h = host(of: s)
            for (suffix, type) in subs { out.append(Module(uuid: u + suffix, type: type, depth: depth, port: port, localId: s.localId, ghost: ghost, host: h)) }
            return out
    }
}

struct Module: Identifiable, Hashable {
    let uuid: String
    let type: String
    let depth: Int
    let port: Int?   // Core port index (c[]), nil for the Core itself
    let localId: Int? // firmware local id (layout `i`)
    var ghost = false // remembered by the profile but not connected
    var host: String? = nil // the profile's own module (board id) behind it; nil for a temp
    var id: String { uuid }
}

/// Live hardware state: changes on every control event (many times a second while a dial turns).
/// Kept out of `ServiceClient` on purpose: everything observing the service (wiring screen, editors, sidebar) would redraw per tick.
/// Only leaf views that show it observe this object.
final class Live: ObservableObject {
    @Published var active: [String: Date] = [:] // submodule uuid → lit until (distantFuture while a button is held)
    @Published var pose: [String: (angle: Double, x: Double, y: Double)] = [:] // dial/orbiter indicators: pointer angle in degrees, tilt −1…1
    @Published var value: [String: Double] = [:]        // what the app says the dial's function is at now (Lightroom plugin)
    @Published var raw: [String: [Int]] = [:]           // developer view: last decoded raw per submodule
    @Published var ledFrame: [String: RGB] = [:]        // what the Core's LEDs show now (board preview), empty while unplugged
    @Published var events: [Engine.Event] = []          // developer log, newest first, capped
    @Published var toast: (uuid: String, label: String)? // 값 알림 on screen now
}
