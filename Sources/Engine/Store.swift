import Foundation

/// Profiles and preferences. Same JSON shape as the Monogram service's state.json so the user's
/// existing profiles import unchanged: profile = {id,title,app,tags,icon,lastActivated,assignments}.
public final class Store {
    public static let legacyState = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Monogram/Service/state.json")
    public static let ownState = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Knobtile/state.json")
    public private(set) var profiles: [[String: Any]] = []
    public private(set) var preferences: [String: Any] = ["screenRotation": 270, "screenRotationFixed": true, "modeSwitchingEnabled": true, "dynamicColorEnabled": true, "autoProfileSwitchingEnabled": true]
    /// 루트 프로필: the floor every profile inherits slot by slot (an empty slot bubbles up to it). Lives outside `profiles`, so
    /// lists, 묶음 cycling and closing never see it. Keys are "port path::sub" ("" = Core), so it is independent of the Core's uuid.
    public private(set) var root: [String: Any] = ["assignments": ["::button1": switcherHold, "::button2": switcherHold]] { didSet { Keymap.user = root["keymaps"] as? [String: Any] ?? [:] } }
    static let switcherHold: [String: Any] = ["app": "", "preset": "", "settings": ["pressAndHold": ["dispatch": ["type": "PROFILE_SWITCHER"]]]]
    /// Inspector edits the root instead of the active profile (editing selection, the Core does not switch).
    public var editingRoot = false
    /// ⌘Z (연결 화면 and 모듈 디자이너): the profiles before each edit made by hand (assign, board, stack members, names), newest last.
    /// Stack switching is not recorded: the hardware does it all the time.
    private var undoStack: [(profiles: [[String: Any]], root: [String: Any])] = []
    private func mark() {
        if let t = undoStack.last, (t.profiles as NSArray) == (profiles as NSArray), (t.root as NSDictionary) == (root as NSDictionary) { return } // an edit made of several steps is one undo
        undoStack.append((profiles, root)); if undoStack.count > 50 { undoStack.removeFirst() }
    }
    public func undo() { guard let s = undoStack.popLast() else { return }; profiles = s.profiles; root = s.root; changed() }
    public var onChange: (() -> Void)?
    /// Bundle id of the frontmost app, used to narrow next/previous cycling (service's `focus`).
    public var focus = ""
    let catalog: Catalog
    private var saveTimer: Timer?

    let saveURL: URL
    public init(catalog: Catalog, url: URL? = nil) {
        self.catalog = catalog
        saveURL = url ?? Self.ownState
        if url == nil { Self.backup(Self.ownState) } // before anything of this run is written
        let url = url ?? (FileManager.default.fileExists(atPath: Self.ownState.path) ? Self.ownState : Self.legacyState)
        if let d = try? Data(contentsOf: url), let s = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            profiles = s["profiles"] as? [[String: Any]] ?? []
            for (k, v) in s["preferences"] as? [String: Any] ?? [:] { preferences[k] = v }
            // The old default 0 drew the Core's title sideways (photo 2026-11-16); 270 reads upright. One-time move of a saved 0.
            if (s["preferences"] as? [String: Any])?["screenRotationFixed"] == nil {
                if (preferences["screenRotation"] as? Int ?? 0) == 0 { preferences["screenRotation"] = 270 }
                preferences["screenRotationFixed"] = true
            }
            if let r = s["root"] as? [String: Any] { root = r }
            Keymap.user = root["keymaps"] as? [String: Any] ?? [:] // didSet does not run inside init
        }
        if profiles.isEmpty { profiles = [Self.newProfile(title: "Profile 1", app: "")] }
        moveRootToModules()
    }
    /// One-time move (2026-11-16): root wiring saved by port path goes to the board module at that path, in every 묶음's board
    /// (a stack's attached member). The Core ("") and paths no board has stay by position.
    func moveRootToModules() {
        var a = root["assignments"] as? [String: Any] ?? [:], done = false
        for (k, v) in a {
            let parts = k.components(separatedBy: "::")
            guard parts[0] != "", Self.isPath(parts[0]) else { continue }
            var ids: Set<String> = []
            for p in profiles { let b = board(p); if let i = b.index(at: parts[0]) { let u = b.modules[i].u; ids.insert(stacks(p)[u].map { $0.members[$0.index] } ?? u) } }
            guard !ids.isEmpty else { continue }
            for u in ids { let nk = ([u] + parts.dropFirst()).joined(separator: "::"); if a[nk] == nil { a[nk] = v } }
            a[k] = nil; done = true
        }
        if done { root["assignments"] = a; save() }
    }

    /// 자동 백업: one copy of the state file per day in Backups/ beside it, the newest `keep` kept. Restore = 프로필 가져오기 → 모두 바꾸기 with that file.
    @discardableResult static func backup(_ state: URL, day: Date = Date(), keep: Int = 14) -> URL? {
        let fm = FileManager.default, dir = state.deletingLastPathComponent().appendingPathComponent("Backups")
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let to = dir.appendingPathComponent("state-\(f.string(from: day)).json")
        guard fm.fileExists(atPath: state.path), !fm.fileExists(atPath: to.path) else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? fm.copyItem(at: state, to: to)) != nil else { return nil }
        for n in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter({ $0.hasPrefix("state-") }).sorted().dropLast(keep) { try? fm.removeItem(at: dir.appendingPathComponent(n)) }
        return to
    }
    public static var backupsDir: URL { ownState.deletingLastPathComponent().appendingPathComponent("Backups") }

    /// 직접 만든 패널 목록: [{name, items: [one-shot slot value + "label"]}]. Kept in the root, so every profile uses them and they travel with it (export, import, ⌘Z).
    /// (51) The user's shortcut changes and own items, kept in the root like the panel lists: [app: [id: item]] (Keymap).
    public var keymaps: [String: Any] { root["keymaps"] as? [String: Any] ?? [:] }
    public func setKeymaps(_ k: [String: Any]) { mark(); root["keymaps"] = k.isEmpty ? nil : k; changed() }
    public var panels: [[String: Any]] { root["panels"] as? [[String: Any]] ?? [] }
    public func setPanels(_ p: [[String: Any]]) { mark(); root["panels"] = p.isEmpty ? nil : p; changed() }
    /// A list is wired by its name ({"panel": "list:<name>"}): renaming it rewrites those wires in every profile and the root.
    public func renamePanel(_ old: String, to new: String) {
        guard !new.isEmpty, panels.contains(where: { $0["name"] as? String == old }), !panels.contains(where: { $0["name"] as? String == new }) else { return }
        mark()
        func fix(_ v: Any) -> Any {
            if var d = v as? [String: Any] { if d["panel"] as? String == "list:" + old { d["panel"] = "list:" + new }; return d.mapValues(fix) }
            if let a = v as? [Any] { return a.map(fix) }
            return v
        }
        profiles = profiles.map { fix($0) as! [String: Any] }
        root = fix(root) as! [String: Any]
        root["panels"] = panels.map { p in var p = p; if p["name"] as? String == old { p["name"] = new }; return p }
        changed()
    }

    static func newProfile(title: String, app: String) -> [String: Any] {
        ["id": UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(21).description,
         "title": title, "app": app, "tags": [], "assignments": [:], "lastActivated": Int(Date().timeIntervalSince1970 * 1000)]
    }

    // MARK: - Queries

    public var activeProfile: [String: Any] {
        profiles.max { num($0["lastActivated"]) ?? 0 < num($1["lastActivated"]) ?? 0 } ?? [:]
    }
    public func profile(_ id: String) -> [String: Any]? { profiles.first { $0["id"] as? String == id } }

    // MARK: - Position matching (a profile binds module *type at a position*, never a serial number)

    /// Connected hardware: port path from the Core ("2", "2/0", "" = Core) → (layout uuid, type id). Set by the Engine.
    public var hardware: [String: (u: String, t: Int)] = [:] {
        // A profile without a saved layout keys its Core assignments under the connected Core's uuid; unplugged, the empty
        // board must still name that Core or the inspector shows 미할당.
        didSet { if let c = hardware[""], preferences["lastCoreUuid"] as? String != c.u { preferences["lastCoreUuid"] = c.u; scheduleSave() } }
    }
    /// The profile's design board (v2 `layout`, or converted from the older path-keyed form). Always has the Core at index 0.
    public func board(_ p: [String: Any]) -> Board {
        Board(layout: p["layout"]) ?? .empty(coreU: hardware[""]?.u ?? preferences["lastCoreUuid"] as? String ?? "v:core", coreT: hardware[""]?.t ?? 25)
    }
    /// The profile's remembered hardware as path → (u, t), derived from the board's geometry.
    public func snapshot(_ p: [String: Any]) -> [String: (u: String, t: Int)] { board(p).derived() }
    public static func sameType(_ a: Int, _ b: Int) -> Bool { a & 0x1f == b & 0x1f }
    /// profile uuid → connected uuid where the same module type sits at the same position.
    public func alias(_ p: [String: Any]) -> [String: String] {
        var m: [String: String] = [:]
        let st = stacks(p)
        let b = board(p), paths = b.paths()
        for (i, s) in b.modules.enumerated() { // every board module, also one lying apart from the Core (no path): it keeps its assignments, only nothing is connected
            let a = st[s.u].map { $0.members[$0.index] } ?? s.u // 스택: the attached member stands at the host's position
            if let path = paths[i], let h = hardware[path], Self.sameType(s.t, h.t) { m[a] = h.u }
            else if a != s.u { m[a] = s.u } // unplugged: the board shows and edits the attached member under the host's id
        }
        return m
    }
    /// Assignments re-keyed to the connected modules. A uuid the snapshot knows applies only through its position: with nothing
    /// connected there it stays under its own id (the board shows and edits it that way); unknown ones (imported) apply directly.
    public func assignments(_ p: [String: Any]) -> [String: Any] {
        let al = alias(p), known = Set(board(p).modules.map(\.u))
        let idle = Set(stacks(p).values.flatMap { s in s.members.filter { $0 != s.members[s.index] } }) // 스택 members not attached now
        var out: [String: Any] = [:], placed: Set<String> = []
        for (k, v) in p["assignments"] as? [String: Any] ?? [:] {
            let parts = k.components(separatedBy: "::")
            if idle.contains(parts[0]) { continue }
            // Only modules on the profile's board carry assignments: a connected module not applied yet (임시) stays empty,
            // and entries left under its hardware id are taken over when it is applied (`adopt`). A profile with no board at all
            // (imported, never laid out) still applies them directly.
            let ghost = known.contains(parts[0]) && !hardware.values.contains { $0.u == parts[0] } // on the board, not connected: shown and edited under its own id
            guard let b = al[parts[0]] ?? (p["layout"] == nil || ghost ? parts[0] : nil) else { continue }
            let key = ([b] + parts.dropFirst()).joined(separator: "::")
            // the profile's own module (by position) beats an imported entry keyed by the same hardware id; without this the winner changed per launch
            if al[parts[0]] != nil { placed.insert(key) } else if placed.contains(key) { continue }
            out[key] = v
        }
        return out
    }
    public func hasAssignments(_ p: [String: Any], base: String) -> Bool { (p["assignments"] as? [String: Any] ?? [:]).keys.contains { $0.components(separatedBy: "::")[0] == base } }
    /// Replace the board (the only layout mutation). A 묶음 (profiles of one app) shares one board and differs only in
    /// assignments, so every profile of the active one's app gets it; removed modules lose their assignments.
    public func setBoard(_ b: Board) {
        mark()
        let a = app(of: activeProfile)
        for i in profiles.indices where app(of: profiles[i]) == a {
            let gone = Set(board(profiles[i]).modules.map(\.u)).subtracting(b.modules.map(\.u))
            for u in gone {
                for m in stacks(profiles[i])[u]?.members ?? [u] { dropAssignments(&profiles[i], base: m) }
                if var all = profiles[i]["stacks"] as? [String: Any] { all[u] = nil; profiles[i]["stacks"] = all.isEmpty ? nil : all }
            }
            if let names = profiles[i]["moduleNames"] as? [String: String] { // names of modules no longer on the board go too (also ones left by older builds)
                let kept = names.filter { n in b.modules.contains { $0.u == n.key } }
                profiles[i]["moduleNames"] = kept.isEmpty ? nil : kept
            }
            profiles[i]["layout"] = b.json
        }
        changed()
    }
    /// "적용": a connected module the profile does not have yet becomes part of it (its parents too). Returns its board index.
    @discardableResult public func adopt(_ path: String) -> Int? {
        var b = board(activeProfile)
        if let i = b.index(at: path) { return i }
        guard let h = hardware[path] else { return nil }
        let parent = path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : ""
        if b.index(at: parent) == nil { guard adopt(parent) != nil else { return nil }; b = board(activeProfile) }
        // the profile's copy is a logical module with its own id: hardware pairs with it by position only, like a palette module
        guard let p = b.pose(at: path, t: h.t, u: "v:" + UUID().uuidString.prefix(8)), !b.overlaps(p) else { return nil }
        b.modules.append(p); setBoard(b)
        // Entries imported under the hardware id move to the new module, except other apps' leftovers (e.g. Final Cut functions in a Lightroom profile).
        let own = app(of: activeProfile)
        for i in profiles.indices where app(of: profiles[i]) == own {
            var a = profiles[i]["assignments"] as? [String: Any] ?? [:]
            for (k, v) in a where k.components(separatedBy: "::")[0] == h.u {
                let from = (v as? [String: Any])?["app"] as? String ?? ""
                guard from.isEmpty || from == own else { continue }
                let nk = ([p.u] + k.components(separatedBy: "::").dropFirst()).joined(separator: "::")
                if a[nk] == nil { a[nk] = v }; a[k] = nil
            }
            profiles[i]["assignments"] = a
        }
        changed()
        return b.modules.count - 1
    }
    private func dropAssignments(_ p: inout [String: Any], base: String) {
        p["assignments"] = (p["assignments"] as? [String: Any] ?? [:]).filter { $0.key.components(separatedBy: "::")[0] != base }
    }
    func app(of p: [String: Any]) -> String { p["app"] as? String ?? "" }

    // MARK: - 스택 (2층): one board module, several logical modules of its type taking turns on it

    /// members[0] is the host (the board module) itself; `index` is the one attached now. A 묶음 shares its stacks like its board.
    public struct Stack: Equatable {
        public var members: [String], index: Int, names: [String: String]
        public init(members: [String], index: Int = 0, names: [String: String] = [:]) { self.members = members; self.index = index; self.names = names }
    }
    /// host uuid → stack. Only real stacks (two or more members) are stored; one member is a plain module.
    public func stacks(_ p: [String: Any]) -> [String: Stack] {
        var out: [String: Stack] = [:]
        for (h, v) in p["stacks"] as? [String: Any] ?? [:] {
            guard let d = v as? [String: Any], let m = d["members"] as? [String], m.count > 1, m[0] == h else { continue }
            out[h] = Stack(members: m, index: min(max(Int(num(d["index"]) ?? 0), 0), m.count - 1), names: d["names"] as? [String: String] ?? [:])
        }
        return out
    }
    public func stack(_ host: String) -> Stack { stacks(activeProfile)[host] ?? Stack(members: [host]) }
    private func setStack(_ host: String, _ s: Stack, also edit: ((inout [String: Any]) -> Void)? = nil) {
        let a = app(of: activeProfile)
        for i in profiles.indices where app(of: profiles[i]) == a {
            var all = profiles[i]["stacks"] as? [String: Any] ?? [:]
            all[host] = s.members.count > 1 ? ["members": s.members, "index": s.index, "names": s.names] as [String: Any] : nil
            profiles[i]["stacks"] = all.isEmpty ? nil : all
            edit?(&profiles[i])
        }
        changed()
    }
    /// 1층 모듈 이름: the person's own name for a board module (stacked or not), shared by the 묶음 like the board itself.
    public func moduleName(_ host: String) -> String { (activeProfile["moduleNames"] as? [String: String])?[host] ?? "" }
    public func setModuleName(_ host: String, _ name: String) {
        guard name != moduleName(host) else { return }
        mark()
        let a = app(of: activeProfile)
        for i in profiles.indices where app(of: profiles[i]) == a {
            var all = profiles[i]["moduleNames"] as? [String: String] ?? [:]
            all[host] = name.isEmpty ? nil : name
            profiles[i]["moduleNames"] = all.isEmpty ? nil : all
        }
        changed()
    }
    /// "+ 추가": a new empty member of the host's type, attached at once so the board and the 연결 화면 edit it.
    @discardableResult public func addStackMember(_ host: String) -> String {
        mark()
        if activeProfile["layout"] == nil { setBoard(board(activeProfile)) } // the host's uuid must outlive the connected hardware
        var s = stack(host)
        let u = "v:" + UUID().uuidString.prefix(8)
        s.members.append(u); s.index = s.members.count - 1
        setStack(host, s)
        return u
    }
    /// Removing the first member hands the host's place (and its assignments' key) to the next one. One member left = a plain module again.
    public func removeStackMember(_ host: String, _ u: String) {
        var s = stack(host)
        guard s.members.count > 1, let k = s.members.firstIndex(of: u) else { return }
        mark()
        s.members.remove(at: k); s.names[u] = nil
        let heir = k == 0 ? s.members[0] : nil
        if let heir { s.names[host] = s.names[heir]; s.names[heir] = nil; s.members[0] = host }
        if k < s.index || s.index >= s.members.count { s.index = max(0, s.index - 1) }
        dropAssignments(&root, base: u) // the root is keyed by member id too
        if let heir { moveAssignments(&root, from: heir, to: host) }
        setStack(host, s) { p in
            self.dropAssignments(&p, base: u)
            if let heir { self.moveAssignments(&p, from: heir, to: host) }
        }
    }
    private func moveAssignments(_ p: inout [String: Any], from: String, to: String) {
        var a = p["assignments"] as? [String: Any] ?? [:]
        for (key, v) in a where key.components(separatedBy: "::")[0] == from { a[key] = nil; a[to + String(key.dropFirst(from.count))] = v }
        p["assignments"] = a
    }
    /// (52) 스택에 넣기: board module `u` (with its own stack) joins `host`'s stack and leaves the board.
    /// Members keep their ids, so their assignments stay as they are; its 1층 name becomes its member name.
    public func stackInto(_ host: String, _ u: String) {
        var b = board(activeProfile)
        guard host != u, let k = b.modules.firstIndex(where: { $0.u == u }), let h = b.modules.first(where: { $0.u == host }),
              h.t & 0x1f == b.modules[k].t & 0x1f, !h.isCore else { return }
        mark()
        let moved = stack(u)
        var s = stack(host)
        s.members += moved.members
        s.names.merge(moved.names) { a, _ in a }
        if s.names[u] == nil, !moduleName(u).isEmpty { s.names[u] = moduleName(u) }
        b.modules.remove(at: k)
        let a = app(of: activeProfile)
        for i in profiles.indices where app(of: profiles[i]) == a {
            var all = profiles[i]["stacks"] as? [String: Any] ?? [:]
            all[u] = nil; all[host] = ["members": s.members, "index": s.index, "names": s.names] as [String: Any]
            profiles[i]["stacks"] = all
            if var n = profiles[i]["moduleNames"] as? [String: String] { n[u] = nil; profiles[i]["moduleNames"] = n.isEmpty ? nil : n }
            profiles[i]["layout"] = b.json
        }
        changed()
    }
    /// (52) 판으로 꺼내기: member `u` leaves the stack with its assignments and lies loose right of the board.
    /// Taking out the host: the board place stays with the rest of the stack, the taken module gets a new id. Returns the new board module's id.
    @discardableResult public func takeOutOfStack(_ host: String, _ u: String) -> String? {
        var s = stack(host), b = board(activeProfile)
        guard s.members.count > 1, let k = s.members.firstIndex(of: u), let h = b.modules.first(where: { $0.u == host }), !h.isCore else { return nil }
        mark()
        let out = k == 0 ? "v:" + UUID().uuidString.prefix(8) : u, name = s.names[u]
        b.modules.append(Pose(t: h.t, x: (b.modules.map { $0.x + $0.w }.max() ?? 0) + 1, y: b.modules.map(\.y).min() ?? 0, r: 0, u: out))
        s.members.remove(at: k); s.names[u] = nil
        let heir = k == 0 ? s.members[0] : nil
        if let heir { s.names[host] = s.names[heir]; s.names[heir] = nil; s.members[0] = host }
        if k < s.index || s.index >= s.members.count { s.index = max(0, s.index - 1) }
        if let heir { moveAssignments(&root, from: host, to: out); moveAssignments(&root, from: heir, to: host) } // the root is keyed by member id too
        let a = app(of: activeProfile)
        for i in profiles.indices where app(of: profiles[i]) == a {
            if let heir { moveAssignments(&profiles[i], from: host, to: out); moveAssignments(&profiles[i], from: heir, to: host) }
            var all = profiles[i]["stacks"] as? [String: Any] ?? [:]
            all[host] = s.members.count > 1 ? ["members": s.members, "index": s.index, "names": s.names] as [String: Any] : nil
            profiles[i]["stacks"] = all.isEmpty ? nil : all
            if let name { var n = profiles[i]["moduleNames"] as? [String: String] ?? [:]; n[out] = name; profiles[i]["moduleNames"] = n }
            profiles[i]["layout"] = b.json
        }
        changed()
        return out
    }
    public func renameStackMember(_ host: String, _ u: String, _ name: String) {
        var s = stack(host)
        guard s.members.contains(u), s.members.count > 1, s.names[u] ?? "" != name else { return }
        mark()
        s.names[u] = name.isEmpty ? nil : name
        setStack(host, s)
    }
    /// Attach member `i` of the host's stack to its hardware; wraps, so index + 1 is "next".
    public func switchStack(_ host: String, to i: Int) {
        var s = stack(host)
        guard s.members.count > 1 else { return }
        s.index = (i % s.members.count + s.members.count) % s.members.count
        setStack(host, s)
    }
    /// The stack a member belongs to and its place in it (button actions name the member, so reordering or removing others is safe).
    public func stack(ofMember u: String) -> (host: String, index: Int)? {
        for (h, s) in stacks(activeProfile) { if let i = s.members.firstIndex(of: u) { return (h, i) } }
        return nil
    }
    /// 프로필 묶음 = 같은 앱의 프로필들. The app is on `screen` (LrC module / Resolve page): the bundle's latest profile
    /// for that screen, else its latest screen-less (default) profile. nil → the bundle has nothing for it, stay put.
    public func profile(app: String, screen: String) -> [String: Any]? {
        let bundle = profiles.filter { self.app(of: $0) == app }
        func latest(_ sc: String) -> [String: Any]? { bundle.filter { ($0["screen"] as? String ?? "") == sc }.max { num($0["lastActivated"]) ?? 0 < num($1["lastActivated"]) ?? 0 } }
        return latest(screen) ?? latest("")
    }

    /// Process identifiers this profile's app answers to (the app id itself plus its bundle ids).
    func compatibleBundles(_ p: [String: Any]) -> [String] {
        let id = app(of: p).lowercased()
        return id.isEmpty ? [] : [id] + (catalog.app(id)?.processIdentifiers ?? [])
    }
    func matching(_ bundles: [String]) -> [[String: Any]] {
        profiles.filter { !Set(compatibleBundles($0)).isDisjoint(with: bundles.map { $0.lowercased() }) }
    }
    func matchingOrAppless(_ bundles: [String]) -> [[String: Any]] {
        let m = matching(bundles)
        return m.isEmpty ? profiles.filter { app(of: $0).isEmpty } : m
    }

    // MARK: - Mutations (names follow the service's redux actions)

    public func activate(_ id: String) {
        guard let i = profiles.firstIndex(where: { $0["id"] as? String == id }) else { return }
        // strictly newer than every other profile, even within the same millisecond
        let latest = profiles.compactMap { num($0["lastActivated"]) }.max() ?? 0
        profiles[i]["lastActivated"] = max(Int(Date().timeIntervalSince1970 * 1000), Int(latest) + 1)
        changed()
    }

    /// Frontmost app changed: switch to the latest profile for it (or the latest app-less one).
    public func activateApps(_ bundles: [String], focused: String) {
        focus = focused.lowercased()
        guard let latest = matchingOrAppless(bundles).max(by: { num($0["lastActivated"]) ?? 0 < num($1["lastActivated"]) ?? 0 }),
              latest["id"] as? String != activeProfile["id"] as? String else { return }
        activate(latest["id"] as! String)
    }

    /// The 묶음's pages in sidebar order: the default (screen-less, latest) first, then the rest in list order (drag in the sidebar to change).
    public func bundle(_ app: String) -> [[String: Any]] {
        let all = profiles.filter { self.app(of: $0) == app }
        guard let head = profile(app: app, screen: "") else { return all }
        return [head] + all.filter { $0["id"] as? String != head["id"] as? String }
    }
    /// Next Page / Previous Page: move within the active profile's 묶음 only. With two or more screen pages the default
    /// stays out of the loop (it is the fallback for screens without a page); from it the button goes to the first page.
    public func nextScreen(by: Int) {
        let cur = activeProfile, all = bundle(app(of: cur))
        let pages = all.filter { !($0["screen"] as? String ?? "").isEmpty }
        let list = pages.count > 1 ? pages : all
        guard list.count > 1 else { return }
        guard let i = list.firstIndex(where: { $0["id"] as? String == cur["id"] as? String }) else { activate(list[0]["id"] as! String); return }
        activate(list[(i + by + list.count) % list.count]["id"] as! String)
    }
    /// Next/Previous Profile: move to another app's 묶음 (its latest profile); pages within a 묶음 are Next/Previous Page.
    /// The original app cycled only within the frontmost app's profiles, which with one profile per app never moves.
    public func nextProfile(autoSwitch: Bool) { cycle(by: 1) }
    public func previousProfile(autoSwitch: Bool) { cycle(by: -1) }
    private func cycle(by: Int) {
        let apps = bundleApps()
        guard apps.count > 1, let i = apps.firstIndex(of: app(of: activeProfile)) else { return }
        activateBundle(apps[(i + by + apps.count) % apps.count])
    }
    /// 묶음(앱) ids in sidebar order.
    public func bundleApps() -> [String] {
        var apps: [String] = []
        for p in profiles where !apps.contains(app(of: p)) { apps.append(app(of: p)) }
        return apps
    }
    /// Switch to a 묶음: its most recently used profile.
    public func activateBundle(_ a: String) {
        if let p = profiles.filter({ app(of: $0) == a }).max(by: { num($0["lastActivated"]) ?? 0 < num($1["lastActivated"]) ?? 0 }) { activate(p["id"] as! String) }
    }
    /// The 묶음 used before the current one (⌘Tab's first candidate), nil with one 묶음.
    public var previousApp: String? {
        let cur = app(of: activeProfile)
        return profiles.filter { app(of: $0) != cur }.max { num($0["lastActivated"]) ?? 0 < num($1["lastActivated"]) ?? 0 }.map(app(of:))
    }

    @discardableResult public func addProfile(title: String = L("새 프로필"), app: String = "") -> String {
        let p = Self.newProfile(title: title, app: app)
        profiles.append(p); changed()
        return p["id"] as! String
    }
    public func updateProfile(_ id: String, _ fields: [String: Any]) {
        guard let i = profiles.firstIndex(where: { $0["id"] as? String == id }) else { return }
        for (k, v) in fields { profiles[i][k] = v }
        if let a = fields["app"] as? String, let peer = profiles.first(where: { app(of: $0) == a && $0["id"] as? String != id }) {
            profiles[i]["layout"] = peer["layout"]; profiles[i]["stacks"] = peer["stacks"]; profiles[i]["moduleNames"] = peer["moduleNames"] // joining a 묶음 means taking its board and its stacks
        }
        changed()
    }
    public func closeProfile(_ id: String) {
        profiles.removeAll { $0["id"] as? String == id }
        if profiles.isEmpty { profiles.append(Self.newProfile(title: L("새 프로필"), app: "")) } // as the original: the list is never empty
        changed()
    }
    /// Backup file: the profiles of one app (nil = all of them), with the root when asked.
    public func bundle(app: String? = nil, root withRoot: Bool) -> [String: Any] {
        var f: [String: Any] = ["profiles": profiles.filter { app == nil || self.app(of: $0) == app }]
        if withRoot { f["root"] = root }
        return f
    }
    /// Reads a backup file or a single profile file. Added profiles get new ids and never become the active one
    /// (a single profile does, as before); `replace` swaps the whole list and keeps ids and the active profile. ⌘Z undoes it.
    @discardableResult public func restore(_ file: [String: Any], replace: Bool = false, root withRoot: Bool = false) -> Bool {
        let single = file["profiles"] == nil
        let list = (single ? [file] : file["profiles"] as? [[String: Any]] ?? []).filter { $0["assignments"] is [String: Any] }
        guard !list.isEmpty else { return false }
        mark()
        if replace && !single { profiles = list }
        else {
            profiles += list.map { p in
                var p = p
                p["id"] = Self.newProfile(title: "", app: "")["id"]
                p["lastActivated"] = single ? Int(Date().timeIntervalSince1970 * 1000) : 0
                return p
            }
        }
        if withRoot, let r = file["root"] as? [String: Any], r["assignments"] is [String: Any] { root = r }
        // a plugin's starter.json brings the 패널 목록 its profiles open; one the user already has (same name) is kept
        let new = (file["panels"] as? [[String: Any]] ?? []).filter { l in !panels.contains { $0["name"] as? String == l["name"] as? String } }
        if !new.isEmpty { root["panels"] = panels + new }
        changed()
        return true
    }
    public func reorder(_ ids: [String]) {
        profiles.sort { (ids.firstIndex(of: $0["id"] as? String ?? "") ?? .max) < (ids.firstIndex(of: $1["id"] as? String ?? "") ?? .max) }
        changed()
    }
    /// assignment = {preset, app?, settings} or nil to clear. Applies to the active profile.
    public func assign(_ uuid: String, _ assignment: [String: Any]?) {
        mark()
        if editingRoot { assignRoot(uuid, assignment); return }
        guard let i = profiles.firstIndex(where: { $0["id"] as? String == activeProfile["id"] as? String }) else { return }
        let parts = uuid.components(separatedBy: "::")
        var base = parts[0]
        if let x = alias(profiles[i]).first(where: { $0.value == base })?.key { base = x } // write under the profile's own module at this position
        else if let path = hardware.first(where: { $0.value.u == base })?.key, adopt(path) != nil, // assigning to a connected module applies it to the profile
                let x = alias(profiles[i]).first(where: { $0.value == base })?.key { base = x }
        var a = profiles[i]["assignments"] as? [String: Any] ?? [:]
        a[([base] + parts.dropFirst()).joined(separator: "::")] = assignment
        profiles[i]["assignments"] = a
        changed()
    }
    /// Root assignments re-keyed to the connected modules, same shape as `assignments(_:)`. Keys are the board module's id
    /// (the wiring belongs to the virtual module and follows it when moved or stacked); a port path ("" = Core, older entries) still works.
    public func rootAssignments() -> [String: Any] {
        var byPath: [String: Any] = [:], byId: [String: Any] = [:]
        for (k, v) in root["assignments"] as? [String: Any] ?? [:] {
            let parts = k.components(separatedBy: "::")
            if Self.isPath(parts[0]) { if let u = unit(at: parts[0]) { byPath[([u] + parts.dropFirst()).joined(separator: "::")] = v } } else { byId[k] = v }
        }
        var p = activeProfile; p["assignments"] = byId; if p["layout"] == nil { p["layout"] = board(p).json } // unknown ids never apply directly
        return byPath.merging(assignments(p)) { _, id in id }
    }
    static func isPath(_ s: String) -> Bool { s.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0.isEmpty ? s.isEmpty : Int($0) != nil } }
    /// Module uuid at a port path: the connected one, else the active profile's board (so the root is visible and editable unplugged).
    private func unit(at path: String) -> String? {
        if let h = hardware[path] { return h.u }
        let b = board(activeProfile); return b.index(at: path).map { b.modules[$0].u }
    }
    private func assignRoot(_ uuid: String, _ assignment: [String: Any]?) {
        let parts = uuid.components(separatedBy: "::")
        let b = board(activeProfile)
        let own = alias(activeProfile).first(where: { $0.value == parts[0] })?.key ?? (b.modules.contains { $0.u == parts[0] } ? parts[0] : nil)
        let path = hardware.first(where: { $0.value.u == parts[0] })?.key ?? b.paths().first(where: { b.modules[$0.key].u == parts[0] })?.value
        // the virtual module keeps its wiring; the Core (every profile's) and a module not on the board stay by position
        guard let key = path == "" ? path : own ?? path else { return }
        var a = root["assignments"] as? [String: Any] ?? [:]
        if key != path, let path { a[([path] + parts.dropFirst()).joined(separator: "::")] = nil } // an older entry at this position must not shadow it
        a[([key] + parts.dropFirst()).joined(separator: "::")] = assignment
        root["assignments"] = a
        changed()
    }
    public func setPreference(_ key: String, _ value: Any) { preferences[key] = value; changed() }

    private func changed() { onChange?(); scheduleSave() }
    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.save() }
    }
    public func save() {
        let s: [String: Any] = ["profiles": profiles, "preferences": preferences, "root": root]
        try? FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]).write(to: saveURL, options: .atomic)
    }
}
