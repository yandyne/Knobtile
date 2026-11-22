import SwiftUI
import Engine

/// The design board: a fixed grid of cells viewed through pan/zoom/rotation. Modules are `Pose`s; connections follow from geometry (`Board`).
/// Moving uses one DragGesture per module box in the board's own coordinate space, so nothing is converted and nothing on screen shifts.
struct LayoutView: View {
    @EnvironmentObject var service: ServiceClient
    @Binding var selected: Module?
    @State private var hoverBox: Int?
    @State private var hoverCard: String?
    @State private var centred = false // true once the user has panned or zoomed: stop re-centring the default 100 % view
    // mouse over a module frame but not over one of its cards: the frame lights up like a card does
    var whole = false // the sidebar shows the whole module: mark the frame, not a card
    var onOpen: (Module, Bool) -> Void = { _, _ in } // tap: open the 연결 화면 for a control (false) or its whole module (true)
    @State private var pan = CGSize.zero
    @State private var zoom: CGFloat = realZoom
    @State private var fitting = false // keeps the whole layout in view until the user pans or zooms
    @GestureState private var drag = CGSize.zero
    @FocusState private var canvasFocused: Bool
    @State private var ghost: Pose? = nil   // the module being moved or placed, at its current cell and turn
    @State private var moving: Int? = nil   // shown index of the module being moved; nil while placing from the palette
    @State private var turn = 0             // R presses during a move
    @State private var delta = (x: 0, y: 0) // cells dragged so far
    @State private var keyMonitor: Any?
    @State private var hover = CGPoint(x: boardSize / 2, y: boardSize / 2) // board-space mouse, for placing
    @State private var joining: StackJoin? // dropped onto a same-type module: asks before stacking
    private var boardRotation: Int { ProcessInfo.processInfo.environment["MC_BOARD_ROTATION"].flatMap { Int($0) } ?? service.preferences["boardRotation"].int ?? 0 } // env: debug, view only // 전체 돌리기: how the assembly lies on the desk (quarter turns); the engine reads the same value
    @AppStorage("theme") private var theme = 1
    var osd = false // 맵 보기: the same board in the screen panel, read only: no tools, always fitted, drawn in the labelled dark look
    var pinned = false // 상시 맵: the osd board small in a screen corner, so short labels in a size that stays readable
    private var look: Int { osd ? 2 : theme }
    /// 맵 보기 writes what a control does, not just the name the person gave it: the name, else its main wire's function.
    /// 패널 목록 편집 중: this control opens that list (own wire or the root's).
    private func opensEditedPanel(_ m: Module) -> Bool {
        guard !osd, let n = service.editingPanel else { return false }
        return service.effective(m).object.values.contains { $0["panel"].string == "list:" + n }
    }
    private func osdLabel(_ m: Module) -> String? { !osd ? nil : pinned ? mapLabel(m).components(separatedBy: " · ").first : mapLabel(m) } // 상시 맵: only what the turn or press does, the rest does not fit
    private var osdFont: CGFloat? { pinned ? 10 / zoom : nil } // 10 pt on screen whatever the board is scaled to
    /// 상시 맵: yellow outline on the stack whose layer just changed.
    @ViewBuilder private func flash(_ s: ServiceClient.Shown) -> some View {
        if pinned, let h = service.host(of: s), service.mapFlash.contains(h) { RoundedRectangle(cornerRadius: 14).stroke(Color.yellow, lineWidth: 3 / zoom) }
    }
    private func mapLabel(_ m: Module) -> String {
        let a = service.assignment(m.uuid)
        if let n = a["settings"]["name"].string, !n.isEmpty { return n }
        let eff = service.effective(m), st = eff.isNull ? a["settings"] : eff
        guard let slot = ["turn", "pose", "press", "pressAndHold", "pressDown", "tiltX"].first(where: { !st[$0].isNull }) else { return a["preset"].string ?? "" }
        return SlotText.describe(st[slot], service: service, appId: service.activeProfile?["app"].string ?? "", presetApp: a["app"].string ?? "")
    }
    private func applyAppearance() { NSApp.appearance = look == 1 || look == 4 ? NSAppearance(named: .aqua) : look == 2 ? NSAppearance(named: .darkAqua) : nil } // 1 original-app outline, 2 dark + labels, 3 developer cards, 4 minimal + numbers
    typealias Side = Board.Side

    /// 100 % = real size: the Core's long side is 9 cm, i.e. one unit = 4.5 cm. Points per cm come from the main display's physical size.
    static var realZoom: CGFloat {
        let id = CGMainDisplayID(), mm = CGDisplayScreenSize(id).width
        let pts = NSScreen.main?.frame.width ?? CGFloat(CGDisplayPixelsWide(id))
        return mm > 0 ? (pts / (mm / 10)) * 4.5 / unit : 1
    }
    static let unit: CGFloat = 166, gap: CGFloat = 28   // 1 unit = one module cell; the gap holds the names next to each joint
    static var pitch: CGFloat { unit + gap }
    static let span = 40, half = 20                      // fixed 40x40 cells, cell (0,0) in the middle: placing modules never resizes or shifts the canvas
    static var boardSize: CGFloat { CGFloat(span) * pitch }
    static func point(_ c: Board.Cell) -> CGPoint { CGPoint(x: CGFloat(c.x + half) * pitch, y: CGFloat(c.y + half) * pitch) }

    var body: some View {
        let shown = service.shown, geoBoard = Board(modules: shown.map(\.pose))
        let hot = Set(ghost.map { geoBoard.candidates(for: $0, moving: moving).map { "\($0.parent)/\($0.port)" } } ?? [])
        GeometryReader { geo in
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: Self.boardSize, height: Self.boardSize).contentShape(Rectangle())
                    .onTapGesture { if moving == nil, ghost != nil { commit(shown, geoBoard) } } // placing from the palette: click to put it down
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, s in
                    moduleBox(s, i, hot: hot, shown: shown, geoBoard: geoBoard)
                        .opacity(moving == i ? 0.25 : 1) // stays in the tree while moved: removing it would cancel its own drag gesture
                        .offset(x: Self.point(.init(s.pose.x, s.pose.y)).x, y: Self.point(.init(s.pose.x, s.pose.y)).y)
                }
                if let g = ghost {
                    let sn = geoBoard.snap(g, moving: moving)
                    let ok = fits(g, shown, geoBoard), joins = !ok && stackTarget(g, shown) != nil
                    ghostBox(g, ok: ok, plugged: sn.port != nil || sn.ownPort != nil, litPort: sn.ownPort)
                        .overlay { if joins { // over a same-type module: dropping asks to stack instead of bouncing back
                            RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.35)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange, lineWidth: 3))
                                .overlay(Label(L("놓으면 스택에 넣기"), systemImage: "square.stack.3d.up.fill").font(.headline).foregroundStyle(.black).rotationEffect(.degrees(Double(-boardRotation) * 90)))
                        } }
                        .offset(x: Self.point(.init(g.x, g.y)).x, y: Self.point(.init(g.x, g.y)).y).allowsHitTesting(false)
                }
            }
            .frame(width: Self.boardSize, height: Self.boardSize, alignment: .topLeading)
            .coordinateSpace(name: "board")
            .onContinuousHover(coordinateSpace: .local) { ph in
                if case .active(let p) = ph { hover = p; if moving == nil, let g = ghost { ghost = placed(g, under: p, geoBoard) } }
            }
            .rotationEffect(.degrees(Double(boardRotation) * 90))
            .scaleEffect(zoom, anchor: .topLeading)
            .offset(x: pan.width + drag.width, y: pan.height + drag.height)
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .overlay(alignment: .topLeading) {
            let (n, m) = service.matchCount
            if m > 0, !osd {
                Text(L("모듈 \(n)/\(m) 일치")).font(.caption).monospacedDigit().foregroundStyle(n == m ? .secondary : Color.orange)
                    .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
                    .help(L("프로필이 기억하는 모듈 중 같은 종류가 같은 자리에 연결된 수"))
            }
        }
        .overlay(alignment: .topTrailing) { if !osd {
            HStack(spacing: 4) {
                Button { service.dispatch("UNDO") } label: { Image(systemName: "arrow.uturn.backward") }.keyboardShortcut("z", modifiers: .command).help(L("되돌리기 (⌘Z): 모듈 추가·이동·회전·삭제, 스택, 이름, 연결"))
                Picker("", selection: $theme) { Text(L("테마 1")).tag(1); Text(L("테마 2")).tag(2); Text(L("미니멀")).tag(4); Text(L("개발자")).tag(3) }.pickerStyle(.segmented).fixedSize()
                Toggle(L("맞춤"), isOn: $fitting).toggleStyle(.button).onChange(of: fitting) { if fitting { fit(shown, in: geo.size) } }
                Button("−") { setZoom(zoom / 1.25, in: geo.size) }
                Button("+") { setZoom(zoom * 1.25, in: geo.size) }
                Button("100%") { setZoom(Self.realZoom, in: geo.size) }
                Button { service.dispatch("UPDATE_PREFERENCE", ["update": ["type": "boardRotation", "value": (boardRotation + 3) % 4]]) } label: { Image(systemName: "rotate.left") }.help(L("전체 돌리기: 반시계 방향 90°"))
                Button { service.dispatch("UPDATE_PREFERENCE", ["update": ["type": "boardRotation", "value": (boardRotation + 1) % 4]]) } label: { Label("\(boardRotation * 90)°", systemImage: "rotate.right").labelStyle(.titleAndIcon) }.help(L("전체 돌리기: 책상에 놓인 방향에 맞춰 90°씩. 번호·방향과 Core 화면이 함께 따라갑니다 (모든 프로필 공통)"))
                        .onChange(of: boardRotation) { centre(on: bounds(shown).centre, in: geo.size) }
                Text("\(Int(zoom / Self.realZoom * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 44)
            }
            .controlSize(.small).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
        } }
        .focusable().focused($canvasFocused).focusEffectDisabled()
        .onAppear { // R / Esc while a module is held: a local monitor sees them whatever has keyboard focus
            if osd { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard ghost != nil else { return e }
                if e.keyCode == 15 { turnGhost(service.shown, Board(modules: service.shown.map(\.pose)), by: e.modifierFlags.contains(.shift) ? 3 : 1); return nil } // R clockwise, ⇧R counter (+3 ≡ −1)
                if e.keyCode == 53 { ghost = nil; moving = nil; turn = 0; return nil }
                return e
            }
        }
        .onDisappear { if let m = keyMonitor { NSEvent.removeMonitor(m) } }
        .onDeleteCommand {
            guard let m = selected, let s = shown.first(where: { $0.pose.u == base(m) }), let bi = s.boardIndex, bi != 0, bi < service.board.modules.count else { return }
            ghost = nil; moving = nil
            var b = service.board; b.modules.remove(at: bi); service.setBoard(b); selected = nil
        }
        .gesture(DragGesture(minimumDistance: 4).updating($drag) { v, st, _ in st = v.translation }
            .onEnded { pan.width += $0.translation.width; pan.height += $0.translation.height; fitting = false; centred = true })
        .gesture(MagnifyGesture().onEnded { setZoom(zoom * $0.magnification, in: geo.size) })
        // preferredColorScheme(nil) never restores the system scheme once forced, so drive NSApp.appearance (nil = follow system)
        .onAppear { if !osd { applyAppearance() } }.onChange(of: theme) { applyAppearance() }
        .onChange(of: shown.map(\.pose), initial: true) { settle(shown, geo.size) }
        .onChange(of: geo.size, initial: true) { settle(shown, geo.size) }
        .confirmStackJoin($joining, service) { j in selected = service.modules().first { $0.uuid.components(separatedBy: "::")[0] == j.u } ?? selected }
        .overlay(alignment: .bottomLeading) { if !osd { palette.padding(.bottom, look == 3 ? 180 : 0) } }
        .overlay(alignment: .bottom) { if look == 3 { EventLog(selected: selected?.uuid) } }
        .overlay(alignment: .topTrailing) { if look == 3 { birdView(shown, in: geo.size).padding(.top, 40).padding(.trailing, 8) } }
        }
    }

    /// 버드뷰: the whole board from above with each module's address and the window currently shown (developer theme).
    private func birdView(_ shown: [ServiceClient.Shown], in size: CGSize) -> some View {
        func turned(_ p: Pose) -> (x: Int, y: Int, w: Int, h: Int) { (0..<boardRotation).reduce((p.x, p.y, p.w, p.h)) { r, _ in (-(r.1 + r.3), r.0, r.3, r.2) } } // as the board lies: quarter turns about the board centre
        let ps = shown.map { turned($0.pose) }
        let x0 = (ps.map(\.x).min() ?? 0) - 1, y0 = (ps.map(\.y).min() ?? 0) - 1
        let x1 = (ps.map { $0.x + $0.w }.max() ?? 1) + 1, y1 = (ps.map { $0.y + $0.h }.max() ?? 1) + 1
        let k = min(180 / CGFloat(x1 - x0), 130 / CGFloat(y1 - y0)) // px per cell
        func px(_ c: CGFloat, _ o: Int) -> CGFloat { (c - CGFloat(o)) * k }
        return ZStack(alignment: .topLeading) {
            ForEach(shown) { s in
                let p = turned(s.pose), dim = s.link == .missing || s.link == .loose
                RoundedRectangle(cornerRadius: 2).fill(s.pose.isCore ? Color.secondary.opacity(0.7) : Color.yellow.opacity(dim ? 0.25 : 0.65))
                    .overlay(Text(service.address(s.pose.u)).font(.system(size: 7, weight: .semibold, design: .monospaced)).foregroundStyle(.black).lineLimit(1))
                    .frame(width: CGFloat(p.w) * k - 2, height: CGFloat(p.h) * k - 2)
                    .offset(x: px(CGFloat(p.x), x0) + 1, y: px(CGFloat(p.y), y0) + 1)
            }
            // the visible area: its centre in cells, turned like the modules; the screen's axes are the turned board's axes
            let bp = boardPoint(CGPoint(x: size.width / 2 - drag.width, y: size.height / 2 - drag.height))
            let vc = (0..<boardRotation).reduce((x: bp.x / Self.pitch - CGFloat(Self.half), y: bp.y / Self.pitch - CGFloat(Self.half))) { c, _ in (-c.y, c.x) }
            let vw = size.width / zoom / Self.pitch, vh = size.height / zoom / Self.pitch
            Rectangle().stroke(.blue, lineWidth: 1)
                .frame(width: vw * k, height: vh * k)
                .offset(x: px(vc.x - vw / 2, x0), y: px(vc.y - vh / 2, y0))
        }
        .frame(width: CGFloat(x1 - x0) * k, height: CGFloat(y1 - y0) * k, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in // click or drag: the main view centres on that spot
            var c = (x: v.location.x / k + CGFloat(x0), y: v.location.y / k + CGFloat(y0)) // cells as drawn (turned)
            for _ in 0..<boardRotation { c = (c.y, -c.x) } // undo the quarter turns of turned()
            fitting = false; centred = true
            centre(on: CGPoint(x: (c.x + CGFloat(Self.half)) * Self.pitch, y: (c.y + CGFloat(Self.half)) * Self.pitch), in: size)
        })
        .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .help(L("버드뷰: 판 전체와 지금 보이는 범위 · 누르거나 끌면 그곳으로 이동"))
    }

    // MARK: moving and placing

    /// Box centred under the cursor, snapped to a port when one is within a cell.
    private func fits(_ g: Pose, _ shown: [ServiceClient.Shown], _ board: Board) -> Bool { Self.fits(g, moving: moving, shown, board) }
    /// Placeable with the connected-but-unapplied (임시) modules the ghost covers exactly left out: a profile module may be put over
    /// one of the same shape (other pins or type show red, 방향 다름/다른 모듈); a different shape (e.g. a quarter turn) must not overlap it.
    static func fits(_ g: Pose, moving: Int?, _ shown: [ServiceClient.Shown], _ board: Board) -> Bool {
        if board.placeable(g, moving: moving) { return true }
        let temps = shown.indices.filter { $0 < board.modules.count && $0 != moving && shown[$0].link == .temp }
        let covered = temps.filter { let p = board.modules[$0]; return p.x == g.x && p.y == g.y && p.w == g.w && p.h == g.h }
        guard covered.count == temps.filter({ Board(modules: [board.modules[$0]]).overlaps(g) }).count else { return false }
        var b = board; for t in covered.reversed() { b.modules.remove(at: t) }
        return !covered.isEmpty && b.placeable(g, moving: moving.map { m in m - covered.filter { $0 < m }.count })
    }
    private func placed(_ g: Pose, under p: CGPoint, _ board: Board) -> Pose {
        var g = g
        g.x = Int(floor(p.x / Self.pitch - CGFloat(g.w) / 2 + 0.5)) - Self.half
        g.y = Int(floor(p.y / Self.pitch - CGFloat(g.h) / 2 + 0.5)) - Self.half
        return board.snap(g, moving: moving).pose
    }
    private func moved(_ shown: [ServiceClient.Shown], _ board: Board) -> Pose? {
        guard let m = moving, m < shown.count else { return nil }
        var g = shown[m].pose
        g.r = (g.r + turn) % 4; g.x += delta.x; g.y += delta.y
        return board.snap(g, moving: m).pose
    }
    private func turnGhost(_ shown: [ServiceClient.Shown], _ board: Board, by step: Int = 1) {
        guard let g = ghost, !g.isCore else { return } // the Core stays put: 전체 돌리기 turns the board
        turn += step
        if moving != nil { ghost = moved(shown, board) } else { var t = g; t.r = (t.r + step) % 4; ghost = placed(t, under: hover, board) }
    }
    /// A moved board module (not the Core) dropped where it does not fit, over a same-type board module: that module's stack is offered.
    private func stackTarget(_ g: Pose, _ shown: [ServiceClient.Shown]) -> StackJoin? {
        guard let m = moving, m < shown.count, !g.isCore, let u = service.host(of: shown[m]) else { return nil }
        func over(_ a: Pose) -> Bool { a.x < g.x + g.w && g.x < a.x + a.w && a.y < g.y + g.h && g.y < a.y + a.h }
        guard let t = shown.indices.first(where: { $0 != m && !shown[$0].pose.isCore && shown[$0].pose.t & 0x1f == g.t & 0x1f && over(shown[$0].pose) }),
              let h = service.host(of: shown[t]), h != u else { return nil }
        return StackJoin(host: h, u: u)
    }
    /// Write the ghost into the profile: a moved module keeps its identity, a temp one is applied first, a palette one is new.
    private func commit(_ shown: [ServiceClient.Shown], _ board: Board) {
        defer { ghost = nil; moving = nil; turn = 0; delta = (0, 0) }
        guard let g = ghost, fits(g, shown, board) else { return }
        // connecting to a temp (connected, not yet applied) module applies that module too, so the link is kept in the profile
        let sn = board.snap(g, moving: moving)
        var partners: [Int] = []
        if let c = sn.port { partners.append(c.parent) }
        if sn.ownPort != nil { // the ghost receives pins: find whose, with the ghost in place
            var test = board.modules; if let m = moving { test[m] = g } else { test.append(g) }
            partners += Board(modules: test).connections().filter { $0.value.parent == (moving ?? test.count - 1) }.map(\.key)
        }
        // a temp the ghost lies on is covered by it, not applied (it would overlap)
        for i in partners where i < shown.count && shown[i].boardIndex == nil && !Board(modules: [shown[i].pose]).overlaps(g) { if let path = shown[i].path { service.adopt(path) } }
        var b = service.board
        if let m = moving {
            let s = shown[m]
            guard let bi = s.boardIndex ?? s.path.flatMap({ service.adopt($0) }) else { return }
            b = service.board
            b.modules[bi].x = g.x; b.modules[bi].y = g.y; b.modules[bi].r = g.r
        } else { b.modules.append(g) }
        service.setBoard(b)
    }

    // MARK: view transform

    private struct Bounds { var x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat; var centre: CGPoint { CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2) } }
    private func bounds(_ shown: [ServiceClient.Shown]) -> Bounds {
        let ps = shown.map(\.pose)
        let x0 = ps.map(\.x).min() ?? 0, y0 = ps.map(\.y).min() ?? 0, x1 = ps.map { $0.x + $0.w }.max() ?? 1, y1 = ps.map { $0.y + $0.h }.max() ?? 1
        let a = Self.point(.init(x0, y0)), b = Self.point(.init(x1, y1))
        return Bounds(x0: a.x, y0: a.y, x1: b.x - Self.gap, y1: b.y - Self.gap)
    }
    /// Board point → container point under the current rotation (about the board centre), zoom and pan.
    private func screen(_ p: CGPoint) -> CGPoint {
        let c = Self.boardSize / 2, a = Double(boardRotation) * .pi / 2
        let x = (p.x - c) * cos(a) - (p.y - c) * sin(a) + c, y = (p.x - c) * sin(a) + (p.y - c) * cos(a) + c
        return CGPoint(x: x * zoom + pan.width, y: y * zoom + pan.height)
    }
    private func settle(_ shown: [ServiceClient.Shown], _ size: CGSize) {
        if fitting || osd { fit(shown, in: size) } else if !centred, !shown.isEmpty, size.width > 1 { centre(on: bounds(shown).centre, in: size) } // 100 %, kept centred until the user pans, zooms or moves a module
    }
    private func centre(on p: CGPoint, in size: CGSize) {
        pan = .zero
        let s = screen(p)
        pan = CGSize(width: size.width / 2 - s.x, height: size.height / 2 - s.y)
    }
    private func setZoom(_ z: CGFloat, in size: CGSize) {
        let keep = CGPoint(x: size.width / 2, y: size.height / 2) // zoom about the container centre
        let before = boardPoint(keep)
        zoom = max(0.1, min(4, z)); fitting = false; centred = true
        centre(on: before, in: size)
    }
    private func boardPoint(_ s: CGPoint) -> CGPoint { // inverse of screen()
        let c = Self.boardSize / 2, a = -Double(boardRotation) * .pi / 2
        let x = (s.x - pan.width) / zoom - c, y = (s.y - pan.height) / zoom - c
        return CGPoint(x: x * cos(a) - y * sin(a) + c, y: x * sin(a) + y * cos(a) + c)
    }
    /// Bird's-eye view: scale so the whole layout fits (never above real size), centred.
    private func fit(_ shown: [ServiceClient.Shown], in size: CGSize) {
        let b = bounds(shown), m: CGFloat = pinned ? 24 : 96, w = b.x1 - b.x0 + m, h = b.y1 - b.y0 + m
        let (sw, sh) = boardRotation % 2 == 0 ? (w, h) : (h, w)
        zoom = max(0.1, min(size.width / sw, size.height / sh, Self.realZoom))
        centre(on: b.centre, in: size)
    }

    // MARK: palette

    static var paletteTypes: [(String, String, Int)] { [(L("버튼"), "square", 1), (L("버튼 ×3"), "square.grid.3x1.below.line.grid.1x2", 8), (L("다이얼"), "circle", 2), (L("다이얼 ×3"), "ellipsis.circle", 9),
                                                        (L("슬라이더"), "slider.vertical.3", 3), (L("슬라이더 ×3"), "slider.horizontal.3", 10), ("Orbiter", "dot.circle.and.hand.point.up.left.fill", 24)] }
    private var palette: some View {
        HStack(spacing: 10) {
            Text(L("모듈")).font(.caption).foregroundStyle(.secondary)
            ForEach(Self.paletteTypes, id: \.2) { name, icon, t in
                Button {
                    moving = nil; turn = 0; fitting = false; centred = true; canvasFocused = true
                    ghost = placed(Pose(t: t, x: 0, y: 0, r: 0, u: "v:" + UUID().uuidString.prefix(8)), under: hover, Board(modules: service.shown.map(\.pose)))
                } label: { VStack(spacing: 2) { Image(systemName: icon).font(.title3); Text(name).font(.system(size: 9)) }.frame(width: 56, height: 40) }
                .buttonStyle(.plain).contentShape(Rectangle())
                .help(L("누르면 모듈이 마우스를 따라옵니다. 밝은 포고핀 자리에 놓으면 연결, 빈 곳이면 떠 있는 모듈. R 90° 회전, Esc 취소"))
            }
        }
        .controlSize(.small).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
    }

    // MARK: drawing

    private func base(_ m: Module) -> String { m.uuid.components(separatedBy: "::")[0] }
    private func align(_ s: Side) -> Alignment { [.top: .top, .right: .trailing, .bottom: .bottom, .left: .leading][s]! }
    /// Where unit `k` of a side sits on a w x h box (sides are at most 2 units long).
    private func anchor(_ s: Side, _ k: Int, w: Int, h: Int) -> Alignment {
        switch s {
        case .top: return w == 1 ? .top : k == 0 ? .topLeading : .topTrailing
        case .bottom: return w == 1 ? .bottom : k == 0 ? .bottomLeading : .bottomTrailing
        case .left: return h == 1 ? .leading : k == 0 ? .topLeading : .bottomLeading
        case .right: return h == 1 ? .trailing : k == 0 ? .topTrailing : .bottomTrailing
        }
    }
    /// "P2 · i3 · ?-L6z": port, firmware id, layout `u` — names we use when talking about a module
    private func label(_ m: Module?) -> String {
        [m?.port.map { "P\($0)" } ?? "Core", m?.localId.map { "i\($0)" }, m.map(base)].compactMap { $0 }.joined(separator: " · ")
    }
    static var typeNames: [Int: String] { [1: L("버튼"), 8: L("버튼 ×3"), 2: L("다이얼"), 9: L("다이얼 ×3"), 3: L("슬라이더"), 10: L("슬라이더 ×3"), 24: "Orbiter"] }
    /// Only the two odd states get a mark: a 14pt dot on the top-left corner, the sentence in its tooltip. Connected shows nothing; not connected is the dashed, dimmed body.
    @ViewBuilder private func badge(_ s: ServiceClient.Shown) -> some View {
        let mark: (String, Color, String)? = switch s.link {
        case .turned: ("!", .red, L("방향이 실물과 다름 · 90° 회전으로 맞추면 연결됩니다"))
        case .mismatch(let t): ("!", .red, L("다른 모듈 연결됨 · 지금: \(Self.typeNames[t & 0x1f] ?? "?")"))
        case .temp: ("~", .orange, L("임시 · 할당하거나 움직이면 프로필에 적용"))
        default: nil
        }
        if let (glyph, color, tip) = mark {
            Text(glyph).font(.system(size: 10, weight: .bold)).foregroundStyle(.white).frame(width: 14, height: 14).background(Circle().fill(color)).help(tip)
        }
    }
    private func linkNote(_ s: ServiceClient.Shown) -> String? { switch s.link { case .missing: L("연결 안 됨"); case .loose: L("설계 전용"); case .turned: L("방향 다름"); default: nil } }
    private func size(_ p: Pose) -> CGSize { CGSize(width: CGFloat(p.w) * Self.pitch - Self.gap, height: CGFloat(p.h) * Self.pitch - Self.gap) }
    /// Outline of the module being moved or placed: green when it will plug in, red when it overlaps.
    private func ghostBox(_ g: Pose, ok: Bool, plugged: Bool, litPort: Int?) -> some View {
        let sz = size(g), pin = Board.pinSide(g), ports = Board.portSides(g)
        return RoundedRectangle(cornerRadius: 14).fill((ok ? plugged ? Color.green : Color.accentColor : Color.red).opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ok ? plugged ? Color.green : Color.accentColor : Color.red, lineWidth: 2))
            .overlay(alignment: pin.map { anchor($0.0, $0.1, w: g.w, h: g.h) } ?? .leading) {
                if let pin { Pogo(female: false, side: pin.0).unitFrame(vertical: pin.0 == .left || pin.0 == .right) }
            }
            .overlay { if let k = litPort, k < ports.count { // this female port is about to receive another module's pins
                Pogo(female: true, side: ports[k].0, bright: true).unitFrame(vertical: ports[k].0 == .left || ports[k].0 == .right)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor(ports[k].0, ports[k].1, w: g.w, h: g.h))
            } }
            .frame(width: sz.width, height: sz.height)
    }
    /// The box corner that shows as screen corner `c` (0 top-left, clockwise) on the turned board, and the offset that pushes a mark `d` outwards from it.
    private func corner(_ c: Int) -> Alignment { [Alignment.topLeading, .topTrailing, .bottomTrailing, .bottomLeading][(c - boardRotation + 4) % 4] }
    private func out(_ c: Int, _ d: CGFloat) -> CGSize { [CGSize(width: -d, height: -d), CGSize(width: d, height: -d), CGSize(width: d, height: d), CGSize(width: -d, height: d)][(c - boardRotation + 4) % 4] }
    private func moduleBox(_ s: ServiceClient.Shown, _ i: Int, hot: Set<String>, shown: [ServiceClient.Shown], geoBoard: Board) -> some View {
        let p = s.pose, ms = service.modules(for: s)
        let core = p.isCore, horizontal = p.w > p.h, sz = size(p)
        let pad: CGFloat = look == 3 ? (p.isCore ? 12 : 18) : 8 // developer theme: smaller cards leave a rim of frame to click for the whole module
        let innerW = sz.width - pad * 2, innerH = sz.height - pad * 2
        let n = CGFloat(max(ms.count, 1)), main = ((horizontal ? innerW : innerH) - 8 * (n - 1)) / n // cards share the long axis
        let pin = Board.pinSide(p), ports = Board.portSides(p)
        let side = pin.map { align($0.0) } ?? .leading
        let pinAlign = pin.map { anchor($0.0, $0.1, w: p.w, h: p.h) } ?? .leading
        let dim = s.link == .missing || s.link == .loose, dashed = dim || s.link == .temp
        let stroke: Color = { if case .mismatch = s.link { return .red }; if s.link == .turned { return .red }; return dim ? .gray : s.link == .temp ? .orange : look == 1 || look == 4 ? Color(white: 0.8) : .secondary }()
        return (horizontal ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))) {
            // Core: screen takes the USB half, two buttons share the other half (as on the device), along whichever axis is long
            let long = horizontal ? innerW : innerH, cross = horizontal ? innerH : innerW, half = look == 3 && boardRotation % 2 == 1 ? (long - 8) * 0.24 : (long - 8) / 2, back = p.r % 4 >= 2 // USB end on the right / bottom; developer cards lie wide on a quarter-turned board and need the height, so the screen gives way
            // the same picture the Core display gets (Screen.render: 240 px square, icon 140 at y 25, title 28 pt at y 178), scaled to fit
            let shown = service.display, k = min(horizontal ? half : cross, horizontal ? cross : half) / 240
            let coreScreen = ZStack(alignment: .top) {
                if let icon = shown?.icon { Image(nsImage: icon).resizable().frame(width: 140 * k, height: 140 * k).offset(y: 25 * k) }
                Text(shown?.title ?? service.activeProfile?["title"].string ?? "").font(.system(size: 28 * k, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                    .frame(width: 236 * k).offset(y: 178 * k)
            }.frame(width: 240 * k, height: 240 * k, alignment: .top)
                .rotationEffect(.degrees(Double(-boardRotation) * 90))
                .frame(width: horizontal ? half : cross, height: horizontal ? cross : half).background(RoundedRectangle(cornerRadius: 10).fill(look == 1 || look == 4 ? Color(white: 0.55) : .black))
            if core && !back { coreScreen }
            // 1, 2, 3 read left→right / top→bottom as seen (the engine decodes the same way); the stack runs backwards where the turned board flips its axis
            let along = core ? (long - 8 - half) / 2 - 4 : main, cw = horizontal ? along : cross, ch = horizontal ? cross : along, odd = boardRotation % 2 == 1
            ForEach((core ? back : horizontal ? boardRotation >= 2 : boardRotation == 1 || boardRotation == 2) ? ms.reversed() : ms) { m in
                ModuleCard(module: m, assignment: service.assignment(m.uuid), isSelected: !whole && selected == m, number: ServiceClient.controlNumber(m.uuid), theme: look, osdFont: osdFont, osdLabel: osdLabel(m))
                        .overlay { if opensEditedPanel(m) { RoundedRectangle(cornerRadius: 10).stroke(Color.orange, lineWidth: 2.5) } }
                    .opacity(dim ? 0.45 : 1)
                    .frame(width: odd ? ch : cw, height: odd ? cw : ch).rotationEffect(.degrees(Double(-boardRotation) * 90)) // cards stay upright on a turned board
                    .frame(width: cw, height: ch)
                    .onTapGesture { selected = m; canvasFocused = true; onOpen(m, false) }
                    .onHover { if $0 { hoverCard = m.uuid } else if hoverCard == m.uuid { hoverCard = nil } }
            }
            if core && back { coreScreen }
        }
        .padding(pad)
        .frame(width: sz.width, height: sz.height)
        .background { let on = whole && ms.contains { $0 == selected }, hov = !on && hoverBox == i && hoverCard == nil && moving == nil
            RoundedRectangle(cornerRadius: 14).fill(on ? ModuleCard.pick.opacity(0.2) : hov ? Color.blue.opacity(0.08) : .clear)
            RoundedRectangle(cornerRadius: 14).stroke(on ? ModuleCard.pick : hov ? Color.blue.opacity(0.4) : stroke, style: StrokeStyle(lineWidth: on ? 2.5 : hov ? 2 : 1.5, dash: dashed ? [6, 4] : [])) }
        .onHover { if $0 { hoverBox = i } else if hoverBox == i { hoverBox = nil } }
        .overlay { flash(s) }
        .overlay(alignment: corner(1)) { if let n = service.host(of: s).map({ service.stack($0).members.count }), n > 1 { // a stack: icon + how many 2층 modules (the 2층 판 itself is in the sidebar)
            Color.clear.frame(width: 0, height: 0).overlay(alignment: .topTrailing) { // a point on the corner: the pill turns about it, not about its own middle
                Label("\(n)", systemImage: "square.stack.3d.up.fill").font(.caption2.bold()).foregroundStyle(.black).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.orange)).fixedSize() }
                .rotationEffect(.degrees(Double(-boardRotation) * 90)).offset(out(1, 7)).allowsHitTesting(false).help(L("스택 · 2층 모듈 \(n)개"))
        } }
        .overlay(alignment: corner(0)) { if !core { Color.clear.frame(width: 0, height: 0).overlay(alignment: .topLeading) { badge(s).fixedSize() }.rotationEffect(.degrees(Double(-boardRotation) * 90)).offset(out(0, 7)) } } // on the top-left corner (user sketch)
        .overlay { ZStack { // female ports the moving module (in its current turn) can plug into
            ForEach(Array(ports.enumerated()), id: \.offset) { k, sp in
                if hot.contains("\(i)/\(k)") {
                    Pogo(female: true, side: sp.0, bright: true).unitFrame(vertical: sp.0 == .left || sp.0 == .right)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor(sp.0, sp.1, w: p.w, h: p.h))
                }
            }
        } }
        .overlay { if look == 3 { ZStack { // female ports with their number right beside the pads
            ForEach(Array(ports.enumerated()), id: \.offset) { k, sp in
                Pogo(female: true, side: sp.0, turn: boardRotation, label: "\(k)").unitFrame(vertical: sp.0 == .left || sp.0 == .right)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor(sp.0, sp.1, w: p.w, h: p.h))
            }
        } } }
        .overlay(alignment: [Alignment.leading, .top, .trailing, .bottom][p.r % 4]) { if core { Text("USB").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary).fixedSize().rotationEffect(.degrees(Double(-boardRotation) * 90)).offset(x: [-3.0, 0, 3, 0][p.r % 4], y: [0, -3.0, 0, 3][p.r % 4]) } }
        .overlay(alignment: pinAlign) { if look == 3, let pin { Pogo(female: false, side: pin.0).unitFrame(vertical: pin.0 == .left || pin.0 == .right) } }
        .overlay(alignment: pinAlign) { if look == 3 { Tag(text: [label(ms.first), linkNote(s)].compactMap { $0 }.joined(separator: " · "), side: side, turn: boardRotation) } } // developer theme reads the state in words on the address line
        .contentShape(Rectangle())
        .onTapGesture { if ghost == nil, let m = ms.first { selected = m; canvasFocused = true; onOpen(m, true) } } // the frame (not a card): whole module
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("board"))
            .onChanged { v in
                if moving != i { moving = i; turn = 0; fitting = false; centred = true; canvasFocused = true; if let m = ms.first { selected = m } } // fitting off: the view must not jump when this is dropped // a new drag, also after a cancelled one
                delta = (Int(floor((v.location.x - v.startLocation.x) / Self.pitch + 0.5)), Int(floor((v.location.y - v.startLocation.y) / Self.pitch + 0.5)))
                ghost = moved(shown, geoBoard)
            }
            .onEnded { _ in
                if let g = ghost, !fits(g, shown, geoBoard) { joining = stackTarget(g, shown) } // asked after the bounce back: cancel leaves it where it was
                commit(shown, geoBoard)
            })
        .contextMenu {
            if !core { Button(L("90° 회전")) {
                guard let bi = s.boardIndex ?? s.path.flatMap({ service.adopt($0) }) else { return }
                var g = shown[i].pose; g.r = (g.r + 1) % 4
                guard Self.fits(g, moving: i, shown, geoBoard) else { NSSound.beep(); return } // same rule as dragging: no different-shape overlap
                var b = service.board; b.modules[bi].r = g.r; service.setBoard(b)
            } }
            if s.link == .turned, let bi = s.boardIndex { Button(L("문제 해결")) { service.fixDirection(bi) } }
            if s.link == .temp, let path = s.path { Button(L("프로필에 적용")) { service.adopt(path) } }
            if let bi = s.boardIndex, bi != 0 { Button(L("삭제"), role: .destructive) { var b = service.board; b.modules.remove(at: bi); service.setBoard(b) } }
        }
    }
}

/// 2층 판: the logical modules stacked on one board module. Picking one attaches it to the hardware, so the board and the
/// 연결 화면 show and edit that one (what you edit is what the device does). One member left is a plain module again.
struct StackFloor: View {
    @EnvironmentObject var service: ServiceClient
    let host: String, kind: String
    var onPick: () -> Void
    var body: some View {
        let s = service.stack(host), single = s.members.count == 1
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(L("2층")).bold().foregroundStyle(.orange)
                Text(service.stackList.first { $0.host == host }?.title ?? L("\(kind) · 일반 모듈")).bold()
                Spacer()
                Text(single ? L("모듈이 하나라 일반 모듈입니다") : L("실물에는 한 번에 하나만 붙습니다")).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) { HStack(alignment: .top, spacing: 10) {
                ForEach(Array(s.members.enumerated()), id: \.element) { i, u in
                    StackMember(host: host, u: u, number: i + 1, placeholder: "\(kind) \(i + 1)", name: s.names[u] ?? "", attached: i == s.index, single: single, core: kind == "Core") {
                        service.stackSwitch(host, to: i); onPick()
                    }
                }
                Button { service.stackAdd(host); onPick() } label: {
                    VStack(spacing: 4) { Image(systemName: "plus").font(.title2); Text(L("추가")).font(.caption) }
                        .foregroundStyle(.secondary).frame(width: 120, height: 92)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(dash: [4, 3])))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(L("같은 종류(\(kind))의 빈 모듈을 하나 더 만들고 바로 붙입니다"))
            }.padding(.bottom, 4) }
            Text(single ? L("추가하면 스택이 됩니다. 스택을 바꾸는 버튼은 다른 컨트롤의 기능 › 스택에서 정합니다.")
                        : L("모듈을 누르면 실물에 붙고, 아래 연결이 그 모듈 것으로 바뀝니다. 하나만 남기면 일반 모듈로 돌아갑니다.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(14)
    }
}
private struct StackMember: View {
    @EnvironmentObject var service: ServiceClient
    let host: String, u: String, number: Int, placeholder: String
    @State var name: String
    let attached: Bool, single: Bool
    var core = false // the Core's stack: its members cannot become loose board modules
    var pick: () -> Void
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(number)").font(.caption.bold()).foregroundStyle(attached ? Color.black : .primary).frame(width: 18, height: 18)
                    .background(Circle().fill(attached ? Color.orange : Color.secondary.opacity(0.3)))
                Text(attached && !single ? L("지금 붙음") : "").font(.caption2).foregroundStyle(.orange)
                Spacer()
                if !single, !core { Button { service.stackTakeOut(host, u) } label: { Image(systemName: "rectangle.portrait.and.arrow.right").font(.caption2) }.buttonStyle(.plain).foregroundStyle(.secondary).help(L("판으로 꺼내기: 판 오른쪽에 설계 전용 모듈로 놓입니다. 연결은 그대로 따라갑니다 (⌘Z)")) }
                if !single { Button { service.stackRemove(host, u) } label: { Image(systemName: "trash").font(.caption2) }.buttonStyle(.plain).foregroundStyle(.secondary).help(L("스택에서 지우기 (이 모듈의 연결도 지워집니다)")) }
            }
            // the name is what the 스택 function list and the board show, so the choice reads as "밝은 영역", not "2번"
            TextField(placeholder, text: $name).textFieldStyle(.roundedBorder).disabled(single)
                .onSubmit { service.stackRename(host, u, name) }.onDisappear { if !single { service.stackRename(host, u, name) } }
                .help(single ? L("이름은 스택(모듈 둘 이상)일 때 붙입니다") : L("이름 · Enter로 저장"))
        }
        .padding(8).frame(width: 120, height: 92)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(attached ? Color.orange : Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: attached ? 2 : 1, dash: attached ? [] : [4, 3])))
        .contentShape(Rectangle()).onTapGesture(perform: pick)
    }
}

/// 스택에 넣기 question, shared by the board drop (A) and the sidebar menu (C). `u` (and its stack, if any) goes into `host`'s stack.
struct StackJoin: Identifiable { let host: String, u: String; var id: String { host + ">" + u } }
extension View {
    func confirmStackJoin(_ join: Binding<StackJoin?>, _ service: ServiceClient, done: @escaping (StackJoin) -> Void = { _ in }) -> some View {
        func name(_ u: String) -> String { service.board.modules.first { $0.u == u }.map(service.boardName) ?? u }
        return confirmationDialog(L("스택에 넣을까요?"), isPresented: Binding(get: { join.wrappedValue != nil }, set: { if !$0 { join.wrappedValue = nil } }), presenting: join.wrappedValue) { j in
            Button(L("스택에 넣기")) { service.stackInto(j.host, j.u); done(j) }
            Button(L("취소"), role: .cancel) {}
        } message: { j in
            Text(L("\(name(j.u)) 를 \(name(j.host))의 2층에 넣습니다. 연결은 그대로 따라갑니다. ⌘Z로 되돌립니다.")
                 + (service.isPlugged(j.u) ? "\n" + L("실물로 꽂혀 있는 모듈입니다. 넣은 뒤 그 자리에는 임시 모듈이 보입니다.") : ""))
        }
    }
}
