import SwiftUI
import Engine

/// 패널 목록 편집: the right sidebar in place of the 연결 화면. The list is one control whose ports are its rows (top to bottom as
/// the panel shows them), each wired to one function. Found functions go straight to the end: a list has one kind of port, so nothing is staged.
struct PanelWiringView: View {
    @EnvironmentObject var service: ServiceClient
    let name: String
    @State private var picked: Int?
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var browsing = true // the function list under the search row; adding is what this screen is for, so it starts open
    @State private var scope = 0 // 0 = the profile's app, 1 = 공통, 2 = 전체
    @State private var openSections: Set<String> = []
    @State private var adding = false // SlotPicker popovers: 키 입력·실행·페이지 are only there
    @State private var changing = false
    @State private var drag: (row: Int?, label: String, at: CGPoint)? // a row being moved, or a found function on its way in
    @State private var rowFrames: [Int: CGRect] = [:]
    @State private var boxFrame = CGRect.zero
    @State private var nameBump = 0 // a refused rename puts the saved name back in the field

    struct Cand { let label: String, app: String, value: JSON }

    // MARK: data

    private var lists: [[String: Any]] { service.panelLists.compactMap { $0.any as? [String: Any] } }
    private var names: [String] { lists.compactMap { $0["name"] as? String } }
    private var items: [[String: Any]] { lists.first { $0["name"] as? String == name }?["items"] as? [[String: Any]] ?? [] }
    private func write(_ items: [[String: Any]]) {
        var all = lists
        guard let i = all.firstIndex(where: { $0["name"] as? String == name }) else { return }
        all[i]["items"] = items; service.setPanelLists(all)
    }
    private var appId: String { service.activeProfile?["app"].string ?? "" }
    private func label(_ d: [String: Any]) -> String { d["label"] as? String ?? "{…}" }
    /// The function's own name; `label` is what the panel shows and may be the person's wording. Items of older builds have the label only.
    private func fn(_ d: [String: Any]) -> String { d["fn"] as? String ?? label(d) }

    /// A panel or a 누르는 동안 inside a panel has no held control to close it; 번갈아 has no wire to keep its turn.
    static func allowed(_ j: JSON) -> Bool {
        let t = j["dispatch"]["type"].string ?? ""
        return j["panel"].isNull && j["alternate"].isNull && !t.hasPrefix("HOLD_") && t != "PROFILE_SWITCHER"
    }
    private func item(_ v: Any?) -> [String: Any]? {
        guard let v else { return nil }
        let j = JSON(any: v)
        guard Self.allowed(j) else { return nil }
        var d = v as? [String: Any] ?? (v as? String).map { ["input": $0] } ?? (v as? [Any]).flatMap { a in a.count == 2 ? ["input": a[0], "action": a[1]] : nil } ?? [:]
        guard !d.isEmpty else { return nil }
        d["label"] = SlotText.describe(j, service: service, appId: appId, presetApp: ""); d["fn"] = d["label"]
        if let input = d["input"] as? String, d["app"] == nil, let ins = service.app(id: appId)?["inputs"],
           !ins[input].isNull || ins.array.contains(where: { $0.string == input || $0["name"].string == input }) { d["app"] = appId } // an app function keeps its app, so the list also runs it from another profile
        return d
    }
    private func add(_ v: Any?, at k: Int? = nil) {
        guard let d = item(v) else { NSSound.beep(); return }
        var it = items; let k = min(k ?? it.count, it.count)
        it.insert(d, at: k); write(it); picked = k; search = ""
    }
    private func move(_ i: Int, to k: Int) {
        guard items.indices.contains(i), k != i, k != i + 1 else { return }
        var it = items; it.move(fromOffsets: [i], toOffset: k); write(it); picked = k > i ? k - 1 : k
    }
    private func cut(_ i: Int) {
        guard items.indices.contains(i) else { return }
        var it = items; it.remove(at: i); write(it); picked = it.isEmpty ? nil : min(i, it.count - 1)
    }
    /// One-shot functions a row can take (the app's first, then 공통): what a button's 누름 port takes, minus the ones a list cannot hold.
    private var candidates: [Cand] {
        var out: [Cand] = [], seen = Set<String>()
        for app in appId.isEmpty ? [""] : [appId, ""] {
            for i in SlotPicker.items(service, app: app, type: "button", slot: "press") where Self.allowed(i.value) && seen.insert(i.label).inserted {
                out.append(Cand(label: i.label, app: app, value: i.value))
            }
        }
        return out
    }
    /// Where a drop at `p` lands: the gap before row k (count = after the last). nil outside the list box.
    private func target(_ p: CGPoint) -> Int? {
        guard boxFrame.insetBy(dx: -12, dy: -30).contains(p) else { return nil }
        return items.indices.filter { (rowFrames[$0]?.midY ?? .infinity) < p.y }.count
    }

    // MARK: body

    var body: some View {
        VStack(spacing: 0) {
            strip
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView { box.padding(12) }.frame(minWidth: 200, maxWidth: 270)
                Color.clear.frame(minWidth: 40, maxWidth: 110)
                ScrollView { VStack(alignment: .leading, spacing: 6) {
                    Text(L("연결된 기능 · \(items.count)")).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(items.enumerated()), id: \.offset) { i, d in node(i, d) }
                    finder
                }.padding(12) }.frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: "pwiring")
            .overlayPreferenceValue(AnchorKey.self) { anchors in GeometryReader { g in canvas(anchors, g) } }
            Divider()
            dock.frame(height: 200)
        }
        .background(.background)
        .background { Button("") { searchFocused = true; browsing = true }.keyboardShortcut("f", modifiers: .command).opacity(0) }
        .onDeleteCommand { if let i = picked { cut(i) } }
        .onChange(of: names) { _, n in if !n.contains(name) { service.editingPanel = nil } } // deleted, or a rename undone
    }

    private var strip: some View {
        HStack(spacing: 8) {
            Text(L("패널 목록")).bold().foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { ForEach(names, id: \.self) { n in Button(n) { service.editingPanel = n }.buttonStyle(.bordered).tint(n == name ? .orange : nil) } }
            }
            Spacer()
            Button(L("되돌리기")) { service.dispatch("UNDO") }.keyboardShortcut("z", modifiers: .command)
            Button(L("닫기")) { service.editingPanel = nil }.keyboardShortcut(.cancelAction)
        }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: left: the list as one box, a port per row

    private var box: some View {
        VStack(alignment: .leading, spacing: 4) {
            NameField(saved: name, placeholder: L("목록 이름")) { v in
                if v.isEmpty || names.contains(v) { NSSound.beep(); nameBump += 1; return }
                service.renamePanelList(name, v); service.editingPanel = v
            }.id(nameBump)
            Text(items.isEmpty ? L("항목이 없으면 패널이 뜨지 않습니다") : L("칸 \(items.count)개 · 위에서부터 뜹니다")).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { i, d in row(i, d) }
            HStack {
                Text(L("＋ 새 칸")).font(.callout).foregroundStyle(.tertiary)
                Spacer()
                Circle().strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(dash: [3, 2])).frame(width: 11, height: 11)
            }.padding(.vertical, 2)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
        .background(GeometryReader { g in Color.clear.onAppear { boxFrame = g.frame(in: .named("pwiring")) }.onChange(of: g.frame(in: .named("pwiring"))) { _, f in boxFrame = f } })
    }
    private func row(_ i: Int, _ d: [String: Any]) -> some View {
        let sel = picked == i
        return HStack(spacing: 6) {
            Text("\(i + 1)").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 16, alignment: .leading)
            Text(label(d)).font(.callout).lineLimit(1)
            Spacer()
            Circle().fill(sel ? Color.orange : .blue).frame(width: 11, height: 11)
                .anchorPreference(key: AnchorKey.self, value: .center) { ["row:\(i)": $0] }
        }
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(sel ? 0.12 : 0)).padding(.horizontal, -4))
        .background(GeometryReader { g in Color.clear.onAppear { rowFrames[i] = g.frame(in: .named("pwiring")) }.onChange(of: g.frame(in: .named("pwiring"))) { _, f in rowFrames[i] = f } })
        .opacity(drag?.row == i ? 0.4 : 1)
        .contentShape(Rectangle())
        .onHover { $0 ? NSCursor.openHand.push() : NSCursor.pop() } // a row is dragged up or down to reorder
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("pwiring"))
            .onChanged { drag = (i, label(d), $0.location) }
            .onEnded { v in if let k = target(v.location) { move(i, to: k) }; drag = nil })
        .onTapGesture { picked = i }
    }

    // MARK: right: functions and the finder

    private func node(_ i: Int, _ d: [String: Any]) -> some View {
        let sel = picked == i, app = d["app"] as? String ?? ""
        return HStack(spacing: 8) {
            Circle().fill(sel ? Color.orange : .blue).frame(width: 11, height: 11)
                .anchorPreference(key: AnchorKey.self, value: .center) { ["node:\(i)": $0] }
            Text(fn(d)).font(.callout).lineLimit(1)
            if !app.isEmpty { Text(service.appName(app)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            Spacer()
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(sel ? Color.orange : .clear))
        .contentShape(Rectangle()).onTapGesture { picked = i }
    }
    /// "⌕ 기능 찾기": Enter or a click puts the function in the last row, dragging it onto the list puts it where it is dropped. The field keeps the focus for the next one.
    private var finder: some View {
        let cands = browsing || !search.isEmpty ? candidates : []
        let scoped = appId.isEmpty || scope == 2 ? cands : cands.filter { $0.app.isEmpty == (scope == 1) }
        var found = search.isEmpty ? [] : scoped.filter { $0.label.found(search) }
        let widened = !search.isEmpty && found.isEmpty && scoped.count != cands.count
        if widened { found = cands.filter { $0.label.found(search) } }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.orange)
                TextField(L("기능 찾기 (⌘F)"), text: $search).textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { if let f = found.first { add(f.value.any); searchFocused = true } }
                    .onExitCommand { if search.isEmpty { browsing = false; searchFocused = false } else { search = "" } }
                if browsing { Button { search = ""; searchFocused = false; browsing = false } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange, style: StrokeStyle(dash: searchFocused ? [] : [4, 3])))
            if browsing || !search.isEmpty {
                if !appId.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array([service.appName(appId), L("공통"), L("전체")].enumerated()), id: \.offset) { s, title in
                            Button { scope = s } label: { Text(title).font(.caption) }.buttonStyle(.bordered).tint(scope == s ? .orange : nil).controlSize(.small)
                        }
                    }.padding(.leading, 4).padding(.top, 2)
                }
                if !search.isEmpty {
                    if found.isEmpty { Text(L("맞는 기능 없음 · 키 입력·실행·페이지는 아래 '다른 기능…'에서 고르세요")).font(.caption).foregroundStyle(.secondary).padding(.leading, 8) }
                    else if widened { Text(L("이 범위엔 없어 전체에서 찾음")).font(.caption).foregroundStyle(.secondary).padding(.leading, 8) }
                    ForEach(found.prefix(12), id: \.label) { candRow($0) }
                    if found.count > 12 { Text(L("… \(found.count - 12)개 더 · 더 쳐서 좁히세요")).font(.caption).foregroundStyle(.secondary).padding(.leading, 8) }
                } else {
                    browse(scoped)
                }
            }
            Button(L("다른 기능… (키 입력·실행·페이지)")) { adding = true }.controlSize(.small).padding(.top, 4)
                .popover(isPresented: $adding, arrowEdge: .leading) { picker { v in add(v); adding = false } }
        }
        .padding(.top, 6)
        .onChange(of: searchFocused) { _, f in if f { browsing = true } }
        .onChange(of: appId) { scope = 0; openSections = [] }
    }
    private func picker(_ pick: @escaping (Any?) -> Void) -> some View {
        SlotPicker(module: Module(uuid: "", type: "button", depth: 0, port: nil, localId: nil), slot: "press", appId: appId, pick: pick).frame(width: 420, height: 400)
    }
    private func candRow(_ c: Cand) -> some View {
        HStack(spacing: 6) {
            Text(c.label).font(.callout).lineLimit(1)
            if c.app.isEmpty, !appId.isEmpty { Text(L("공통")).font(.caption2).foregroundStyle(.tertiary) }
            Spacer()
            Image(systemName: "plus").font(.caption2).foregroundStyle(.orange)
        }
        .padding(.vertical, 3).padding(.horizontal, 8).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("pwiring"))
            .onChanged { drag = (nil, c.label, $0.location) }
            .onEnded { v in if let k = target(v.location) { add(c.value.any, at: k) }; drag = nil })
        .onTapGesture { add(c.value.any) }
    }
    /// Nothing typed: every 묶음 of the scope, folded (a scope with one 묶음, or functions without one, lie open).
    private func browse(_ scoped: [Cand]) -> some View {
        var order: [String] = [], by: [String: [Cand]] = [:]
        for c in scoped { let s = PresetText.section(c.label); if by[s] == nil { order.append(s) }; by[s, default: []].append(c) }
        return VStack(alignment: .leading, spacing: 2) {
            if scoped.isEmpty { Text(L("이 범위에 맞는 기능 없음")).font(.caption).foregroundStyle(.secondary).padding(.leading, 8).padding(.top, 4) }
            ForEach(order, id: \.self) { sec in
                let list = by[sec]!, open = sec.isEmpty || order.count == 1 || openSections.contains(sec)
                if !sec.isEmpty {
                    Button { if open { openSections.remove(sec) } else { openSections.insert(sec) } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                            Text(sec).font(.caption.weight(.semibold)); Text("\(list.count)").font(.caption2).foregroundStyle(.tertiary); Spacer()
                        }.padding(.vertical, 3).padding(.horizontal, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.top, 2)
                }
                if open { ForEach(list, id: \.label) { candRow($0) } }
            }
        }
    }

    // MARK: wires

    private func canvas(_ anchors: [String: Anchor<CGPoint>], _ g: GeometryProxy) -> some View {
        func pt(_ k: String) -> CGPoint? { anchors[k].map { g[$0] } }
        let n = items.count, sel = picked, drag = drag, frames = rowFrames, box = boxFrame
        let gap = drag.flatMap { target($0.at) }
        return Canvas { ctx, _ in
            for i in 0..<n {
                guard let a = pt("row:\(i)"), let b = pt("node:\(i)") else { continue }
                var p = Path(); p.move(to: a); p.addCurve(to: b, control1: CGPoint(x: (a.x + b.x) / 2, y: a.y), control2: CGPoint(x: (a.x + b.x) / 2, y: b.y))
                ctx.stroke(p, with: .color(sel == i ? .orange : .blue), lineWidth: sel == i ? 3 : 2)
            }
            guard let drag else { return }
            if let gap, let y = gap < n ? frames[gap]?.minY : frames[n - 1]?.maxY ?? box.minY + 44 { // where it lands: a line in that gap
                var l = Path(); l.move(to: CGPoint(x: box.minX + 6, y: y)); l.addLine(to: CGPoint(x: box.maxX - 6, y: y))
                ctx.stroke(l, with: .color(.orange), lineWidth: 2)
            }
            ctx.draw(Text(drag.label).font(.callout).foregroundStyle(Color.orange), at: CGPoint(x: drag.at.x + 12, y: drag.at.y - 12), anchor: .leading)
        }.allowsHitTesting(false)
    }

    // MARK: dock

    private var dock: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if let i = picked, items.indices.contains(i) {
                    let d = items[i], f = fn(d), l = label(d)
                    Text(L("\(i + 1)번 칸 · \(f)")).font(.headline).lineLimit(1)
                    HStack {
                        Text(L("보이는 이름"))
                        NameField(saved: l == f ? "" : l, placeholder: f) { v in var it = items; it[i]["fn"] = f; it[i]["label"] = v.isEmpty ? f : v; write(it) }
                            .id("\(i)" + l).padding(.vertical, 3).padding(.horizontal, 6).background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.5)))
                    }
                    HStack {
                        Button(L("위로")) { move(i, to: i - 1) }.disabled(i == 0)
                        Button(L("아래로")) { move(i, to: i + 2) }.disabled(i == items.count - 1)
                        Button(L("바꾸기…")) { changing = true }
                            .popover(isPresented: $changing, arrowEdge: .top) { picker { v in
                                changing = false
                                guard var n = item(v) else { NSSound.beep(); return }
                                if l != f { n["label"] = l } // the person's wording stays with the row
                                var it = items; it[i] = n; write(it)
                            } }
                        Button(L("끊기"), role: .destructive) { cut(i) }
                    }.controlSize(.small)
                } else {
                    Text(L("칸을 누르면 여기서 이름과 순서를 고칩니다. 칸은 위아래로 끌어 옮기고, 찾은 기능은 눌러서 맨 아래에 넣거나 원하는 자리로 끌어다 놓습니다.")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(L("여는 법: 버튼의 '길게'나 다이얼의 '누를 때'에 공통 기능 '\(SlotText.describe(JSON(any: ["panel": "list:" + name]), service: service, appId: "", presetApp: ""))'을 잇습니다. 판에서 주황 테두리가 이 목록을 여는 컨트롤입니다. 앱 기능 항목은 그 앱의 프로필이 켜져 있을 때 실행됩니다."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
            ScrollView { // the order the 화면 패널 shows; short lists come up there as a row of tiles in the same order
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.caption2).foregroundStyle(.white.opacity(0.6)).padding(.leading, 8)
                    ForEach(Array(items.enumerated()), id: \.offset) { i, d in
                        Text(label(d)).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3).padding(.horizontal, 8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(i == (picked ?? 0) ? 0.16 : 0)))
                            .foregroundStyle(i == (picked ?? 0) ? .white : .white.opacity(0.6))
                    }
                    if items.isEmpty { Text(L("비어 있음")).font(.caption).foregroundStyle(.white.opacity(0.6)).padding(.leading, 8) }
                }.padding(8)
            }
            .frame(width: 170).background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.8)))
        }.padding(12)
    }
}
