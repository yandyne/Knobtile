import SwiftUI
import Engine

/// 연결 화면: covers the window when a module or control is picked on the board (proposal bind-c-screen.html).
/// Left: the controls in scope with one port per event. Right: the functions those controls use (one node per distinct
/// function), 대기 노드 (found via the search row, not wired yet) and the "⌕ 기능 찾기" row, which focused opens a browse panel
/// scoped to the profile's page (chips 페이지 · 앱 어디서나 · 공통 · 전체, ★ 추천, ↻ 다른 프로필, 묶음별). Wires join them; a badge on a wire shows its step. The dock at the bottom edits the picked
/// wire (its slot value) and the control it belongs to (the former inspector's AssignmentEditor).
struct WiringView: View {
    @EnvironmentObject var service: ServiceClient
    @Binding var module: Module?      // nil closes
    @Binding var whole: Bool          // true = every control of the module, false = this control only
    @State private var picked: Picked?
    @State private var drag: (port: String, at: CGPoint)?
    @State private var dragCancelled = false // esc during a pull: ignore the rest of this drag
    @State private var newFor: (uuid: String, slot: String)? // "+ 새 기능" opened for this port
    @State private var presetFor: Module?
    @State private var changing = false // dock "바꾸기" picker
    @State private var pickingB = false // dock "번갈아 실행" picker (the second function)
    @State private var staged: [Staged] = []   // 대기 노드: functions found but not wired yet (screen state only, never saved)
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var browsing = false            // search row was focused: chips·추천·묶음 stay open until esc
    @State private var scope: Scope?               // nil = this profile's default (its page, else the app)
    @State private var openSections: Set<String> = []
    enum Scope { case screen, app, common, all }
    struct Staged: Equatable { let label: String, app: String }  // app "" = 공통
    @AppStorage("wiringDockHeight") private var dockHeight = 300.0
    @State private var dockAtDragStart: Double?
    @State private var joining: StackJoin? // 스택에 넣기 menu: asks first

    enum Picked: Equatable { case wire(String, String), control(String), node(String), staged(String) }
    struct Wire: Identifiable { let uuid: String, slot: String, node: String, value: JSON, inherited: Bool; var id: String { uuid + "::" + slot } }

    // MARK: data

    /// Controls in scope. `whole` = all controls of the picked control's module.
    private var controls: [Module] {
        guard let module else { return [] }
        let base = module.uuid.components(separatedBy: "::")[0]
        return whole ? service.modules().filter { $0.uuid.components(separatedBy: "::")[0] == base } : [module]
    }
    /// A module (or another 2층 member) came up: keep the control that was picked, else the first one, so the dock is never empty.
    private func keepPick() {
        switch picked {
        case .control(let u) where controls.contains { $0.uuid == u }: break
        case .wire(let u, _) where controls.contains { $0.uuid == u }: picked = .control(u) // the wire belongs to the member that left
        default: picked = controls.first.map { .control($0.uuid) }
        }
    }
    private var modulesOnBoard: [[Module]] { // grouped by physical module, board order
        var order: [String] = [], by: [String: [Module]] = [:]
        for m in service.modules() { let b = m.uuid.components(separatedBy: "::")[0]; if by[b] == nil { order.append(b) }; by[b, default: []].append(m) }
        return order.map { by[$0]! }
    }
    /// Slot values in effect for a control: the engine's merged view (root inheritance), the stored assignment when unplugged or editing the root.
    private func settings(_ m: Module) -> JSON {
        let own = service.assignment(m.uuid)["settings"], eff = service.effective(m)
        return service.editingRoot || eff.isNull ? own : eff
    }
    private func wires(_ m: Module) -> [Wire] {
        let s = settings(m), inh = service.inherited(m), a = service.assignment(m.uuid)
        return Engine.slots(m.type).compactMap { slot in
            let v = s[slot]; guard !v.isNull else { return nil }
            return Wire(uuid: m.uuid, slot: slot, node: SlotText.describe(v, service: service, appId: appId, presetApp: a["app"].string ?? ""), value: v, inherited: inh.contains(slot))
        }
    }
    private var allWires: [Wire] { controls.flatMap(wires) }
    private var nodes: [(name: String, value: JSON, inherited: Bool)] { // first wire's value stands for the node
        var out: [(String, JSON, Bool)] = []
        for w in allWires where !out.contains(where: { $0.0 == w.node }) { out.append((w.node, w.value, w.inherited)) }
        let ws = allWires
        return out.map { n in (n.0, n.1, n.2 && ws.filter { $0.node == n.0 }.allSatisfy(\.inherited)) }
    }
    /// Ports shown for a control: every slot when it is the only one, else the basic ones plus the wired ones.
    private func slots(_ m: Module) -> [String] {
        let wired = Set(wires(m).map(\.slot))
        let stateful = service.assignment(m.uuid.components(separatedBy: "::")[0])["settings"]["buttonMode"].string != nil
        return Engine.slots(m.type).filter { $0 != "pressOff" || stateful || wired.contains($0) }.filter { !whole || controls.count == 1 || SlotText.basic.contains($0) || wired.contains($0) }
    }
    private var appId: String { service.editingRoot ? "" : service.activeProfile?["app"].string ?? "" }
    private func control(_ uuid: String) -> Module? { controls.first { $0.uuid == uuid } ?? service.modules().first { $0.uuid == uuid } }

    /// Edit one control's settings (creates the assignment when the control had none).
    /// slots that run once per press (per-tick ones like 왼쪽 회전 are left out)
    private static let oneShot: Set<String> = ["press", "doublePress", "doubleTap", "pressAndHold", "pressDown", "pressUp", "pressOff"]
    private func then(_ m: Module, _ slot: String, _ own: JSON, _ key: String, _ on: Any) -> Binding<Bool> {
        Binding(get: { !own["then"][key].isNull }, set: { v in self.update(m) {
            var t = $0[slot] as? [String: Any] ?? [:], n = t["then"] as? [String: Any] ?? [:]
            n[key] = v ? on : nil; t["then"] = n.isEmpty ? nil : n; $0[slot] = t } })
    }
    private func update(_ m: Module, _ edit: (inout [String: Any]) -> Void) {
        let a = service.assignment(m.uuid)
        var settings = a["settings"].any as? [String: Any] ?? [:]
        edit(&settings)
        service.dispatch("ASSIGN_MODULE", ["uuid": m.uuid, "assignment": ["app": a["app"].string ?? "", "preset": a["preset"].string ?? "", "settings": settings]])
    }
    private func set(_ uuid: String, _ slot: String, _ value: Any?) {
        guard let m = control(uuid) else { return }
        update(m) { if let value { $0[slot] = value } else { $0.removeValue(forKey: slot) } }
        picked = value == nil ? nil : .wire(uuid, slot)
    }

    /// Unplug a port; its function waits in 대기 중 (unless another wire still holds it) so it can be wired elsewhere without searching again.
    /// shortcut: found by matching the stored value to a picker item, so a function whose value was edited after wiring is not kept.
    private func cut(_ m: Module, _ slot: String) {
        if let w = wires(m).first(where: { $0.slot == slot }), !allWires.contains(where: { $0.node == w.node && ($0.uuid, $0.slot) != (m.uuid, slot) }) {
            for app in appId.isEmpty ? [""] : [appId, ""] {
                if let i = SlotPicker.items(service, app: app, type: m.type, slot: slot).first(where: { $0.value == w.value }) {
                    if !staged.contains(where: { $0.label == i.label }) { staged.append(Staged(label: i.label, app: app)) }
                    break
                }
            }
        }
        set(m.uuid, slot, nil)
    }

    // MARK: body

    var body: some View {
        VStack(spacing: 0) {
            strip
            Divider()
            floor
            HStack(alignment: .top, spacing: 0) {
                ScrollView { VStack(spacing: 10) { ForEach(controls) { box($0) } }.padding(12) }.frame(minWidth: 215, maxWidth: 290)
                Color.clear.frame(minWidth: 40, maxWidth: 110) // capped: the spare width goes to the names, not to the gap
                ScrollView { VStack(alignment: .leading, spacing: 6) {
                    Text(L("연결된 기능 · \(nodes.count)")).font(.caption).foregroundStyle(.secondary)
                    ForEach(nodes, id: \.name) { node($0) }
                    if !staged.isEmpty {
                        Text(L("대기 중 · \(staged.count) · 선을 이으면 연결됨")).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                        ForEach(staged, id: \.label) { stagedNode($0) }
                    }
                    searchRow
                }.padding(12) }.frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: "wiring")
            .overlayPreferenceValue(AnchorKey.self) { anchors in GeometryReader { g in canvas(anchors, g) } }
            Divider().overlay { // drag the edge to resize the dock
                Color.clear.frame(height: 8).contentShape(Rectangle())
                    .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in let s = dockAtDragStart ?? dockHeight; dockAtDragStart = s; dockHeight = min(max(s - v.translation.height, 120), 700) }
                        .onEnded { _ in dockAtDragStart = nil })
            }
            ScrollView { dock }.frame(height: dockHeight)
        }
        .background(.background)
        .onReceive(service.live.$active.map { $0.keys.sorted() }.removeDuplicates()) { keys in // touching a control brings it up; the scope (control / whole module) stays as it was
            if let u = keys.first(where: { k in service.modules().contains { $0.uuid == k } }), let m = service.modules().first(where: { $0.uuid == u }), !controls.contains(m) { module = m } // a whole module stays whole: only a control outside what is shown moves the screen
        }
        .confirmStackJoin($joining, service) { j in module = service.modules().first { $0.uuid.components(separatedBy: "::")[0] == j.u } ?? module }
        .popover(item: $presetFor) { m in PresetList(module: m).frame(width: 360, height: 480) }
        .onChange(of: appId) { staged = []; search = ""; scope = nil; openSections = [] } // another profile: its functions differ
        .background { Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).opacity(0) }
        // debug: snapshot notification {"search": text} / {"stage": label} drives the search row without a keyboard (remote captures)
        .onChange(of: (module?.uuid ?? "") + (whole ? "*" : ""), initial: true) { if !whole, let m = module { picked = .control(m.uuid) } else { keepPick() } } // control clicked on the board: the dock shows it at once
        .onReceive(snapshotNotes) { n in
            if let q = n.userInfo?["search"] as? String { search = q }
            if n.userInfo?["browse"] != nil { browsing = true }
            if let l = n.userInfo?["stage"] as? String, let c = candidates.first(where: { $0.label == l }) { stage(c) }
            if let slot = n.userInfo?["wire"] as? String, let s = staged.first, let m = module, // debug: wire the first staged node to a port, as a drop would
               let v = SlotPicker.items(service, app: s.app, type: m.type, slot: slot).first(where: { $0.label == s.label })?.value { set(m.uuid, slot, v.any); staged.removeAll { $0 == s } }
        }
    }

    /// Top of the sidebar: the picked 1층 module's own name, and under it its 2층 판 (the modules that take turns on it).
    @ViewBuilder private var floor: some View {
        if !service.editingRoot, let module, let sh = service.shown.first(where: { $0.pose.u == module.uuid.components(separatedBy: "::")[0] }) {
            let kind = ServiceClient.kindName(sh.pose)
            if let h = service.host(of: sh) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(L("1층")).bold().foregroundStyle(.secondary)
                        Text(service.address(module.uuid).components(separatedBy: " ")[0] + " " + kind).foregroundStyle(.secondary)
                        NameField(saved: service.moduleName(h), placeholder: L("모듈 이름")) { service.setModuleName(h, $0) }.id("m:" + h + service.moduleName(h))
                            .padding(.vertical, 3).padding(.horizontal, 6).background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))
                        let targets = service.stackTargets(of: h)
                        if !targets.isEmpty {
                            Menu(L("스택에 넣기")) {
                                ForEach(targets, id: \.u) { t in Button(service.boardName(t)) { joining = StackJoin(host: t.u, u: h) } }
                            }.fixedSize().controlSize(.small).help(L("이 모듈(스택이면 전부)을 같은 종류 모듈의 2층에 넣습니다. 연결은 그대로 따라갑니다"))
                        }
                    }.padding(.horizontal, 14).padding(.top, 10)
                    StackFloor(host: h, kind: kind) { keepPick() }
                }
            } else if let path = sh.path { // connected but not in the profile yet: names and stacks belong to a profile's module
                HStack { Text(L("이 모듈은 아직 프로필에 없습니다.")).font(.caption).foregroundStyle(.secondary); Button(L("프로필에 적용")) { service.adopt(path) }.controlSize(.small) }.padding(10)
            }
            Divider()
        }
    }
    private var strip: some View {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Menu(service.editingRoot ? L("루트") : service.activeProfile?["title"].string ?? "") {
                ForEach(service.profiles, id: \.["id"].string) { p in Button(p["title"].string ?? "") { service.editingRoot = false; service.dispatch("ACTIVATE_PROFILE", ["profileId": p["id"].string ?? ""]) } }
                Divider()
                Toggle(L("루트 프로필 편집"), isOn: $service.editingRoot)
            }.fixedSize()
            Spacer()
            Button(L("되돌리기")) { service.dispatch("UNDO") }.keyboardShortcut("z", modifiers: .command)
            Button(L("닫기")) { if drag != nil { drag = nil; dragCancelled = true } else { module = nil } }.keyboardShortcut(.cancelAction) // esc while a wire is pulled drops the wire only
          }
          HStack(spacing: 8) {
            ForEach(modulesOnBoard, id: \.first!.uuid) { ms in
                let on = ms.contains { $0.uuid == module?.uuid }
                Button(service.address(ms[0].uuid).components(separatedBy: " ")[0] + " " + (service.moduleHost(ms[0].uuid).map(service.moduleName).flatMap { $0.isEmpty ? nil : $0 } ?? Self.typeName(ms[0].type, ms.count))) { module = ms[0]; whole = ms.count > 1; picked = nil }
                    .buttonStyle(.bordered).tint(on ? .accentColor : nil)
            }
            if let module, let ms = modulesOnBoard.first(where: { $0.contains(module) }), ms.count > 1 {
                Text("·").foregroundStyle(.secondary)
                ForEach(ms) { m in
                    Button(String(UnicodeScalar(0x2460 + (ServiceClient.controlNumber(m.uuid) ?? 1) - 1)!)) { self.module = m; whole = false; picked = nil }
                        .buttonStyle(.bordered).tint(!whole && m == module ? .orange : nil)
                }
                Button(L("전체")) { whole = true; picked = nil }.buttonStyle(.bordered).tint(whole ? .orange : nil)
            }
          }
        }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
    }
    static func typeName(_ t: String, _ n: Int) -> String {
        let base = ["button": L("버튼"), "dial": L("다이얼"), "slider": L("슬라이더"), "orbiter": "Orbiter"][t] ?? t
        return n > 1 ? "\(base) ×\(n)" : base
    }

    // MARK: left: control boxes

    private func box(_ m: Module) -> some View {
        let a = service.assignment(m.uuid), s = settings(m)
        let name = a["settings"]["name"].string ?? a["preset"].string ?? (s.isNull ? L("미할당") : "")
        let sel = picked == .control(m.uuid)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let c = a["settings"]["color"].string, c != "#000000" { Circle().fill(Color(hex: c)).frame(width: 9, height: 9) }
                Text(service.address(m.uuid)).font(.caption).foregroundStyle(.secondary)
                NameField(saved: a["settings"]["name"].string ?? "", placeholder: a["preset"].string ?? (s.isNull ? L("미할당") : L("이름"))) { v in update(m) { $0["name"] = v.isEmpty ? nil : v } }
                    .id(m.uuid + (a["settings"]["name"].string ?? ""))
                Spacer()
                if m.type == "dial", let st = service.runtimeState(m.uuid) { Text(L("감도 \(st.sensitivity)")).font(.caption2).foregroundStyle(.secondary) }
                Button(L("프리셋…")) { presetFor = m }.controlSize(.mini).help(L("이 컨트롤에 프리셋 통째로 할당"))
            }.contentShape(Rectangle()).onTapGesture { picked = .control(m.uuid) }
            ForEach(slots(m), id: \.self) { slot in port(m, slot) }
        }
        .padding(10)
        .background(LiveBox(uuid: m.uuid, sel: sel))
    }
    private func port(_ m: Module, _ slot: String) -> some View {
        let id = m.uuid + "::" + slot, w = wires(m).first { $0.slot == slot }
        let sel = picked == .wire(m.uuid, slot) || drag?.port == id
        return HStack {
            Text(SlotText.names[slot] ?? slot).font(.callout).foregroundStyle(w == nil ? Color.secondary : w!.inherited ? Color.purple : Color.primary)
            Spacer()
            Circle().fill(sel ? Color.orange : w == nil ? Color.secondary.opacity(0.3) : w!.inherited ? .purple : .blue).frame(width: 11, height: 11)
                .anchorPreference(key: AnchorKey.self, value: .center) { [id: $0] }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle()) // the whole row is the grab area, not just the 11pt dot
        .onHover { $0 ? NSCursor.crosshair.push() : NSCursor.pop() } // + cursor = you can pull a wire from here
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("wiring"))
            .onChanged { if !dragCancelled { drag = (id, $0.location) } }
            .onEnded { v in if !dragCancelled { drop(m, slot, at: v.location) }; dragCancelled = false; drag = nil })
        .onTapGesture { picked = w == nil ? .control(m.uuid) : .wire(m.uuid, slot) }
    }
    /// A wire dropped on a node rewires the port to that function; on "+ 새 기능" opens the picker; elsewhere it unplugs the port.
    private func drop(_ m: Module, _ slot: String, at p: CGPoint) {
        if let hit = hitNode(p) {
            if hit == "+" { newFor = (m.uuid, slot) }
            else if hit.hasPrefix("stage:"), let s = staged.first(where: { "stage:" + $0.label == hit }) {
                // the staged label resolved for this port's type and slot; a port that cannot take it just beeps
                if let v = SlotPicker.items(service, app: s.app, type: m.type, slot: slot).first(where: { $0.label == s.label })?.value {
                    set(m.uuid, slot, v.any); staged.removeAll { $0 == s }
                } else { NSSound.beep() }
            }
            else if let n = nodes.first(where: { $0.name == hit }) { set(m.uuid, slot, n.value.any) }
        } else if wires(m).contains(where: { $0.slot == slot }) { cut(m, slot) }
    }
    @State private var nodeFrames: [String: CGRect] = [:]
    private func hitNode(_ p: CGPoint) -> String? {
        let live = Set(["+"] + nodes.map(\.name) + staged.map { "stage:" + $0.label }) // a cut wire's node is gone but its frame stays recorded
        return nodeFrames.first { live.contains($0.key) && $0.value.contains(p) }?.key
    }

    // MARK: right: nodes

    private func node(_ n: (name: String, value: JSON, inherited: Bool)) -> some View {
        let sel = picked == .node(n.name), hot = drag != nil && hitNode(drag!.at) == n.name
        return HStack(spacing: 8) {
            Circle().fill(n.inherited ? Color.purple : .blue).frame(width: 11, height: 11)
                .anchorPreference(key: AnchorKey.self, value: .center) { ["node:" + n.name: $0] }
            Text(n.name).font(.callout).lineLimit(1).foregroundStyle(n.inherited ? Color.purple : Color.primary)
            Spacer()
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(hot ? AnyShapeStyle(Color.orange.opacity(0.25)) : AnyShapeStyle(.quaternary.opacity(0.4))))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(sel ? Color.orange : .clear))
        .background(GeometryReader { g in Color.clear.onAppear { nodeFrames[n.name] = g.frame(in: .named("wiring")) }.onChange(of: g.frame(in: .named("wiring"))) { _, f in nodeFrames[n.name] = f } })
        .contentShape(Rectangle()).onTapGesture { picked = .node(n.name) }
        .onHover { $0 ? NSCursor.crosshair.push() : NSCursor.pop() }
    }
    /// A function found but not wired yet. Dashed; a wire dropped on it connects that port and the node turns into a real one.
    private func stagedNode(_ s: Staged) -> some View {
        let sel = picked == .staged(s.label), hot = drag != nil && hitNode(drag!.at) == "stage:" + s.label
        return HStack(spacing: 8) {
            Circle().strokeBorder(Color.secondary).frame(width: 11, height: 11)
            Text(s.label).font(.callout).lineLimit(1).foregroundStyle(.secondary)
            if !s.app.isEmpty, s.app != appId { Text(service.appName(s.app)).font(.caption2).foregroundStyle(.tertiary) }
            Spacer()
            Button { staged.removeAll { $0 == s }; if sel { picked = nil } } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(hot ? AnyShapeStyle(Color.orange.opacity(0.25)) : AnyShapeStyle(.quaternary.opacity(0.2))))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(sel ? Color.orange : .secondary.opacity(0.6), style: StrokeStyle(dash: [4, 3])))
        .background(GeometryReader { g in Color.clear.onAppear { nodeFrames["stage:" + s.label] = g.frame(in: .named("wiring")) }.onChange(of: g.frame(in: .named("wiring"))) { _, f in nodeFrames["stage:" + s.label] = f } })
        .contentShape(Rectangle()).onTapGesture { picked = .staged(s.label) }
        .onHover { $0 ? NSCursor.crosshair.push() : NSCursor.pop() }
    }
    /// Functions any port in scope can take (app presets first, then 공통), minus the ones already staged.
    private var candidates: [Staged] {
        var out: [Staged] = [], seen = Set(staged.map(\.label)) // a set: scanning the list for each label was most of the time spent redrawing this screen
        for app in appId.isEmpty ? [""] : [appId, ""] {
            for m in controls { for slot in slots(m) { for i in SlotPicker.items(service, app: app, type: m.type, slot: slot) {
                if seen.insert(i.label).inserted { out.append(Staged(label: i.label, app: app)) }
            } } }
        }
        return out
    }
    private func stage(_ c: Staged) { staged.append(c); search = "" }

    // scope chips: the profile's page first, then the app anywhere, 공통, 전체 (proposal node-filter.html, B안)
    private var screenKey: String { service.editingRoot ? "" : service.activeProfile?["screen"].string ?? "" }
    private var hasPage: Bool { !screenKey.isEmpty && Engine.screens[appId]?.contains { $0.key == screenKey } == true }
    private var currentScope: Scope { scope ?? (hasPage ? .screen : appId.isEmpty ? .common : .app) }
    private func inScope(_ c: Staged, _ s: Scope) -> Bool {
        if c.label.hasPrefix(L("스택 ")) { return true } // 스택 바꾸기 belongs to the board, not to an app or page
        switch s {
        case .all: return true
        case .common: return c.app.isEmpty
        case .app: return !c.app.isEmpty && (!hasPage || (PresetText.screens(app: c.app, label: c.label) ?? []) == []) // with a page: only page-free 묶음
        case .screen: return !c.app.isEmpty && PresetText.screens(app: c.app, label: c.label)?.contains(screenKey) == true
        }
    }
    /// Functions other profiles of this app actually wired (labels only; the engine's own describe gives the same text as a node).
    private var usedElsewhere: [String] {
        guard !appId.isEmpty else { return [] }
        let me = service.activeProfile?["id"].string
        var out: [String] = []
        for p in service.profiles where p["app"].string == appId && p["id"].string != me {
            for (_, a) in p["assignments"].object { for (_, v) in a["settings"].object {
                let l = SlotText.describe(v, service: service, appId: appId, presetApp: a["app"].string ?? "")
                if !out.contains(l) { out.append(l) }
            } }
        }
        return out
    }

    /// "⌕ 기능 찾기": type to list functions, click/return stages one. Also the drop target of the old flow (wire → picker for that port).
    /// Focused with nothing typed it opens the browse panel: scope chips, ★ 추천, ↻ 다른 프로필에서 쓴 것, 묶음별 목록. esc closes.
    private var searchRow: some View {
        let hot = drag != nil && hitNode(drag!.at) == "+"
        let cands = browsing || !search.isEmpty ? candidates : [], sc = currentScope // only shown while searching; building it on every redraw made resizing stutter
        let scoped = cands.filter { inScope($0, sc) }
        var found = search.isEmpty ? [] : scoped.filter { $0.label.found(search) }
        let widened = !search.isEmpty && found.isEmpty && sc != .all
        if widened { found = cands.filter { $0.label.found(search) } }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.orange)
                TextField(L("기능 찾기 (⌘F) · 또는 포트에서 선을 끌어오세요"), text: $search).textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { if let f = found.first { stage(f) } }
                    .onExitCommand { search = ""; searchFocused = false; browsing = false }
                if browsing { Button { search = ""; searchFocused = false; browsing = false } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(hot ? 0.3 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange, style: StrokeStyle(dash: hot || searchFocused ? [] : [4, 3])))
            .background(GeometryReader { g in Color.clear.onAppear { nodeFrames["+"] = g.frame(in: .named("wiring")) }.onChange(of: g.frame(in: .named("wiring"))) { _, f in nodeFrames["+"] = f } })
            .popover(isPresented: Binding(get: { newFor != nil }, set: { if !$0 { newFor = nil } }), arrowEdge: .leading) {
                if let newFor, let m = control(newFor.uuid) {
                    SlotPicker(module: m, slot: newFor.slot, appId: appId, pick: { v in set(newFor.uuid, newFor.slot, v); self.newFor = nil }, also: { set(newFor.uuid, $0, $1) }).frame(width: 420, height: 400)
                }
            }
            if browsing || !search.isEmpty {
                if !appId.isEmpty { chips(cands) }
                if !search.isEmpty {
                    if found.isEmpty { Text(L("맞는 기능 없음 · 키 입력·페이지는 포트에서 선을 끌어 고르세요")).font(.caption).foregroundStyle(.secondary).padding(.leading, 8) }
                    else if widened { Text(L("이 범위엔 없어 전체에서 찾음")).font(.caption).foregroundStyle(.secondary).padding(.leading, 8) }
                    ForEach(found.prefix(12), id: \.label) { row($0) }
                    if found.count > 12 { Text(L("… \(found.count - 12)개 더 · 더 쳐서 좁히세요")).font(.caption).foregroundStyle(.secondary).padding(.leading, 8) }
                } else {
                    browse(scoped)
                }
            }
        }
        .onChange(of: searchFocused) { _, f in if f { browsing = true } }
        .onChange(of: screenKey) { scope = nil }
    }
    private func chips(_ cands: [Staged]) -> some View {
        let list: [(Scope, String)] = (hasPage ? [(.screen, Engine.screens[appId]?.first { $0.key == screenKey }?.names.last ?? screenKey)] : [])
            + [(.app, hasPage ? service.appName(appId) + L(" 어디서나") : service.appName(appId)), (.common, L("공통")), (.all, L("전체"))]
        return HStack(spacing: 4) {
            ForEach(list, id: \.1) { s, title in
                let on = currentScope == s, n = cands.filter { inScope($0, s) }.count
                Button { scope = s } label: { Text(s == .all ? title : "\(title) · \(n)").font(.caption) }
                    .buttonStyle(.bordered).tint(on ? .orange : nil).controlSize(.small)
            }
        }.padding(.leading, 4).padding(.top, 2)
    }
    private func row(_ c: Staged, mark: String? = nil) -> some View {
        Button { stage(c) } label: {
            HStack(spacing: 6) {
                if let mark { Text(mark).font(.caption).foregroundStyle(.orange).frame(width: 12) }
                Text(c.label).font(.callout).lineLimit(1)
                if c.app.isEmpty, !appId.isEmpty { Text(L("공통")).font(.caption2).foregroundStyle(.tertiary) }
                Spacer()
            }.padding(.vertical, 3).padding(.horizontal, 8).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    /// Empty-search panel: ★ 추천 (PresetText table for this page), ↻ wired in other profiles of the app, then every 묶음 of the scope, folded.
    private func browse(_ scoped: [Staged]) -> some View {
        let names = Set(nodes.map(\.name))
        let rec = PresetText.recommended(app: appId, screen: screenKey).compactMap { l in scoped.first { $0.label == l } }
        let used = usedElsewhere.filter { !names.contains($0) }.compactMap { l in scoped.first { $0.label == l } }.filter { u in !rec.contains(u) }
        var order: [String] = [], by: [String: [Staged]] = [:]
        for c in scoped { let s = c.label.hasPrefix(L("스택 ")) ? L("스택") : PresetText.section(c.label); if by[s] == nil { order.append(s) }; by[s, default: []].append(c) }
        return VStack(alignment: .leading, spacing: 2) {
            if !rec.isEmpty { Text(L("★ 추천")).font(.caption).foregroundStyle(.secondary).padding(.leading, 8).padding(.top, 4); ForEach(rec, id: \.label) { row($0, mark: "★") } }
            if !used.isEmpty { Text(L("↻ 다른 프로필에서 쓴 것")).font(.caption).foregroundStyle(.secondary).padding(.leading, 8).padding(.top, 4); ForEach(used.prefix(8), id: \.label) { row($0, mark: "↻") } }
            if scoped.isEmpty { Text(L("이 범위에 맞는 기능 없음")).font(.caption).foregroundStyle(.secondary).padding(.leading, 8).padding(.top, 4) }
            ForEach(order, id: \.self) { sec in
                let items = by[sec]!, open = sec.isEmpty || order.count == 1 || openSections.contains(sec)
                if !sec.isEmpty {
                    Button { if open { openSections.remove(sec) } else { openSections.insert(sec) } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                            Text(sec).font(.caption.weight(.semibold)); Text("\(items.count)").font(.caption2).foregroundStyle(.tertiary); Spacer()
                        }.padding(.vertical, 3).padding(.horizontal, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.top, 2)
                }
                if open { ForEach(items, id: \.label) { row($0) } }
            }
        }
    }

    // MARK: wires

    private func canvas(_ anchors: [String: Anchor<CGPoint>], _ g: GeometryProxy) -> some View {
        func pt(_ k: String) -> CGPoint? { anchors[k].map { g[$0] } }
        func curve(_ a: CGPoint, _ b: CGPoint) -> Path { var p = Path(); p.move(to: a); p.addCurve(to: b, control1: CGPoint(x: (a.x + b.x) / 2, y: a.y), control2: CGPoint(x: (a.x + b.x) / 2, y: b.y)); return p }
        let ws = allWires
        return Canvas { ctx, _ in
                for w in ws {
                    guard let a = pt(w.id), let b = pt("node:" + w.node) else { continue }
                    let sel = picked == .wire(w.uuid, w.slot)
                    let color: Color = sel ? .orange : w.inherited ? .purple : .blue
                    ctx.stroke(curve(a, b), with: .color(color), style: StrokeStyle(lineWidth: sel ? 3 : 2, dash: w.inherited ? [5, 4] : []))
                    if let badge = SlotText.badge(w.value) { // step at 40% of the wire
                        let x = a.x + (b.x - a.x) * 0.4, y = a.y + (b.y - a.y) * 0.4 - 1
                        let t = Text(badge).font(.system(size: 10, weight: .semibold)).foregroundStyle(sel ? Color.black : color)
                        let r = ctx.resolve(t), sz = r.measure(in: CGSize(width: 100, height: 20))
                        let rect = CGRect(x: x - sz.width / 2 - 5, y: y - sz.height / 2 - 1, width: sz.width + 10, height: sz.height + 2)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(sel ? .orange : Color(nsColor: .windowBackgroundColor)))
                        if !sel { ctx.stroke(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(color), lineWidth: 1) }
                        ctx.draw(r, at: CGPoint(x: x, y: y))
                    }
                }
                if let drag, let a = pt(drag.port) { ctx.stroke(curve(a, drag.at), with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [5, 4])) }
            }
        .allowsHitTesting(false)
        // clicking a wire picks it (hit-test the stroked curve); the columns underneath keep their own gestures
        .overlay { WireHit(wires: ws.map { w in (w, pt(w.id), pt("node:" + w.node)) }, curve: curve) { picked = .wire($0.uuid, $0.slot) } }
    }
    /// Transparent layer between the columns: only the wire strokes themselves catch the click.
    private struct WireHit: View {
        let wires: [(Wire, CGPoint?, CGPoint?)]
        let curve: (CGPoint, CGPoint) -> Path
        let pick: (Wire) -> Void
        var body: some View {
            Color.clear.contentShape(WireShape(paths: wires.compactMap { w, a, b in a.flatMap { a in b.map { curve(a, $0) } } }))
                .gesture(SpatialTapGesture(coordinateSpace: .named("wiring")).onEnded { v in
                    if let (w, _, _) = wires.first(where: { w, a, b in a != nil && b != nil && curve(a!, b!).strokedPath(StrokeStyle(lineWidth: 10)).contains(v.location) }) { pick(w) }
                })
        }
    }
    private struct WireShape: Shape {
        let paths: [Path]
        func path(in rect: CGRect) -> Path { var p = Path(); for x in paths { p.addPath(x.strokedPath(StrokeStyle(lineWidth: 10))) }; return p }
    }

    // MARK: dock

    @ViewBuilder private var dock: some View {
        switch picked {
        case .wire(let uuid, let slot):
            if let m = control(uuid) { VStack(alignment: .leading, spacing: 12) { connectionRow(m, slot); Divider(); AssignmentEditor(module: m, assignment: service.assignment(m.uuid)) { update(m, $0) } }.padding(.bottom, 12) }
        case .control(let uuid):
            if let m = control(uuid) { VStack(alignment: .leading, spacing: 12) { controlNote(m); Divider(); AssignmentEditor(module: m, assignment: service.assignment(m.uuid)) { update(m, $0) } }.padding(.bottom, 12) }
        case .node(let name):
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                ForEach(allWires.filter { $0.node == name }) { w in Text("\(service.address(w.uuid)) · \(SlotText.names[w.slot] ?? w.slot)\(w.inherited ? L(" (루트)") : "")").font(.callout) }
                Spacer()
            }.padding()
        case .staged(let label):
            VStack(alignment: .leading, spacing: 8) {
                Text(label).font(.headline)
                Text(L("대기 중 · 포트에서 선을 끌어 이 기능에 놓으면 연결됩니다. 선이 없으면 저장되지 않습니다.")).foregroundStyle(.secondary)
                Button(L("대기에서 빼기"), role: .destructive) { staged.removeAll { $0.label == label }; picked = nil }.controlSize(.small)
                Spacer()
            }.padding()
        case nil:
            Text(whole ? L("선이나 포트, 컨트롤 머리를 클릭하면 여기서 고칩니다. 빈 포트에서 선을 끌어 기능에 놓으면 연결됩니다.") : L("포트에서 선을 끌어 오른쪽 기능에 놓으세요.")).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    private func controlNote(_ m: Module) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(service.address(m.uuid) + " · " + Self.typeName(m.type, 1)).font(.headline)
            LastEvent(uuid: m.uuid).font(.callout)
            Button(L("할당 해제"), role: .destructive) { service.dispatch("CLEAR_MODULE", ["uuid": m.uuid]); picked = nil }.controlSize(.small).disabled(service.assignment(m.uuid).isNull)
            Spacer()
        }.padding()
    }
    /// The picked wire: its function, where the value comes from, and the value's own fields (step / invert for nudges).
    private func connectionRow(_ m: Module, _ slot: String) -> some View {
        let a = service.assignment(m.uuid), own = a["settings"][slot], w = wires(m).first { $0.slot == slot }
        let rootV = service.editingRoot ? JSON.null : service.rootSlot(m, slot)
        let orig = service.app(id: a["app"].string ?? "")?["presets"][m.type].array.first { $0["name"] == a["preset"] }?[slot] ?? .null
        let shipped = orig["ui"].isNull ? orig : .null
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(service.address(m.uuid)) · \(SlotText.names[slot] ?? slot) → \(w?.node ?? L("없음"))").font(.headline).lineLimit(1)
                Spacer()
                Text(w?.inherited == true ? L("루트 값") : rootV.isNull ? L("이 프로필 값") : L("이 프로필 값 · 루트에도 있음")).font(.caption).foregroundStyle(.secondary)
            }
            if let w, w.inherited {
                Button(L("이 프로필에서 바꾸기")) { set(m.uuid, slot, w.value.any) }.controlSize(.small).help(L("루트 값을 복사해 이 프로필의 값으로 만듭니다"))
            } else if let step = own["step"].double { // nudge: step and direction live in the value
                HStack {
                    Text(L("스텝")); NumField(value: Binding(get: { step }, set: { v in update(m) { var t = $0[slot] as? [String: Any] ?? [:]; t["step"] = v; $0[slot] = t } })).frame(width: 70)
                    Toggle(L("반전"), isOn: Binding(get: { own["invert"].bool ?? false }, set: { v in update(m) { var t = $0[slot] as? [String: Any] ?? [:]; t["invert"] = v; $0[slot] = t } }))
                    Toggle(L("가속"), isOn: Binding(get: { own["accel"].bool ?? false }, set: { v in update(m) { var t = $0[slot] as? [String: Any] ?? [:]; t["accel"] = v ? true : nil; $0[slot] = t } }))
                        .help(L("천천히 돌리면 한 틱에 한 걸음 그대로, 빠르게 돌리면 한 틱에 여러 걸음(최대 4배)"))
                }
            }
            if w?.inherited != true, !own.isNull, Self.oneShot.contains(slot) {
                let turn = wires(m).first { $0.slot == "turn" }?.value ?? .null
                let fn = service.app(id: [turn["app"].string, a["app"].string, appId].compactMap { $0 }.first { !$0.isEmpty } ?? "")?["inputs"][turn["input"].string ?? ""] ?? .null
                HStack {
                    Text(L("실행 후"))
                    if fn["range"].array.count == 2, fn["reset"].double != nil { Toggle(L("값을 기능의 기본값으로"), isOn: then(m, slot, own, "value", "default")) }
                    Toggle(L("LED 지정 색으로"), isOn: then(m, slot, own, "led", "assigned"))
                    Toggle(L("LED 깜빡임"), isOn: then(m, slot, own, "flash", true))
                }.toggleStyle(.checkbox).help(L("기능을 실행한 직후 이 컨트롤의 표시를 맞춥니다. 앱에는 더 보내지 않습니다."))
            }
            if w?.inherited != true, !own.isNull, Self.oneShot.contains(slot) { // 번갈아 실행: this wire's function is A, a second one B; each press runs the other
                let ab = own["alternate"].array
                HStack {
                    if ab.count == 2 {
                        Text(L("번갈아"))
                        Button(L("B 바꾸기…")) { pickingB = true }
                        ColorPicker(L("B 차례 LED"), selection: Binding(get: { Color(hex: own["color"].string ?? "#000000") }, set: { c in update(m) { var t = $0[slot] as? [String: Any] ?? [:]; t["color"] = c.hex; $0[slot] = t } }), supportsOpacity: false).fixedSize()
                            .help(L("B를 실행할 차례일 때의 LED 색. 정하지 않으면 지정 색을 어둡게 합니다."))
                        Button(L("해제")) { set(m.uuid, slot, ab[0].any) }.help(L("A만 남깁니다"))
                    } else {
                        Button(L("번갈아 실행…")) { pickingB = true }.help(L("누를 때마다 지금 기능(A)과 여기서 고르는 기능(B)을 번갈아 실행합니다. 앱에서 직접 바꾸면 차례가 어긋날 수 있습니다."))
                    }
                }.controlSize(.small)
                .popover(isPresented: $pickingB, arrowEdge: .top) {
                    SlotPicker(module: m, slot: slot, appId: appId) { b in
                        pickingB = false
                        guard let b else { return }
                        var a = ab.count == 2 ? ab[0].any : own.any, new: [String: Any] = [:]
                        if var d = a as? [String: Any] { new["then"] = d.removeValue(forKey: "then"); a = d } // 실행 후 belongs to the wire, not to A
                        if ab.count == 2 { new["then"] = own["then"].isNull ? nil : own["then"].any; new["color"] = own["color"].string }
                        new["alternate"] = [a, b]
                        set(m.uuid, slot, new)
                    }.frame(width: 420, height: 400)
                }
            }
            if w?.inherited != true { RangeFields(value: own, slot: slot, appId: a["app"].string ?? appId) { r in update(m) { var t = $0[slot] as? [String: Any] ?? [:]; t["range"] = r; $0[slot] = t } }.fixedSize() }
            HStack {
                Button(L("바꾸기…")) { changing = true }.controlSize(.small)
                    .popover(isPresented: $changing, arrowEdge: .top) { SlotPicker(module: m, slot: slot, appId: appId, pick: { v in set(m.uuid, slot, v); changing = false }, also: { set(m.uuid, $0, $1) }).frame(width: 420, height: 400) }
                if w?.inherited != true, !own.isNull { Button(L("끊기"), role: .destructive) { cut(m, slot) }.controlSize(.small) }
                if w?.inherited != true, !own.isNull, !rootV.isNull { Button(L("루트 값 쓰기")) { set(m.uuid, slot, nil) }.controlSize(.small).help(L("이 프로필의 값을 지우고 루트의 \(SlotText.describe(rootV, service: service, appId: "", presetApp: ""))을 씁니다")) }
                if !shipped.isNull, own != shipped { Button(L("원래대로")) { set(m.uuid, slot, shipped.any) }.controlSize(.small).help(L("프리셋이 들고 온 값으로")) }
            }
            LastEvent(uuid: m.uuid).font(.caption)
            Spacer()
        }.padding()
    }
}

/// Port and node centres in the "wiring" space, for the wire canvas.
struct AnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGPoint>] = [:]
    static func reduce(value: inout [String: Anchor<CGPoint>], nextValue: () -> [String: Anchor<CGPoint>]) { value.merge(nextValue()) { $1 } }
}

/// 컨트롤 이름: typed in place on the control box, saved on Enter or when focus leaves (not per keystroke: each save re-applies the profile).
struct NameField: View {
    let saved: String, placeholder: String
    let save: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField(placeholder, text: $text).textFieldStyle(.plain).font(.callout.bold()).lineLimit(1).focused($focused)
            .onAppear { text = saved }
            .onSubmit { commit(); focused = false }
            .onChange(of: focused) { if !focused { commit() } }
            .help(L("이름 · 눌러서 고치고 Enter로 저장"))
    }
    private func commit() { let v = text.trimmingCharacters(in: .whitespaces); if v != saved { save(v) } }
}

/// Control box ground and ring: green while the physical control is operated (wins over the orange "picked" ring, which comes back on release).
/// A leaf view so that only this redraws per hardware event, not the wiring screen.
private struct LiveBox: View {
    @EnvironmentObject private var live: Live
    let uuid: String, sel: Bool
    var body: some View {
        let on = live.active[uuid] != nil
        RoundedRectangle(cornerRadius: 10).fill(on ? AnyShapeStyle(Color.green.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.4)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Color.green : sel ? .orange : .clear, lineWidth: 2))
    }
}
/// What the control just did (last logged event), so turning it while the dock is open shows the step in effect.
private struct LastEvent: View {
    @EnvironmentObject private var live: Live
    let uuid: String
    var body: some View {
        let e = live.events.first { $0.uuid == uuid && $0.name != "pose" }
        Text(e.map { L("방금: \(SlotText.names[$0.name] ?? $0.name) \($0.value.formatted(.number.precision(.fractionLength(0...2)))) → \($0.action ?? "—")") } ?? L("실물을 조작하면 여기 표시됩니다")).foregroundStyle(.secondary)
    }
}
