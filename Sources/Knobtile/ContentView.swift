import SwiftUI
import Engine
import ServiceManagement

struct ContentView: View {
    @EnvironmentObject var service: ServiceClient
    @State private var selectedModule: Module?
    @AppStorage("language") private var language = ""
    @State private var wiring: Module?   // 연결 화면 open for this control
    @State private var whole = false      // … showing its whole module
    @State private var trusted = AXIsProcessTrusted() // 손쉬운 사용: without it keys, clicks and scrolling go nowhere
    @State private var wiringHidden = false // sidebar collapsed by ⌥⌘I; opening a control on the board shows it again

    var body: some View {
        NavigationSplitView {
            ProfileSidebar().navigationSplitViewColumnWidth(min: 260, ideal: 280) // narrower, the three toolbar buttons (추가·가져오기·내보내기) fold away into "»"
        } detail: {
            // the split owns the drag: while an edge moves, this body (and with it every view of the window) is not evaluated again
            SidebarSplit(left: LayoutView(selected: $selectedModule, whole: whole) { m, all in wiring = m; whole = all; wiringHidden = false; service.editingPanel = nil },
                         right: service.editingPanel.map { AnyView(PanelWiringView(name: $0).id($0)) } // 패널 목록 편집 takes the sidebar while a list is open
                            ?? (wiring != nil && !wiringHidden ? AnyView(WiringView(module: $wiring, whole: $whole)) : nil)) // 연결 화면 as a right sidebar beside the board
            .safeAreaInset(edge: .top, spacing: 0) { VStack(spacing: 0) {
                if !trusted { // macOS asks once at launch and says little: say what the grant is for, as long as it is missing
                    HStack {
                        Label(L("단축키·클릭·스크롤을 다른 앱에 보내려면 손쉬운 사용 권한이 필요합니다. 시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용에서 Knobtile을 켜세요."), systemImage: "hand.raised.fill")
                        Spacer()
                        Button(L("설정 열기")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
                    }.font(.callout).padding(.horizontal).padding(.vertical, 6).background(.yellow.opacity(0.2))
                }
                // the profile's app has no plugin here: say why nothing happens, and where to fix it
                if !service.editingRoot, let lost = service.missingApp(service.activeProfile) {
                    HStack {
                        Label(L("이 프로필은 \(service.appName(lost)) 플러그인이 있어야 동작합니다. 단축키와 시스템 기능만 동작합니다."), systemImage: "exclamationmark.triangle.fill")
                        Spacer()
                        Button(L("플러그인 추가…")) { service.showPlugins() }
                    }.font(.callout).padding(.horizontal).padding(.vertical, 6).background(.orange.opacity(0.18))
                }
            } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in trusted = AXIsProcessTrusted() } // coming back from System Settings
            .onChange(of: wiring) { _, w in if let w { selectedModule = w } } // the sidebar followed an operated control or a chip: the board mark follows too
            .onChange(of: service.modules()) { // plugged/unplugged: the picked control keeps its board module (hardware uuid ↔ board id)
                wiring = wiring.flatMap(service.refreshed); selectedModule = selectedModule.flatMap(service.refreshed)
            }
            // debug: the snapshot notification's {"select": type} picks the first module of that type (remote captures without a mouse)
            .onReceive(snapshotNotes) { n in
                if let t = n.userInfo?["select"] as? String { wiring = t == "none" ? nil : service.modules().first { $0.type == t }; whole = n.userInfo?["whole"] != nil; selectedModule = wiring }
                if let id = n.userInfo?["activate"] as? String { service.dispatch("ACTIVATE_PROFILE", ["profileId": id]) } // debug: pick a profile without a mouse
            }
        }
        .id(language) // a language change draws every view again
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $service.designMode) { Text(L("디자인")).tag(true); Text(L("실행")).tag(false) }.pickerStyle(.segmented).fixedSize()
                    .help(L("디자인: 목록·프로필 전환·포인터는 그대로 동작하고, 단축키·앱 실행·앱 API 호출만 보내지 않습니다 (⌘E로 전환)"))
                    .background { Button("") { service.designMode.toggle() }.keyboardShortcut("e", modifiers: .command).opacity(0) }
            }
            ToolbarItem(placement: .status) { StatusBadge() }
            ToolbarItem { Button { wiringHidden.toggle() } label: { Label(L("연결 사이드바"), systemImage: "sidebar.trailing") }.keyboardShortcut("i", modifiers: [.command, .option]).disabled(wiring == nil).help(L("연결 사이드바 숨기기/보이기 (⌥⌘I)")) }
            ToolbarItem { Button { service.showPrefs.toggle() } label: { Label(L("환경설정"), systemImage: "gearshape") }.keyboardShortcut(",", modifiers: .command) }
        }
        .sheet(isPresented: $service.showPrefs) { PreferencesView() }
        .navigationTitle(service.editingRoot ? L("루트 프로필 · 모든 프로필의 바닥") : service.activeProfile?["title"].string ?? "Knobtile")
    }
}

struct StatusBadge: View {
    @EnvironmentObject var service: ServiceClient
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.callout)
            if let fw = service.firmware["currentVersion"].string, !fw.isEmpty {
                Text("FW \(fw)").font(.caption).foregroundStyle(.secondary)
            }
            if let (name, ok) = link {
                Circle().fill(ok ? .green : .orange).frame(width: 9, height: 9).padding(.leading, 6)
                Text(ok ? L("\(name) 연결됨") : L("\(name) 플러그인 미연결")).font(.callout)
                    .help(ok ? "" : L("\(name)이(가) 실행 중이고 그 앱의 Knobtile 플러그인이 켜져 있어야 합니다. 5초마다 재시도합니다."))
            }
        }
        .help(L("서비스: \(String(describing: service.status))"))
    }
    /// Active profile's app when it talks over a plugin socket (native mode only).
    private var link: (String, Bool)? {
        guard let id = service.activeProfile?["app"].string, let app = service.app(id: id),
              app["connections"].array.contains(where: { $0["type"].string == "tcp" }) else { return nil }
        return (app["name"].string ?? id, service.linkedApps[id] ?? false)
    }
    private var color: Color {
        guard service.status == .connected else { return .red }
        return service.coreState == "open" ? .green : .orange
    }
    private var text: String {
        switch service.status {
        case .connected: return service.coreState == "open" ? L("Core 연결됨") : L("Core 분리됨 (\(service.coreState))")
        case .connecting: return L("서비스 연결 중…")
        case .disconnected: return L("서비스 미연결")
        case .failed(let m): return L("오류: \(m)")
        }
    }
}

// MARK: - Profiles

struct ProfileSidebar: View {
    @EnvironmentObject var service: ServiceClient
    @State private var renaming: String? // profile id being renamed inline in its row
    @State private var newTitle = ""
    @FocusState private var renameFocused: Bool
    private func addPanelList() {
        let a = NSAlert(), f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        a.messageText = L("새 패널 목록"); a.informativeText = L("컨트롤을 누르고 있는 동안 화면에 뜨는 목록입니다. 기능은 오른쪽 사이드바에서 찾아 넣습니다.")
        f.placeholderString = L("예: 자주 쓰는 것"); a.accessoryView = f
        a.addButton(withTitle: L("만들기")); a.addButton(withTitle: L("취소")); a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let n = f.stringValue.trimmingCharacters(in: .whitespaces), all = service.panelLists.compactMap { $0.any as? [String: Any] }
        guard !n.isEmpty, !all.contains(where: { $0["name"] as? String == n }) else { NSSound.beep(); return }
        service.setPanelLists(all + [["name": n, "items": [] as [Any]]])
        service.editingPanel = n
    }
    @State private var selected: String? // local so a click lands at once; the store's answer arrives a tick later and would snap the List back meanwhile
    private var activeId: String? { service.editingRoot ? nil : service.activeProfile?["id"].string }

    var body: some View {
        List(selection: $selected) {
            ForEach(bundles, id: \.app) { bundle in // 프로필 묶음: section title = the app (not selectable), rows = default profile first, then its screen profiles
                Section {
                    if let h = bundle.head { row(h, head: true) }
                    ForEach(bundle.children, id: \.["id"].string) { p in row(p, head: false) }
                        .onMove { from, to in // page order for Next Page: reorder these within the whole list
                            var kids = bundle.children.map { $0["id"].string ?? "" }; kids.move(fromOffsets: from, toOffset: to)
                            var it = kids.makeIterator()
                            service.dispatch("REORDER_PROFILES", ["order": service.profiles.map { p in let id = p["id"].string ?? ""; return kids.contains(id) ? it.next()! : id }])
                        }
                } header: { header(bundle) }
            }
            Section(L("패널 목록")) { // 직접 만든 고르기 패널: shared by every profile (kept in the root)
                ForEach(service.panelLists.compactMap { $0["name"].string }, id: \.self) { n in
                    Button { service.editingPanel = service.editingPanel == n ? nil : n } label: { Label(n, systemImage: "list.bullet.rectangle").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                        .listRowBackground(service.editingPanel == n ? RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.25)).padding(.horizontal, 10) : nil)
                        .contextMenu { Button(L("목록 삭제"), role: .destructive) { service.setPanelLists(service.panelLists.compactMap { $0.any as? [String: Any] }.filter { $0["name"] as? String != n }) } } // ⌘Z brings it back; wires that open it stay and do nothing meanwhile
                }
                Button { addPanelList() } label: { Label(L("목록 추가"), systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .onAppear { selected = activeId }
        .onChange(of: activeId) { _, id in selected = id }
        .onChange(of: selected) { _, id in if let id, id != activeId { service.editingRoot = false; service.dispatch("ACTIVATE_PROFILE", ["profileId": id]) } }
        .toolbar {
            ToolbarItem {
                Button {
                    let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(21)
                    service.dispatch("ADD_PROFILE", ["profile": [
                        "id": String(id), "title": L("새 프로필"), "app": "", "tags": [],
                        "lastActivated": Int(Date().timeIntervalSince1970 * 1000), "assignments": [:]]])
                } label: { Label(L("프로필 추가"), systemImage: "plus") }
            }
            ToolbarItem { Button { importProfile() } label: { Label(L("프로필 가져오기"), systemImage: "square.and.arrow.down") }.help(L("프로필 또는 내보낸 묶음 가져오기")) }
            ToolbarItem { Button { exportBundle(nil) } label: { Label(L("전체 내보내기"), systemImage: "square.and.arrow.up") }.help(L("모든 프로필 내보내기")) }
        }
    }

    /// Copies the chosen image into our support dir so the profile keeps working if the source moves.
    private func pickIcon(_ p: JSON) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let src = panel.url, let id = p["id"].string else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Knobtile/icons")
        let dst = dir.appendingPathComponent(id + "." + src.pathExtension)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.copyItem(at: src, to: dst)) != nil else { return }
        service.dispatch("UPDATE_PROFILE", ["profileId": id, "icon": dst.path])
    }
    /// Profile files are the profile object as stored (same shape as state.json entries).
    private func exportProfile(_ p: JSON) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (p["title"].string ?? "profile") + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? JSONSerialization.data(withJSONObject: p.any, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
    /// All profiles of one app (nil = every profile) in one file; the checkbox adds the root.
    private func exportBundle(_ app: String?) {
        let panel = NSSavePanel(), withRoot = NSButton(checkboxWithTitle: L("루트 프로필 포함"), target: nil, action: nil)
        withRoot.state = app == nil ? .on : .off
        panel.accessoryView = withRoot
        panel.nameFieldStringValue = (app.map { $0.isEmpty ? L("앱 없음") : appName($0) } ?? L("Knobtile 전체")) + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? JSONSerialization.data(withJSONObject: service.exportBundle(app: app, root: withRoot.state == .on), options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let d = try? Data(contentsOf: url),
              let f = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        var replace = false, root = false
        if let list = f["profiles"] as? [Any] { // a bundle: ask how, a single profile is just added
            let a = NSAlert(), withRoot = NSButton(checkboxWithTitle: L("루트 프로필도 바꾸기"), target: nil, action: nil)
            a.messageText = L("프로필 \(list.count)개 가져오기")
            a.informativeText = L("지금 프로필에 추가하거나, 지금 프로필을 모두 지우고 파일의 것으로 바꿉니다. ⌘Z로 되돌릴 수 있습니다.")
            a.addButton(withTitle: L("추가")); a.addButton(withTitle: L("모두 바꾸기")); a.addButton(withTitle: L("취소"))
            if f["root"] != nil { withRoot.state = .on; a.accessoryView = withRoot }
            let r = a.runModal()
            if r == .alertThirdButtonReturn { return }
            replace = r == .alertSecondButtonReturn; root = f["root"] != nil && withRoot.state == .on
        }
        if !service.importFile(f, replace: replace, root: root) { NSSound.beep() }
    }
    private func appName(_ id: String?) -> String { service.appName(id) }
    struct Bundle { let app: String; let head: JSON?; let children: [JSON] } // head = latest screen-less profile (what a detected screen without its own profile falls back to)
    /// 모든 앱 first, then apps in first-appearance order; children in the app's screen order.
    private var bundles: [Bundle] {
        var order: [String] = [], by: [String: [JSON]] = [:]
        for p in service.profiles { let a = p["app"].string ?? ""; if by[a] == nil { order.append(a) }; by[a, default: []].append(p) }
        if let i = order.firstIndex(of: ""), i > 0 { order.remove(at: i); order.insert("", at: 0) }
        return order.map { a in
            let head = by[a]!.first { ($0["screen"].string ?? "").isEmpty } // list order, not lastActivated: clicking a second screen-less profile must not swap rows under the mouse
            return Bundle(app: a, head: head, children: by[a]!.filter { $0["id"].string != head?["id"].string }) // list order = page order
        }
    }
    private func screenName(_ app: String, _ key: String) -> String { // names: English first, Korean last (both are window titles to match)
        let n = Engine.screens[app]?.first { $0.key == key }?.names
        return (Language.code == "en" ? n?.first : n?.last) ?? key
    }
    private func screenName(_ p: JSON) -> String {
        let k = p["screen"].string ?? ""
        return k.isEmpty ? (Engine.screens[p["app"].string ?? ""] == nil ? "" : L("기본")) : screenName(p["app"].string ?? "", k)
    }
    /// Section title: app icon + name, and the screen the app is on right now ("→ 기본" when that screen has no profile of its own).
    @ViewBuilder private func header(_ b: Bundle) -> some View {
        let now: String? = service.screen.flatMap { $0.app == b.app ? $0 : nil }.map { sc in
            screenName(b.app, sc.key) + (b.children.contains { $0["screen"].string == sc.key } ? "" : L(" → 기본")) }
        HStack(spacing: 6) {
            Group { if let icon = appIcon(b.app) { Image(nsImage: icon).resizable() } else { Color.clear } }.frame(width: 18, height: 18) // empty slot keeps titles aligned
            Text(b.app.isEmpty ? L("앱 없음") : appName(b.app)).font(.headline).foregroundStyle(.primary)
            if let now { Text(L("· 지금 \(now)")).font(.caption).foregroundStyle(.secondary) }
            if ([b.head] + b.children).contains(where: service.missingPlugin) {
                Button { service.showPlugins() } label: { Label(L("플러그인 없음"), systemImage: "exclamationmark.triangle.fill") }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.orange).help(L("이 앱의 플러그인이 설치되지 않아 앱 기능이 동작하지 않습니다. 누르면 플러그인 설정이 열립니다."))
            }
        }.padding(.top, 4)
        .contextMenu {
            Button(L("이 앱 프로필 내보내기…")) { exportBundle(b.app) }
            if let h = b.head ?? b.children.first, let list = Engine.screens[b.app] {
                Menu(L("화면 추가")) { // copy of the default profile bound to that screen
                    ForEach(list, id: \.key) { sc in
                        Button(sc.names.last!) { duplicate(h, title: sc.names.last!, screen: sc.key) }
                            .disabled(b.children.contains { $0["screen"].string == sc.key })
                    }
                }
            }
        }
    }
    /// Every profile is the same row: a 12pt slot (page color dot or empty, so titles line up), title, screen caption, count.
    @ViewBuilder private func row(_ p: JSON, head: Bool) -> some View {
        let screen = p["screen"].string ?? "", isDefault = head && screen.isEmpty && Engine.screens[p["app"].string ?? ""] != nil
        HStack(spacing: 8) {
            Circle().fill(p["color"].string.map { $0.isEmpty ? Color.clear : Color(hex: $0) } ?? .clear).frame(width: 8, height: 8).frame(width: 12)
            VStack(alignment: .leading) {
                if renaming == p["id"].string { // inline rename: return saves, esc or losing focus cancels
                    TextField(L("이름"), text: $newTitle).textFieldStyle(.plain).focused($renameFocused)
                        .onSubmit { service.dispatch("UPDATE_PROFILE", ["profileId": renaming ?? "", "title": newTitle]); renaming = nil }
                        .onExitCommand { renaming = nil }
                        .onChange(of: renameFocused) { _, f in if !f { renaming = nil } }
                } else {
                    Text(p["title"].string ?? L("제목 없음")).onTapGesture(count: 2) { rename(p) }
                        .simultaneousGesture(TapGesture().onEnded { selected = p["id"].string }) // the double-click gesture takes the List's own click on the text
                }
                Text(isDefault ? L("기본 · 다른 화면은 여기로") : screenName(p)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(p["assignments"].object.count)").font(.caption2).foregroundStyle(.tertiary)
        }
        .tag(p["id"].string ?? "")
        .contextMenu { rowMenu(p) }
    }
    private func rename(_ p: JSON) { newTitle = p["title"].string ?? ""; renaming = p["id"].string; DispatchQueue.main.async { renameFocused = true } }
    @ViewBuilder private func rowMenu(_ p: JSON) -> some View {
        Button(L("이름 변경")) { rename(p) }
        Button(L("복제")) { duplicate(p, title: (p["title"].string ?? "") + L(" 복사"), screen: p["screen"].string ?? "") }
        Menu(L("앱 지정")) {
            ForEach(service.apps, id: \.["id"].string) { a in
                Button(a["name"].string ?? "") { service.dispatch("UPDATE_PROFILE", ["profileId": p["id"].string ?? "", "app": a["id"].string ?? ""]) }
            }
            Divider()
            Button(L("다른 앱 고르기…")) { // an app without an integration (Photoshop): the profile follows it by bundle id
                let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
                if panel.runModal() == .OK, let u = panel.url, let id = Foundation.Bundle(url: u)?.bundleIdentifier { service.dispatch("UPDATE_PROFILE", ["profileId": p["id"].string ?? "", "app": id]) }
            }
        }
        if let list = Engine.screens[p["app"].string ?? ""] { // LrC module / Resolve page this profile belongs to
            Menu(L("화면")) {
                Button(L("없음")) { service.dispatch("UPDATE_PROFILE", ["profileId": p["id"].string ?? "", "screen": ""]) }
                ForEach(list, id: \.key) { sc in Button(sc.names.last!) {
                    // the default must stay: giving it a screen would leave the 묶음 headless (no row to select, no 화면 추가, closing the last page empties the app)
                    if (p["screen"].string ?? "").isEmpty { duplicate(p, title: sc.names.last!, screen: sc.key) }
                    else { service.dispatch("UPDATE_PROFILE", ["profileId": p["id"].string ?? "", "screen": sc.key]) }
                } }
            }
        }
        Menu(L("페이지 색")) { // LED color of controls without their own; also the page's wave/welcome color
            Button(L("없음")) { service.dispatch("UPDATE_PROFILE", ["profileId": p["id"].string ?? "", "color": ""]) }
            ForEach([(L("빨강"), "#ff3030"), (L("주황"), "#ff8c00"), (L("노랑"), "#ffd000"), (L("초록"), "#30d040"), (L("하늘"), "#30b0ff"), (L("파랑"), "#3050ff"), (L("자주"), "#c040e0"), (L("흰색"), "#ffffff")], id: \.1) { n, hex in
                Button { service.dispatch("UPDATE_PROFILE", ["profileId": p["id"].string ?? "", "color": hex]) } label: { Label(n, systemImage: p["color"].string == hex ? "checkmark.circle.fill" : "circle.fill") }
            }
        }
        Button(L("아이콘 선택…")) { pickIcon(p) }
        Button(L("내보내기…")) { exportProfile(p) }
        Divider()
        Button(L("닫기"), role: .destructive) { service.dispatch("CLOSE_PROFILE", ["profileId": p["id"].string ?? ""]) }
    }
    private func appIcon(_ id: String) -> NSImage? { service.appIcon(id) }
    /// A copy with the same app, board, assignments and icon: pick its 화면 afterwards to fill the bundle.
    private func duplicate(_ p: JSON, title: String, screen: String) {
        var c = p.any as? [String: Any] ?? [:]; c["id"] = nil; c["lastActivated"] = nil
        c["title"] = title; c["screen"] = screen
        service.dispatch("ADD_PROFILE", ["profile": c])
    }
}
struct EventLog: View {
    @EnvironmentObject var service: ServiceClient
    @EnvironmentObject private var live: Live
    let selected: String? // filter to the selected module when 선택만 is on
    @State private var onlySelected = false
    @State private var paused = false
    private static let t: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
    private var rows: [Engine.Event] { live.events.filter { !onlySelected || selected == nil || $0.uuid == selected } }
    private func line(_ e: Engine.Event) -> String {
        "\(Self.t.string(from: e.time))  \(e.uuid.padding(toLength: 18, withPad: " ", startingAt: 0))  \(e.name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(e.value.formatted(.number.precision(.fractionLength(0...3))))  → \(e.action ?? "—")"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("이벤트 로그")).font(.caption.bold())
                Toggle(L("선택만"), isOn: $onlySelected).toggleStyle(.button)
                Toggle(paused ? L("▶ 재개") : L("⏸ 정지"), isOn: $paused).toggleStyle(.button).onChange(of: paused) { service.logPaused = paused }
                Button(L("복사")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rows.reversed().map(line).joined(separator: "\n"), forType: .string) }
                Button(L("지우기")) { live.events = [] }
                Spacer(); Text("\(rows.count)").font(.caption).foregroundStyle(.secondary)
            }.controlSize(.mini).padding(6)
            ScrollView { LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(Array(rows.prefix(200).enumerated()), id: \.offset) { _, e in
                    HStack(spacing: 10) {
                        Text(Self.t.string(from: e.time)).foregroundStyle(.secondary)
                        Text(service.address(e.uuid)).foregroundStyle(.blue).frame(width: 150, alignment: .leading).lineLimit(1).help(e.uuid)
                        Text("\(e.name) \(e.value.formatted(.number.precision(.fractionLength(0...3))))").foregroundStyle(.green).frame(width: 150, alignment: .leading)
                        Text(e.action ?? "—").foregroundStyle(e.action == nil ? .secondary : .primary).lineLimit(1)
                    }
                }
            }.padding(.horizontal, 8).padding(.bottom, 6) }.font(.system(size: 10, design: .monospaced))
        }
        .frame(height: 170).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
    }
}

struct Tag: View {
    let text: String, side: Alignment
    var turn = 0 // quarter turns of the board: the text reads level on a top/bottom edge as seen, upward on a side edge, never upside down
    var body: some View {
        let vertical = side == .leading || side == .trailing
        Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).fixedSize()
            .rotationEffect(.degrees((vertical != (turn % 2 == 1) ? -90 : 0) - Double(turn) * 90))
            .frame(width: vertical ? 12 : LayoutView.unit, height: vertical ? LayoutView.unit : 12)
            .offset(x: side == .leading ? -17 : side == .trailing ? 17 : 0, y: side == .top ? -17 : side == .bottom ? 17 : 0) // pins reach 4pt past the border
    }
}

/// Connector as on the device: male = 6 spring pins in two groups of 3 biting the border, female = 7 faint flat pads inside.
struct Pogo: View {
    let female: Bool, side: LayoutView.Side
    var bright = false // a female port the dragged module can plug into
    var turn = 0 // quarter turns of the board, so the digit stays upright
    var label: String? // developer theme: port number right beside the pads (after them on horizontal arms, above them on vertical arms)
    private var vertical: Bool { side == .left || side == .right }
    private var edge: Edge.Set { switch side { case .top: .top; case .right: .trailing; case .bottom: .bottom; case .left: .leading } }
    var body: some View {
        ZStack {
            if female { // 7 flat pads inside the body
                // the port number hangs off the row (overlay), so the pads stay centred on the unit and face the other module's pins
                stack(spacing: 6) {
                    ForEach(0..<7) { _ in Rectangle().fill(.yellow.opacity(bright ? 0.95 : 0.08)).frame(width: vertical ? 7 : 6, height: vertical ? 6 : 7).shadow(color: bright ? .yellow : .clear, radius: 4) }
                }
                .overlay(alignment: vertical ? .top : .trailing) { if let label { digit(label).offset(x: vertical ? 0 : 13, y: vertical ? -13 : 0) } }
                .padding(edge, 4)
            } else { // 6 spring pins (3+3) centered on the border line: the pads' size and pitch, the middle (4th) place empty
                stack(spacing: 6) { ForEach(0..<6) { i in Ellipse().fill(.yellow.opacity(0.45)).frame(width: vertical ? 7 : 6, height: vertical ? 6 : 7).padding(vertical ? .top : .leading, i == 3 ? 12 : 0) } }
                    .offset(x: side == .left ? -3.5 : side == .right ? 3.5 : 0, y: side == .top ? -3.5 : side == .bottom ? 3.5 : 0)
            }
        }
    }
    private func digit(_ t: String) -> some View { Text(t).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.yellow.opacity(0.8)).frame(width: 7, height: 7).rotationEffect(.degrees(Double(-turn) * 90)) }
    private func stack<C: View>(spacing: CGFloat, @ViewBuilder _ c: () -> C) -> some View {
        (vertical ? AnyLayout(VStackLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))) { c() }
    }
}

extension View {
    /// Fix the connector/name to one unit along the module edge so it centers on that unit, not on the corner.
    func unitFrame(vertical: Bool) -> some View { frame(width: vertical ? nil : LayoutView.unit, height: vertical ? LayoutView.unit : nil) }
}

struct ModuleCard: View {
    let module: Module
    let assignment: JSON
    let isSelected: Bool
    @Environment(\.noActiveFill) private var noActiveFill
    @EnvironmentObject private var hw: Live // the card is the leaf that shows live state; its parents do not observe it
    private var isActive: Bool { hw.active[module.uuid] != nil } // the physical control is being pressed/turned right now
    private var pose: (angle: Double, x: Double, y: Double)? { hw.pose[module.uuid] } // dial pointer angle, orbiter tilt
    private var led: Color? { hw.ledFrame[module.uuid].map { Color(red: Double($0.r) / 255, green: Double($0.g) / 255, blue: Double($0.b) / 255) } } // nil = unplugged: fall back to the assigned color
    var number: Int? // developer theme: ①②③ badge, the control's index in its module
    var theme = 3
    var osdFont: CGFloat? = nil // 상시 맵: label size in board points (the board is scaled down), two lines
    var osdLabel: String? = nil // 맵 보기: what the control does, written under it; also turns on the touched-control highlight
    @State private var hovered = false
    private var name: String { osdLabel ?? assignment["settings"]["name"].string ?? assignment["preset"].string ?? L("미할당") }

    var body: some View {
        Group { if theme == 3 { devCard } else { shape } }.contentShape(Rectangle()).onHover { hovered = $0 } // light blue = clickable
    }
    static let pick = Color.accentColor.opacity(0.55) // one lighter selection colour for a module frame and a control card
    private var halo: Color { isSelected ? Self.pick : .blue.opacity(hovered ? 0.5 : 0.18) } // selectable ring as in the original app
    /// Themes 1/2 (mockup indicators.html 안 A/B): dial = tick ring + accent arc swept from 12 o'clock + needle + tick count;
    /// orbiter = ring arc/needle from 3 o'clock + crosshair + tilt dot with a line from the centre; key = inner fill + LED bar while held.
    /// Theme 2 draws the same in the assignment's LED color with a glow. Theme 4 (안 C) is thin outlines, one bold accent stroke and numbers.
    private var shape: some View {
        let mini = theme == 4, w: CGFloat = mini ? 1.5 : 3
        return VStack(spacing: 4) {
            if module.type == "dial" || module.type == "orbiter" {
                GeometryReader { g in
                    let d = min(g.size.width, g.size.height), orbiter = module.type == "orbiter"
                    let angle = (pose?.angle ?? 0).truncatingRemainder(dividingBy: 360), sweep = angle < 0 ? angle + 360 : angle
                    ZStack {
                        Circle().stroke(halo, lineWidth: 3)
                        Circle().stroke(.secondary.opacity(0.6), lineWidth: w).padding(7)
                        if !orbiter && !mini { // 36 ticks, every 9th longer
                            ForEach(0..<36, id: \.self) { i in
                                Rectangle().fill(.secondary.opacity(0.5)).frame(width: 1, height: i % 9 == 0 ? d * 0.07 : d * 0.04)
                                    .offset(y: -d * 0.4).rotationEffect(.degrees(Double(i) * 10))
                            }
                        }
                        Circle().stroke(.secondary.opacity(0.4), lineWidth: mini ? 1 : 2).scaleEffect(orbiter ? 0.75 : 0.6)
                        if orbiter {
                            if !mini { Circle().trim(from: 0, to: sweep / 360).stroke(live.opacity(0.8), style: .init(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90)).padding(10).shadow(color: glow, radius: 4) } // arc from 12 o'clock
                            Capsule().fill(live).frame(width: d * 0.1, height: 4).offset(x: d * 0.4).rotationEffect(.degrees(sweep - 90)).shadow(color: glow, radius: 4)
                            if !mini {
                                Rectangle().fill(.secondary.opacity(0.3)).frame(width: d * 0.5, height: 1)
                                Rectangle().fill(.secondary.opacity(0.3)).frame(width: 1, height: d * 0.5)
                                Circle().stroke(.secondary, lineWidth: 1.5).frame(width: d * 0.14, height: d * 0.14)
                            }
                            let dot = CGPoint(x: (pose?.x ?? 0) * d * 0.27, y: -(pose?.y ?? 0) * d * 0.27) // tilt arrives as screen right / up (Modules.swift)
                            Path { $0.move(to: .zero); $0.addLine(to: dot) }.stroke(live.opacity(0.7), style: .init(lineWidth: mini ? 3 : 2, lineCap: .round)).offset(x: d / 2, y: d / 2)
                            Circle().fill(live).frame(width: d * (mini ? 0.1 : 0.14), height: d * (mini ? 0.1 : 0.14)).offset(x: dot.x, y: dot.y).shadow(color: glow, radius: 5)
                            if mini { Text("X \(Int((pose?.x ?? 0) * 100)) · Y \(Int((pose?.y ?? 0) * 100))").font(.system(size: 11)).foregroundStyle(live).offset(y: d * 0.36) }
                        } else {
                            if !mini { Circle().trim(from: 0, to: sweep / 360).stroke(live.opacity(0.8), style: .init(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90)).scaleEffect(0.7).shadow(color: glow, radius: 4) } // arc from 12 o'clock
                            Capsule().fill(live).frame(width: mini ? 4 : 3, height: d * 0.22).offset(y: -d * 0.14).rotationEffect(.degrees(sweep)).shadow(color: glow, radius: 4)
                            Circle().fill(live).frame(width: 7, height: 7)
                            if let v = hw.value[module.uuid] { Text(String(format: "%g", (v * 100).rounded() / 100)).font(.system(size: mini ? 11 : 9)).foregroundStyle(mini ? live : .secondary).offset(y: d * (mini ? 0.36 : 0.13)) } // the app's own value beats our turn count
                            else if mini { Text("\(Int((pose?.angle ?? 0).rounded()) >= 0 ? "+" : "")\(Int((pose?.angle ?? 0).rounded()))°").font(.system(size: 11)).foregroundStyle(live).offset(y: d * 0.36) }
                            else { Text("\(Int(((pose?.angle ?? 0) / 3.75).rounded()))t").font(.system(size: 9)).foregroundStyle(.secondary).offset(y: d * 0.13) }
                        }
                    }.frame(width: d, height: d).frame(maxWidth: .infinity, maxHeight: .infinity)
                }.aspectRatio(1, contentMode: .fit)
                ledBar
            } else { // button, slider
                VStack(spacing: 5) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).stroke(mini && isActive ? live : halo, lineWidth: 3)
                        RoundedRectangle(cornerRadius: 9).stroke(.secondary.opacity(0.6), lineWidth: w).padding(7)
                        RoundedRectangle(cornerRadius: 5).fill(isActive && !mini ? AnyShapeStyle(live.opacity(0.85)) : AnyShapeStyle(.clear)).padding(15).shadow(color: isActive ? glow : .clear, radius: 6)
                        RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.4), lineWidth: 1.5).padding(15)
                    }
                    ledBar
                }
            }
            if theme == 2 || mini { Text(name).font(osdFont.map { .system(size: $0) } ?? .caption).lineLimit(osdFont == nil ? 1 : 2).multilineTextAlignment(.center).minimumScaleFactor(osdFont == nil ? 1 : 0.7).fontWeight(isActive ? .semibold : .regular).foregroundStyle(assignment.isNull ? .secondary : .primary) }
        }.padding(4)
        .background { if osdLabel != nil, isActive, !noActiveFill { RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.18)) } }
    }
    /// Moving-part color: theme 2 uses the assignment's LED color (black = unset) and glows; theme 1 uses the accent.
    private var live: Color {
        if theme == 2, let led { return led }
        if theme == 2, let c = assignment["settings"]["color"].string, c != "#000000" { return Color(hex: c) }
        return theme == 2 ? Color(red: 0.6, green: 0.82, blue: 1) : .accentColor
    }
    private var glow: Color { theme == 2 ? live.opacity(0.9) : .clear }
    /// The control's LED as the Core shows it now (unplugged: the assigned color), in every theme and on every kind of control.
    private var ledColor: Color? { led ?? assignment["settings"]["color"].string.flatMap { $0 == "#000000" ? nil : Color(hex: $0) } }
    private var ledBar: some View { Capsule().fill(ledColor ?? .secondary.opacity(0.25)).frame(width: 36, height: 4).shadow(color: ledColor.map { $0.opacity(theme == 2 ? 0.9 : 0) } ?? .clear, radius: 4) }
    private var devCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let number { Text(String(UnicodeScalar(0x2460 + number - 1)!)).font(.title3).foregroundStyle(.yellow) }
                Image(systemName: icon).font(.title2)
                Spacer()
                Text(module.type).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(name)
                .font(.callout).lineLimit(2)
                .foregroundStyle(assignment.isNull ? .secondary : .primary)
            if let c = ledColor {
                RoundedRectangle(cornerRadius: 2).fill(c).frame(height: 4)
            }
            Spacer(minLength: 0)
            devInfo // decoded raw · position gauge · last event → action (mockup devmode.html 안 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(isActive ? AnyShapeStyle(.green.opacity(0.07)) : hovered ? AnyShapeStyle(.blue.opacity(0.08)) : AnyShapeStyle(.background.secondary)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isActive ? .green.opacity(0.35) : isSelected ? Self.pick : hovered ? .blue.opacity(0.25) : .clear, lineWidth: 2)) // active flash kept faint on purpose
    }
    @EnvironmentObject private var service: ServiceClient
    private var devInfo: some View {
        let raw = hw.raw[module.uuid], st = service.runtimeState(module.uuid)
        let decoded: String = switch module.type {
            case "dial": raw.map { "p=\($0[0]) t=\($0[1]) tap=\($0[2])" } ?? "idle"
            case "orbiter": raw.map { "ring=\($0[0]) x=\($0[1]) y=\($0[2])" } ?? "idle"
            default: raw.map { "v=\($0[0])" } ?? "idle" }
        let mine = hw.events.lazy.filter { $0.uuid == module.uuid && $0.name != "pose" }
        let last = mine.first { $0.action != nil } ?? mine.first // prefer the event that did something
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(decoded)\(st.map { " · sens \($0.sensitivity)" } ?? "")").foregroundStyle(raw == nil ? .secondary : .primary)
            // gauge and last-event rows always keep their place, so the card doesn't jump when they come and go
            if module.type != "button" { GeometryReader { g in ZStack(alignment: .leading) {
                Capsule().fill(.quaternary); Capsule().fill(.blue).frame(width: g.size.width * (st?.position ?? 0) / 255)
            } }.frame(height: 4) }
            Text(last.map { "\($0.name)(\($0.value.formatted(.number.precision(.fractionLength(0...2))))) → \($0.action ?? "—")" } ?? " ").foregroundStyle(.green).lineLimit(1)
        }.font(.system(size: 10, design: .monospaced))
    }
    private var icon: String {
        switch module.type { case "dial": return "dial.medium"; case "slider": return "slider.vertical.3"; case "orbiter": return "circle.circle"; default: return "button.programmable" }
    }
}

// MARK: - Inspector

/// Preset list for one control (the former inspector's lower half): sections, screen chips, search.
struct PresetList: View {
    @EnvironmentObject var service: ServiceClient
    let module: Module
    @State private var search = ""
    @State private var group = 0 // 0 = profile app's presets, 1 = Universal (공통)
    @State private var expanded: Set<String> = []  // collapsed sections by default; searching opens all
    @State private var screenFilter: [String]? = nil // nil = 전체, [] = 공통, ["develop"] …

    var body: some View {
        let profile = service.activeProfile
        let appId = service.editingRoot ? "" : profile?["app"].string ?? "" // root: common presets only
        let presets = presetsFor(type: module.type, appId: appId)
        VStack(alignment: .leading, spacing: 0) {
            if !appId.isEmpty { // the person picks the category: this app's functions or the common ones
                    Picker("", selection: $group) { Text(L("공통")).tag(1); Text(service.appName(appId)).tag(0) }
                        .pickerStyle(.segmented).labelsHidden().padding(.horizontal)
                }
                TextField(L("프리셋 검색"), text: $search).textFieldStyle(.roundedBorder).padding(.horizontal)
                let shownItems = presets.filter { (appId.isEmpty || ($0.appId.isEmpty == (group == 1))) && (search.isEmpty || $0.label.found(search)) }
                let tagged = !shownItems.isEmpty && shownItems[0].screens != nil // Lightroom: section → screen table
                if tagged {
                    HStack(spacing: 6) { // chips: filter by the screen a preset is meant for (only screens some preset names)
                        chip(L("전체"), nil)
                        ForEach((Engine.screens[appId] ?? []).filter { sc in shownItems.contains { $0.screens?.contains(sc.key) == true } }, id: \.key) { sc in chip(sc.names.last!, [sc.key]) }
                        chip(L("공통"), [])
                    }.padding(.horizontal).padding(.top, 4)
                }
                let onScreen = profile?["screen"].string ?? ""
                let sections = sectionsOf(shownItems.filter { i in screenFilter.map { f in f.isEmpty ? i.screens == [] : i.screens?.contains(f[0]) == true } ?? true })
                List {
                    ForEach(sections, id: \.0) { sec, items in
                        let open = sec.isEmpty || !search.isEmpty || shownItems.count <= 40 || expanded.contains(sec) // short lists and searches open everything
                        Section(isExpanded: Binding(get: { open }, set: { if $0 { expanded.insert(sec) } else { expanded.remove(sec) } })) {
                            ForEach(items, id: \.key) { item in presetRow(item, module: module, dim: tagged && !onScreen.isEmpty && item.screens != [] && item.screens?.contains(onScreen) == false) }
                        } header: {
                            if !sec.isEmpty {
                                Button { if open { expanded.remove(sec) } else { expanded.insert(sec) } } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).frame(width: 12)
                                        Text(sec).font(.headline); Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.listStyle(.sidebar)
        }.padding(.top, 8)
    }

    struct Item {
        let key: String; let appId: String; let preset: JSON
        var label: String { preset["label"].string ?? preset["name"].string ?? "" }
        var screens: [String]? { PresetText.screens(app: appId, label: label) }
    }

    /// Items grouped by their label's first segment, catalog order kept; section "" (no dot) first.
    private func sectionsOf(_ items: [Item]) -> [(String, [Item])] {
        var order: [String] = [], by: [String: [Item]] = [:]
        for i in items { let s = PresetText.section(i.label); if by[s] == nil { order.append(s) }; by[s, default: []].append(i) }
        return order.sorted { $0.isEmpty && !$1.isEmpty }.map { ($0, by[$0]!) }
    }

    private func chip(_ title: String, _ value: [String]?) -> some View {
        Group { if screenFilter == value { Button(title) {}.buttonStyle(.borderedProminent) } else { Button(title) { screenFilter = value }.buttonStyle(.bordered) } }
            .controlSize(.small)
    }

    private func presetRow(_ item: Item, module: Module, dim: Bool) -> some View {
        let n = PresetText.name(item.label)
        let desc = PresetText.describe(item.preset.any as? [String: Any] ?? [:], type: module.type)
        return Button {
            service.dispatch("ASSIGN_MODULE", ["uuid": module.uuid, "assignment": [
                "app": item.appId, "preset": item.preset["name"].string ?? "", "settings": item.preset.any]])
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    (Text(n.group.isEmpty ? "" : n.group + " · ").foregroundStyle(.secondary) + Text(n.name).foregroundStyle(.primary))
                    if !desc.isEmpty { Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                if let sc = item.screens { // 현상 / 라이브러리·현상 / 공통
                    Text(sc.isEmpty ? L("공통") : sc.map { k in Engine.screens[item.appId]?.first { $0.key == k }?.names.last ?? k }.joined(separator: "·"))
                        .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(sc == ["develop"] ? .orange : sc.isEmpty ? .secondary : .teal)
                }
            }.opacity(dim ? 0.55 : 1)
        }.buttonStyle(.plain).help(item.label)
    }

    /// Presets of the profile's app plus the Universal app (id ""). Core buttons use `button` presets.
    private func presetsFor(type: String, appId: String) -> [Item] {
        let ids = appId.isEmpty ? [""] : [appId, ""]
        return ids.flatMap { id -> [Item] in
            (service.app(id: id)?["presets"][type].array ?? []).enumerated().map {
                Item(key: "\(id)#\($0.offset)", appId: id, preset: $0.element)
            }
        }
    }
}

/// Per-assignment settings the engine reads: name, color, sensitivity, turn.step / turn.invert.
struct AssignmentEditor: View {
    @EnvironmentObject private var service: ServiceClient
    let module: Module
    let assignment: JSON
    let update: ((inout [String: Any]) -> Void) -> Void

    var body: some View {
        let s = assignment["settings"]
        Form {
            TextField(L("이름"), text: Binding(get: { s["name"].string ?? "" }, set: { v in update { $0["name"] = v } }))
            // LED 색 종류: 단일색, or a color that changes with the value (built-in band / 사용자 정의 two colors) on every LED while the control moves.
            // Changing colors need a position, so only dials and sliders offer them; not tied to the wired function.
            let deco = s["deco"].array.compactMap(\.string), moves = module.type == "dial" || module.type == "slider"
            if moves {
                Picker(L("LED 색"), selection: Binding(get: { s["deco"].string ?? (deco.count == 2 ? "custom" : "") }, set: { v in
                    update { if v.isEmpty { $0["deco"] = nil } else if v == "custom" { $0["deco"] = ["#2060ff", "#ffb020"] } else { $0["deco"] = v } }
                })) {
                    Text(L("단일색")).tag("")
                    Section(L("변하는 색 (빌트인)")) { ForEach(Engine.bands, id: \.id) { Text($0.name).tag($0.id) } }
                    Text(L("변하는 색 (사용자 정의)")).tag("custom")
                }.help(L("변하는 색: 돌리는 동안 값에 따라 모든 LED 색이 변하고, 멈추면 아래 색으로 돌아옴"))
            }
            HStack {
                ColorPicker(moves ? L("색") : L("LED 색"), selection: Binding(get: { Color(hex: s["color"].string ?? "#000000") }, set: { c in update { $0["color"] = c.hex } }), supportsOpacity: false)
                Button(L("기본")) { update { $0["color"] = "#000000" } }.disabled((s["color"].string ?? "#000000") == "#000000")
                    .help(L("#000000 = 기본 흰색"))
            }
            if deco.count == 2 {
                HStack {
                    ColorPicker(L("낮은 값"), selection: Binding(get: { Color(hex: deco[0]) }, set: { c in update { $0["deco"] = [c.hex, deco[1]] } }), supportsOpacity: false)
                    ColorPicker(L("높은 값"), selection: Binding(get: { Color(hex: deco[1]) }, set: { c in update { $0["deco"] = [deco[0], c.hex] } }), supportsOpacity: false)
                }
            }
            if module.type == "button" {
                // 켜짐 방식 belongs to the whole module (its buttons act as one group), so it is saved on the module, not this button
                let parent = module.uuid.components(separatedBy: "::")[0], pa = service.assignment(parent)
                Picker(L("LED 켜짐 방식 (모듈)"), selection: Binding(get: { pa["settings"]["buttonMode"].string ?? "each" }, set: { v in
                    var st = pa["settings"].any as? [String: Any] ?? [:]; st["buttonMode"] = v == "each" ? nil : v
                    service.dispatch("ASSIGN_MODULE", ["uuid": parent, "assignment": ["app": pa["app"].string ?? "", "preset": pa["preset"].string ?? "", "settings": st]])
                })) { Text(L("버튼")).tag("each"); Text(L("토글")).tag("toggle"); Text(L("옵션")).tag("one") }
                    .help(L("버튼: 누를 때마다 실행, LED는 기본 색 · 토글: 누르면 켜지고 다시 누르면 꺼짐 · 옵션: 이 모듈에서 누른 버튼만 켜짐. 켤 때 = '누름', 끌 때 = '끌 때'에 연결한 기능"))
                Picker(L("길게 누르기"), selection: Binding(get: { s["holdDelay"].int ?? 500 }, set: { v in update { $0["holdDelay"] = v } })) {
                    Text(L("0.3초")).tag(300); Text(L("0.5초")).tag(500); Text(L("0.8초")).tag(800)
                }.pickerStyle(.segmented)
                Toggle(L("길게 누르면 반복"), isOn: Binding(get: { s["autorepeat"].bool ?? false }, set: { v in update { $0["autorepeat"] = v } }))
            }
            if module.type == "orbiter" { // the Core shapes tilt itself from these (0xB2/0xB5); turnSensitivity is the ring's tick threshold
                LabeledContent(L("기울기 감도")) {
                    Slider(value: Binding(get: { Double(s["tiltSensitivity"].int ?? 3) }, set: { v in update { $0["tiltSensitivity"] = Int(v) } }), in: 1...5, step: 1)
                    Text("\(s["tiltSensitivity"].int ?? 3)").monospacedDigit().frame(width: 16)
                }
                Picker(L("축 혼합"), selection: Binding(get: { s["tiltMode"].int ?? 1 }, set: { v in update { $0["tiltMode"] = v } })) {
                    Text(L("큰 축만")).tag(0); Text(L("축에 스냅")).tag(1); Text(L("그대로")).tag(2)
                }
                LabeledContent(L("데드존")) {
                    Slider(value: Binding(get: { Double(s["tiltDeadzone"].int ?? 0) }, set: { v in update { $0["tiltDeadzone"] = Int(v) } }), in: 0...50, step: 5)
                    Text("\(s["tiltDeadzone"].int ?? 0)%").monospacedDigit().frame(width: 32)
                }.help(L("이 비율 아래의 기울기는 무시 (손 떨림 제거)"))
                LabeledContent(L("안정화")) {
                    Slider(value: Binding(get: { Double(s["tiltSmoothing"].int ?? 0) }, set: { v in update { $0["tiltSmoothing"] = Int(v) } }), in: 0...90, step: 10)
                    Text("\(s["tiltSmoothing"].int ?? 0)%").monospacedDigit().frame(width: 32)
                }.help(L("기울기 값을 부드럽게 따라감 (높을수록 느리고 안정적)"))
                LabeledContent(L("링 감도")) {
                    Slider(value: Binding(get: { Double(s["turnSensitivity"].int ?? 9) }, set: { v in update { $0["turnSensitivity"] = Int(v) } }), in: 1...9, step: 1)
                    Text("\(s["turnSensitivity"].int ?? 9)").monospacedDigit().frame(width: 16)
                }
            }
            if module.type == "dial" {
                LabeledContent(L("감도")) {
                    Slider(value: Binding(get: { Double(s["sensitivity"].int ?? 9) }, set: { v in update { $0["sensitivity"] = Int(v) } }), in: 1...9, step: 1)
                    Text("\(s["sensitivity"].int ?? 9)").monospacedDigit().frame(width: 16)
                }
                if !s["turn"].isNull {
                    Toggle(L("회전 방향 반전"), isOn: Binding(get: { s["turn"]["invert"].bool ?? false },
                                                 set: { v in update { var t = $0["turn"] as? [String: Any] ?? [:]; t["invert"] = v; $0["turn"] = t } }))
                    if let step = s["turn"]["step"].double {
                        LabeledContent(L("한 틱당 변화")) {
                            NumField(value: Binding(get: { step }, set: { v in update { var t = $0["turn"] as? [String: Any] ?? [:]; t["step"] = v; $0["turn"] = t } })).frame(width: 70).multilineTextAlignment(.trailing)
                        }
                    }
                    RangeFields(value: s["turn"], slot: "turn", appId: appId) { r in update { var t = $0["turn"] as? [String: Any] ?? [:]; t["range"] = r; $0["turn"] = t } }
                }
            }
            if module.type == "slider" {
                RangeFields(value: s["pose"], slot: "pose", appId: appId) { r in update { var t = $0["pose"] as? [String: Any] ?? [:]; t["range"] = r; $0["pose"] = t } }
            }
        }
        .formStyle(.grouped).scrollDisabled(true)
        // fixed height (the form does not scroll): about 40 per row; the LED 색 kind row and the two custom-color row count too
        .frame(height: (module.type == "dial" ? 276 : module.type == "orbiter" ? 316 : module.type == "button" ? 236 : module.type == "slider" ? 156 : 116) + (assignment["settings"]["deco"].array.count == 2 ? 40 : 0)
               + (RangeFields.defaults(service, assignment["settings"][module.type == "slider" ? "pose" : "turn"], module.type == "slider" ? "pose" : module.type == "dial" ? "turn" : "", appId) == nil ? 0 : 40))
    }
    private var appId: String { assignment["app"].string ?? "" }
}

/// 값 범위 (하한 ~ 상한) of one wire. Empty fields = the function's default range (shown as the placeholder); stored as the wire's `range` only when it differs.
struct RangeFields: View {
    @EnvironmentObject private var service: ServiceClient
    let value: JSON, slot: String, appId: String
    let write: ([Double]?) -> Void

    /// The function's default range, or nil when this wire has no range to edit.
    /// Every plugin line carries the wire's range, so a dial offers it as a slider does.
    static func defaults(_ service: ServiceClient, _ value: JSON, _ slot: String, _ appId: String) -> [Double]? {
        // a wire made in the wiring screen stores app "" (= the profile's app)
        let app = service.app(id: [value["app"].string, appId, service.activeProfile?["app"].string].compactMap { $0 }.first { !$0.isEmpty } ?? "")
        let def = app?["inputs"][value["input"].string ?? ""]["range"].array.compactMap(\.double) ?? []
        guard def.count == 2 else { return nil }
        return def
    }
    var body: some View {
        if let def = Self.defaults(service, value, slot, appId) {
            let cur = value["range"].array.compactMap(\.double)
            LabeledContent(L("값 범위")) { HStack(spacing: 4) { field(0, cur, def); Text("~"); field(1, cur, def) } }
        }
    }
    private func field(_ i: Int, _ cur: [Double], _ def: [Double]) -> some View {
        NumField(value: Binding<Double?>(get: { cur.count == 2 ? cur[i] : nil }, set: { v in
            var r = cur.count == 2 ? cur : def
            r[i] = v ?? def[i]
            if r[0] < r[1] { write(r == def ? nil : r) } // an upside-down range is ignored
        }), prompt: def[i].formatted()).frame(width: 70).multilineTextAlignment(.trailing)
    }
}

/// 동작별 할당 표: one row per setting slot of the control. A slot's value lives in the assignment's settings, so replacing one
/// overrides only that slot of the preset; 원래대로 copies the shipped preset's value back.
/// Slot names and the short text of a slot value (shared by the 연결 화면 and the pickers).
@MainActor enum SlotText {

    static var names: [String: String] { ["press": L("누름"), "doublePress": L("더블클릭"), "pressAndHold": L("길게"), "pressDown": L("누를 때"), "pressUp": L("뗄 때"), "pressOff": L("끌 때"),
                        "turn": L("회전"), "pressAndTurn": L("누르고 회전"), "leftTurn": L("왼쪽 회전"), "rightTurn": L("오른쪽 회전"),
                        "pressAndLeftTurn": L("누르고 왼쪽"), "pressAndRightTurn": L("누르고 오른쪽"), "doubleTap": L("더블탭"), "pose": L("위치"), "tiltX": L("기울기 ↔"), "tiltY": L("기울기 ↕")] } // computed: follows the language
    static let basic: Set<String> = ["press", "doublePress", "pressAndHold", "turn", "pressAndTurn", "doubleTap", "tiltX", "tiltY"]
    static let modSymbols = Engine.modSymbols
    private static var appTitles: [String: String?] = [:]
    /// Name of an installed app by bundle id (asked once per id); nil = not on this Mac.
    static func appTitle(_ bundle: String) -> String? {
        if let t = appTitles[bundle] { return t }
        let t = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        appTitles[bundle] = t; return t
    }
    static func panelName(_ p: String, service: ServiceClient) -> String {
        switch p {
        case "profiles": return L("프로필 전환 패널")
        case "pages": return L("페이지 고르기 패널")
        case "map": return L("맵 보기")
        case _ where p.hasPrefix("stack:"): return service.stackLabel(String(p.dropFirst(6)), member: false) + L(" 고르기 패널")
        default: return L("패널: ") + p.dropFirst(5)
        }
    }

    /// Wire badge: a nudge's step and direction.
    static func badge(_ v: JSON) -> String? { v["step"].double.map { (v["invert"].bool == true ? "∓" : "±") + $0.formatted() } }

    /// Short text for a slot value: preset label when the input names one, key chord, page name, else the raw input.
    static func describe(_ v: JSON, service: ServiceClient, appId: String, presetApp: String) -> String {
        let apps = [appId, presetApp, ""]
        if let s = v.string { return label(for: s, service: service, apps: apps) }
        if case .array = v { return label(for: v[0].string ?? "", service: service, apps: apps) + (v[1].string.map { " (\($0))" } ?? "") }
        if case .array(let ab) = v["alternate"], ab.count == 2 { return ab.map { describe($0, service: service, appId: appId, presetApp: presetApp) }.joined(separator: " ⇄ ") }
        if let b = v["open"].string { return appTitle(b).map { L("열기: ") + $0 } ?? L("찾을 수 없음: ") + b }
        if let n = v["shortcut"].string { return (service.shortcutNames?.contains(n) ?? true ? L("단축어: ") : L("찾을 수 없음: ")) + n } // a renamed shortcut stays wired and says so
        if let t = v["text"].string { return L("글자: ") + t.prefix(24) }
        if let p = v["panel"].string { return panelName(p, service: service) }
        if let l = v["send"].string { return v["name"].string ?? l }
        if let id = v["keys"].string { return Keymap.find(id)?.label ?? L("찾을 수 없음: ") + id }
        if let k = v["key"].string { return v["modifiers"].array.compactMap { Self.modSymbols[$0.string ?? ""] }.joined() + k.uppercased() }
        if let t = v["dispatch"]["type"].string { return dispatchName(t, service: service) }
        if let t = v["ui"]["type"].string { return t == "SHOW_LAYOUT_PREVIEW" ? L("앱 창 보이기") : t == "HIDE_LAYOUT_PREVIEW" ? L("앱 창 숨기기 (무시됨)") : t }
        if case .array(let m) = v["macro"] { return L("매크로 \(m.count)단계") }
        if let i = v["input"].string { return label(for: i, service: service, apps: apps) + (v["action"].string.map { " (\($0))" } ?? "") }
        if !v["mac"].isNull { return describe(v["mac"], service: service, appId: appId, presetApp: presetApp) }
        return "{…}"
    }
    private static func label(for input: String, service: ServiceClient, apps: [String]) -> String {
        for id in apps {
            for type in ["button", "dial", "slider", "orbiter"] {
                if let p = service.app(id: id)?["presets"][type].array.first(where: { $0["name"].string == input }), let l = p["label"].string { return l }
            }
        }
        return input.trimmingCharacters(in: .whitespaces)
    }
    private static func dispatchName(_ t: String, service: ServiceClient) -> String {
        func title(_ id: Substring) -> String { service.profiles.first { $0["id"].string == String(id) }?["title"].string ?? "?" }
        switch t {
        case "NEXT_SCREEN": return "Next Page"
        case "PREVIOUS_SCREEN": return "Previous Page"
        case "NEXT_PROFILE": return L("다음 프로필")
        case "PREVIOUS_PROFILE": return L("이전 프로필")
        case "PROFILE_SWITCHER": return L("프로필 전환 패널")
        case "PLAY_SCENE": return L("장면 재생")
        case "TOGGLE_MAP": return L("상시 맵 켜기/끄기")
        case _ where t.hasPrefix("ACTIVATE_PROFILE:"): return title(t.dropFirst(17)) + L(" 페이지로")
        case _ where t.hasPrefix("ACTIVATE_BUNDLE:"): return L("프로필 묶음: ") + service.appName(String(t.dropFirst(16)))
        case _ where t.hasPrefix("HOLD_SCREEN:"): return L("누르는 동안 · ") + title(t.dropFirst(12))
        case _ where t.hasPrefix("STACK_NEXT:"): return service.stackLabel(String(t.dropFirst(11)), member: false) + L(" › 다음 모듈")
        case _ where t.hasPrefix("STACK:"): return service.stackLabel(String(t.dropFirst(6)), member: true)
        case _ where t.hasPrefix("HOLD_STACK:"): return L("누르는 동안 · ") + service.stackLabel(String(t.dropFirst(11)), member: true)
        case _ where t.hasPrefix("HOLD_STACK_NEXT:"): return L("누르는 동안 · ") + service.stackLabel(String(t.dropFirst(16)), member: false) + L(" › 다음 모듈")
        default: return t
        }
    }
}

/// Picks one slot's value: this app's presets, 공통, a recorded key chord, or a page of the 묶음.
struct SlotPicker: View {
    @EnvironmentObject var service: ServiceClient
    let module: Module
    let slot: String
    let appId: String
    let pick: (Any?) -> Void   // nil = 비우기
    var also: ((String, Any) -> Void)? = nil // wires another slot of the same control (the opposite turn of a named shortcut)
    @State private var tab = 0
    @State private var search = ""
    @State private var chord: (key: String, mods: [String])?
    @State private var typed = ""
    @State private var apps: [(id: String, name: String)] = []
    @State private var keysApp: String?   // 키 입력 tab's app; nil = this profile's app when it has a list, else 공통
    @State private var rekey: String?     // item being re-keyed
    @State private var newName = ""
    @State private var newOpposite = ""
    @State private var offer: (item: Keymap.Item, slot: String)?
    private var pulse: Bool { !["turn", "pressAndTurn", "pose", "tiltX", "tiltY"].contains(slot) }

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $tab) {
                if !appId.isEmpty { Text(service.appName(appId)).tag(0) }
                Text(L("공통")).tag(1); Text(L("키 입력")).tag(2); Text(L("실행")).tag(5); Text(L("페이지")).tag(3); Text(L("스택")).tag(4); Text(L("패널")).tag(6)
            }.pickerStyle(.segmented).labelsHidden()
            switch tab {
            case 2: keyEntry
            case 3: pages
            case 4: stackItems
            case 5: runItems
            case 6: panelItems
            default: presets(tab == 1 ? "" : appId)
            }
            Button(L("비우기"), role: .destructive) { pick(nil) }.controlSize(.small)
        }.padding().onAppear { if appId.isEmpty { tab = 1 } }
    }

    /// Presets of this module type that fill this slot. A pulse slot (press, double, hold…) takes any one-shot action:
    /// this type's press/doubleTap values and every button preset's press (a dial press can do what a button does).
    static func items(_ service: ServiceClient, app: String, type: String, slot: String) -> [(label: String, value: JSON)] {
        let pulse = !["turn", "pressAndTurn", "pose", "tiltX", "tiltY"].contains(slot)
        let presets = service.app(id: app)?["presets"] ?? .null
        var items: [(label: String, value: JSON)] = []
        var seen = Set<String>()
        func add(_ p: JSON, _ key: String) {
            let l = p["label"].string ?? p["name"].string ?? ""
            if !p[key].isNull, seen.insert(l).inserted { items.append((l, p[key])) }
        }
        for p in presets[type].array { add(p, slot); if pulse { add(p, "press"); add(p, "doubleTap") } }
        if pulse, type != "button" { for p in presets["button"].array { add(p, "press") } }
        if pulse, app.isEmpty { // 스택 바꾸기: found by 기능 찾기 like any 공통 function
            func item(_ t: String) { let v = JSON(any: ["dispatch": ["type": t]]); items.append((SlotText.describe(v, service: service, appId: "", presetApp: ""), v)) }
            for e in service.stackList {
                item("STACK_NEXT:" + e.host)
                if slot == "pressAndHold" { item("HOLD_STACK_NEXT:" + e.host) }
                for u in e.stack.members { item("STACK:" + u); if slot == "pressAndHold" { item("HOLD_STACK:" + u) } }
            }
            // 패널과 프로필 묶음도 공통 기능: listed here so the 공통 tab and 기능 찾기 find them (the 패널·페이지 tabs offer the same values)
            if slot == "pressAndHold" || (slot == "pressDown" && type == "dial") {
                func panel(_ k: String) { let v = JSON(any: ["panel": k]); items.append((SlotText.describe(v, service: service, appId: "", presetApp: ""), v)) }
                panel("profiles"); panel("pages"); panel("map")
                for e in service.stackList { panel("stack:" + e.host) }
                for n in service.panelLists.compactMap({ $0["name"].string }) { panel("list:" + n) }
            }
            if slot != "pressAndHold" { for a in service.profiles.map({ $0["app"].string ?? "" }).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } { item("ACTIVATE_BUNDLE:" + a) } }
        }
        if pulse { // what the plugin announced at run time (Lightroom: develop presets, by uuid: this Mac's)
            for f in service.functions(app) where seen.insert(f.label).inserted { items.append((f.label, JSON(any: ["send": f.line, "app": app, "name": f.label]))) }
        }
        return items
    }

    /// 실행: a shortcut of the Shortcuts app (by name) or an app (by bundle id). One-shot wires only.
    static func installedApps() -> [(id: String, name: String)] {
        let fm = FileManager.default
        var out: [String: String] = [:]
        for root in ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"] {
            for n in (try? fm.contentsOfDirectory(atPath: root)) ?? [] { // one folder deep: "Adobe Lightroom Classic/Adobe Lightroom Classic.app"
                let p = root + "/" + n
                let found = n.hasSuffix(".app") ? [p] : ((try? fm.contentsOfDirectory(atPath: p)) ?? []).filter { $0.hasSuffix(".app") }.map { p + "/" + $0 }
                for c in found { if let id = Foundation.Bundle(path: c)?.bundleIdentifier, out[id] == nil { out[id] = fm.displayName(atPath: c).replacingOccurrences(of: ".app", with: "") } }
            }
        }
        return out.map { (id: $0.key, name: $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    @ViewBuilder private var runItems: some View {
        if !pulse { Text(L("앱 열기와 단축어는 한 번 실행되는 연결(누름·더블클릭·길게)에만 걸 수 있습니다.")).foregroundStyle(.secondary); Spacer() }
        else {
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            VStack {
                TextField(L("검색"), text: $search).textFieldStyle(.roundedBorder)
                List {
                    Section(L("단축어")) {
                        if let names = service.shortcutNames {
                            ForEach(names.filter { search.isEmpty || $0.found(search) }, id: \.self) { n in Button(n) { pick(["shortcut": n]) } }
                            if names.isEmpty { Text(L("단축어 앱에 단축어가 없습니다")).foregroundStyle(.secondary) }
                        } else { Text(L("읽는 중…")).foregroundStyle(.secondary) }
                    }
                    Section(L("앱")) {
                        ForEach(apps.filter { search.isEmpty || $0.name.found(search) }, id: \.id) { a in
                            Button { pick(["open": a.id]) } label: { HStack { Text(a.name); Spacer(); if running.contains(a.id) { Text(L("실행 중")).font(.caption).foregroundStyle(.secondary) } }.contentShape(Rectangle()) }
                        }
                        Button(L("다른 앱 고르기…")) {
                            let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
                            if panel.runModal() == .OK, let u = panel.url, let id = Foundation.Bundle(url: u)?.bundleIdentifier { pick(["open": id]) }
                        }
                    }
                }.buttonStyle(.plain)
            }
            .onAppear {
                service.loadShortcuts()
                DispatchQueue.global().async { let a = Self.installedApps(); DispatchQueue.main.async { apps = a } }
            }
        }
    }
    /// 패널: held open by the control it is wired to, so only a slot that fires while the control is down can take one.
    private var panelItems: some View {
        let ok = slot == "pressAndHold" || (slot == "pressDown" && module.type == "dial")
        let lists = service.panelLists.compactMap { $0["name"].string }
        return List {
            if !ok { Text(L("패널은 버튼의 '길게'나 다이얼의 '누를 때'에 연결합니다. 누르고 있는 동안 뜨고, 다이얼은 누른 채 돌려서, 버튼은 다른 버튼으로 고른 뒤 놓으면 실행됩니다.")).foregroundStyle(.secondary) }
            else {
                Button(L("프로필 고르기")) { pick(["panel": "profiles"]) }
                Button(L("페이지 고르기 (이 프로필 묶음)")) { pick(["panel": "pages"]) }
                Button(L("맵 보기 (누르는 동안 판 구성과 기능 이름)")) { pick(["panel": "map"]) }
                if !service.stackList.isEmpty { Section(L("스택 층 고르기")) { ForEach(service.stackList, id: \.host) { e in Button(e.title) { pick(["panel": "stack:" + e.host]) } } } }
                Section(L("직접 만든 목록")) {
                    ForEach(lists, id: \.self) { n in Button(n) { pick(["panel": "list:" + n]) } }
                    if lists.isEmpty { Text(L("왼쪽 사이드바 아래 '패널 목록'에서 만드세요")).foregroundStyle(.secondary) }
                }
            }
        }.buttonStyle(.plain)
    }
    private func presets(_ app: String) -> some View {
        let items = Self.items(service, app: app, type: module.type, slot: slot)
        let shown = Array(items.filter { search.isEmpty || $0.label.found(search) }.enumerated())
        return VStack {
            TextField(L("검색"), text: $search).textFieldStyle(.roundedBorder)
            List(shown, id: \.offset) { item in Button(item.element.label) { pick(item.element.value.any) }.buttonStyle(.plain) }
        }
    }

    /// (51) 키 입력: the app's named shortcuts (Keymap). A row wires its name ({"keys": id}); re-keying it changes every wire
    /// that uses it. 직접 추가 records a new named item; the raw chord and 글자 입력 stay below as before.
    private var keyEntry: some View {
        let app = keysApp ?? (Keymap.apps.contains(appId) ? appId : "")
        let items = Keymap.items(app: app)
        let shown = items.filter { search.isEmpty || $0.label.found(search) || $0.chord.found(search) }
        let groups = shown.reduce(into: [String]()) { if !$0.contains(Self.group($1.label)) { $0.append(Self.group($1.label)) } }
        return VStack(spacing: 6) {
            HStack {
                Picker("", selection: Binding(get: { app }, set: { keysApp = $0; rekey = nil })) {
                    ForEach(Keymap.apps, id: \.self) { Text($0.isEmpty ? L("macOS 공통") : service.appName($0)).tag($0) }
                }.labelsHidden().fixedSize()
                TextField(L("검색"), text: $search).textFieldStyle(.roundedBorder)
            }
            if let o = offer, let opp = o.item.opposite.flatMap(Keymap.find) {
                HStack {
                    Text(L("\(SlotText.names[o.slot] ?? o.slot)에도 \(opp.label)?")).font(.callout).lineLimit(2)
                    Spacer()
                    Button(L("함께 연결")) { also?(o.slot, ["keys": opp.id]); pick(["keys": o.item.id]) }
                    Button(L("이것만")) { pick(["keys": o.item.id]) }
                }.controlSize(.small).padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
            }
            List {
                ForEach(groups, id: \.self) { g in
                    Section(g) { ForEach(shown.filter { Self.group($0.label) == g }, id: \.id) { keyRow($0, in: items) } }
                }
                Section(L("직접 추가")) {
                    TextField(L("이름 (예: Resolve.Node.Reset)"), text: $newName).textFieldStyle(.roundedBorder)
                    if rekey == nil { recorder }
                    Picker(L("반대 방향"), selection: $newOpposite) {
                        Text(L("없음")).tag("")
                        ForEach(items, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    HStack {
                        Button(L("목록에 추가")) {
                            guard let c = chord else { return }
                            var d: [String: Any] = ["label": newName, "key": c.key, "modifiers": c.mods]
                            if !newOpposite.isEmpty { d["opposite"] = newOpposite }
                            edit(app) { $0["user." + UUID().uuidString.prefix(8).lowercased()] = d }
                            newName = ""; newOpposite = ""; chord = nil
                        }.disabled(chord == nil || newName.trimmingCharacters(in: .whitespaces).isEmpty || rekey != nil)
                        Button(L("이름 없이 이 키로 할당")) { if let c = chord { pick(["key": c.key, "modifiers": c.mods]) } }.disabled(chord == nil || rekey != nil)
                    }
                    if pulse { // 글자 입력: the characters themselves, so Korean works whatever the input source is
                        HStack { TextField(L("또는 입력할 글자 (예: 저작권 문구)"), text: $typed).textFieldStyle(.roundedBorder); Button(L("이 글자로 할당")) { pick(["text": typed]) }.disabled(typed.isEmpty) }
                    }
                }
            }
            Text(L("그 앱이 앞에 있을 때 그 앱으로 입력됩니다. 키를 바꾸면 이 이름을 쓰는 모든 연결에 적용됩니다.")).font(.caption).foregroundStyle(.secondary)
        }
    }
    /// "Lrc.Photo.Next" → "Lrc.Photo"; a name without dots is its own group.
    static func group(_ label: String) -> String { let g = label.components(separatedBy: ".").dropLast().joined(separator: "."); return g.isEmpty ? L("기타") : g }
    @ViewBuilder private func keyRow(_ i: Keymap.Item, in items: [Keymap.Item]) -> some View {
        HStack(spacing: 6) {
            Button { choose(i) } label: {
                HStack(spacing: 6) {
                    Text(i.label.components(separatedBy: ".").last ?? i.label)
                    if i.changed { pill(L("변경됨"), .orange) } else if i.own { pill(L("직접 추가"), .blue) }
                    Spacer()
                    Text(i.chord).font(.caption.monospaced()).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button(L("키 바꾸기…")) { rekey = i.id; chord = nil }
                if i.changed { Button(L("기본값으로")) { edit(i.app) { $0[i.id] = nil } } }
                if i.own { Button(L("삭제"), role: .destructive) { edit(i.app) { $0[i.id] = nil } } }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
        }
        if rekey == i.id {
            VStack(alignment: .leading, spacing: 4) {
                recorder
                if let c = chord, let other = items.first(where: { $0.id != i.id && $0.key == c.key && Set($0.mods) == Set(c.mods) }) {
                    Text(L("같은 키를 \(other.label)도 씁니다")).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button(L("저장")) {
                        guard let c = chord else { return }
                        edit(i.app) { var d = $0[i.id] as? [String: Any] ?? [:]; d["key"] = c.key; d["modifiers"] = c.mods; if i.own { d["label"] = i.label; d["opposite"] = i.opposite }; $0[i.id] = d }
                        rekey = nil; chord = nil
                    }.disabled(chord == nil)
                    Button(L("취소")) { rekey = nil; chord = nil }
                }.controlSize(.small)
            }
        }
    }
    private func pill(_ t: String, _ c: Color) -> some View { Text(t).font(.caption2).padding(.horizontal, 5).background(Capsule().fill(c.opacity(0.2))) }
    /// A turn slot with an opposite item offers to wire the other direction too (event → one function each).
    private func choose(_ i: Keymap.Item) {
        let pairs = ["rightTurn": "leftTurn", "leftTurn": "rightTurn", "pressAndRightTurn": "pressAndLeftTurn", "pressAndLeftTurn": "pressAndRightTurn"]
        if also != nil, i.opposite.flatMap(Keymap.find) != nil, let other = pairs[slot] { offer = (i, other) } else { pick(["keys": i.id]) }
    }
    private func edit(_ app: String, _ f: (inout [String: Any]) -> Void) {
        var all = service.keymaps, mine = all[app] as? [String: Any] ?? [:]
        f(&mine); all[app] = mine.isEmpty ? nil : mine
        service.setKeymaps(all)
    }
    private var recorder: some View {
        Text(chord.map { $0.mods.compactMap { SlotText.modSymbols[$0] }.joined() + $0.key.uppercased() } ?? L("여기를 클릭한 뒤 키를 누르세요"))
            .font(.title3).frame(maxWidth: .infinity, minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
            .focusable()
            .onKeyPress { press in
                guard let key = Self.keyName(press.key) else { return .ignored }
                var mods: [String] = []
                if press.modifiers.contains(.command) { mods.append("command") }
                if press.modifiers.contains(.shift) { mods.append("shift") }
                if press.modifiers.contains(.option) { mods.append("alt") }
                if press.modifiers.contains(.control) { mods.append("control") }
                chord = (key, mods); return .handled
            }
    }
    /// KeyEquivalent → System.keyCodes name.
    static func keyName(_ k: KeyEquivalent) -> String? {
        let special: [KeyEquivalent: String] = [.upArrow: "up", .downArrow: "down", .leftArrow: "left", .rightArrow: "right", .return: "enter", .tab: "tab",
                                                .space: "space", .delete: "backspace", .deleteForward: "delete", .escape: "escape", .home: "home", .end: "end", .pageUp: "pageup", .pageDown: "pagedown"]
        if let s = special[k] { return s }
        let c = String(k.character).lowercased()
        return c.count == 1 && (c.first!.isLetter || c.first!.isNumber || "=-[]';,/.`\\".contains(c)) ? c : nil
    }

    /// 스택 바꾸기: attach one member of a stack on the board, or step to the next. The 길게 slot offers 누르는 동안 (back on release).
    private var stackItems: some View {
        func dispatch(_ t: String) -> [String: Any] { ["dispatch": ["type": t]] }
        let hold = slot == "pressAndHold"
        return List {
            if service.stackList.isEmpty { Text(L("스택이 없습니다. 판에서 모듈 모서리의 스택 아이콘을 눌러 2층에 모듈을 추가하세요.")).foregroundStyle(.secondary) }
            ForEach(service.stackList, id: \.host) { e in
                Section(e.title) {
                    Button(hold ? L("누르는 동안 · 다음 모듈") : L("다음 모듈")) { pick(dispatch((hold ? "HOLD_STACK_NEXT:" : "STACK_NEXT:") + e.host)) }
                    ForEach(Array(e.stack.members.enumerated()), id: \.element) { i, u in
                        Button((hold ? L("누르는 동안 · ") : "") + L("\(i + 1)번 ") + e.name(i)) { pick(dispatch((hold ? "HOLD_STACK:" : "STACK:") + u)) }
                    }
                }
            }
        }.buttonStyle(.plain)
    }

    /// Pages of the active profile's 묶음, plus Next/Previous Page. The 길게 slot offers 누르는 동안 (switch back on release).
    private var pages: some View {
        let app = service.activeProfile?["app"].string ?? ""
        let cur = service.activeProfile?["id"].string
        let pages = service.profiles.filter { $0["app"].string ?? "" == app && $0["id"].string != cur }
        func dispatch(_ t: String) -> [String: Any] { ["dispatch": ["type": t]] }
        return List {
            Button("Next Page") { pick(dispatch("NEXT_SCREEN")) }
            Button("Previous Page") { pick(dispatch("PREVIOUS_SCREEN")) }
            Button(L("장면 재생 (LED 쓸기)")) { pick(dispatch("PLAY_SCENE")) }
            Button(L("상시 맵 켜기/끄기")) { pick(dispatch("TOGGLE_MAP")) }
            if slot == "pressAndHold" { Button(L("프로필 전환 패널 (누른 채 다른 버튼·← →, 놓으면 선택)")) { pick(dispatch("PROFILE_SWITCHER")) } }
            Section(slot == "pressAndHold" ? L("누르는 동안 이 페이지") : L("이 페이지로")) {
                ForEach(pages, id: \.["id"].string) { p in
                    Button(p["title"].string ?? "") { pick(dispatch((slot == "pressAndHold" ? "HOLD_SCREEN:" : "ACTIVATE_PROFILE:") + (p["id"].string ?? ""))) }
                }
                if pages.isEmpty { Text(L("묶음에 다른 페이지가 없습니다")).foregroundStyle(.secondary) }
            }
            if slot != "pressAndHold" { // 프로필 묶음(앱)으로: also what a 패널 목록 item uses to jump to another app's profiles
                Section(L("이 프로필 묶음(앱)으로")) {
                    ForEach(service.profiles.map { $0["app"].string ?? "" }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }, id: \.self) { a in
                        Button(service.appName(a)) { pick(dispatch("ACTIVATE_BUNDLE:" + a)) }
                    }
                }
            }
        }.buttonStyle(.plain)
    }
}

// MARK: - Preferences

struct PreferencesView: View {
    /// A plugin's own starter profiles (its starter.json), added to the list; ⌘Z takes them back.
    @ViewBuilder private func starterButton(_ id: String) -> some View {
        if let s = service.app(id: id)?["starter"].any as? [String: Any], let n = (s["profiles"] as? [Any])?.count {
            Button(L("시작 프로필 추가")) { if service.importFile(s, replace: false, root: false) { pluginNote = L("프로필 \(n)개를 추가했습니다. 왼쪽 목록에서 확인하세요.") } }
                .help(L("이 플러그인이 권하는 프로필을 추가합니다. Core, 버튼 3개, Orbiter, 다이얼 3개 모듈 두 개 구성을 기준으로 만든 것입니다."))
        }
    }
    @EnvironmentObject var service: ServiceClient
    @Environment(\.dismiss) private var dismiss
    @AppStorage("alwaysOnTop") private var onTop = false
    @AppStorage("language") private var language = "" // "" system · "ko" · "en"
    @AppStorage("hideDock") private var hideDock = false
    @AppStorage("prefsTab") private var tab = 0 // 0 일반 · 1 조작 · 2 화면 표시 · 3 LED · 4 플러그인
    @State private var plugins = Catalog.installed
    @State private var pluginNote = ""

    var body: some View {
        VStack(spacing: 0) {
        Picker("", selection: $tab) { Text(L("일반")).tag(0); Text(L("조작")).tag(1); Text(L("화면 표시")).tag(2); Text("LED").tag(3); Text(L("플러그인")).tag(4) }
            .pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top])
        Form {
            if tab == 0 {
                Toggle(L("로그인 시 실행"), isOn: Binding(get: { SMAppService.mainApp.status == .enabled },
                                                   set: { on in _ = try? (on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()) }))
                Toggle(L("Dock에서 아이콘 숨기기"), isOn: $hideDock)
                    .onChange(of: hideDock) { _, on in NSApp.setActivationPolicy(on ? .accessory : .regular); NSApp.activate(ignoringOtherApps: true) } // activate: the switch drops our windows behind the others
                    .help(L("숨기면 메뉴 막대의 Knobtile 아이콘에서 창을 엽니다."))
                Picker(L("언어"), selection: $language) { Text(L("시스템 설정 따름")).tag(""); Text(verbatim: "한국어").tag("ko"); Text(verbatim: "English").tag("en") }
                    .onChange(of: language) { _, v in // AppleLanguages in the app's own defaults is what macOS reads at launch
                        if v.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") } else { UserDefaults.standard.set([v], forKey: "AppleLanguages") }
                    }
                    .help(L("바로 적용됩니다. macOS가 넣는 메뉴(파일·편집 등)는 다시 시작한 뒤 바뀝니다."))
                LabeledContent(L("자동 백업")) {
                    Button(L("백업 폴더 열기")) { try? FileManager.default.createDirectory(at: Store.backupsDir, withIntermediateDirectories: true); NSWorkspace.shared.open(Store.backupsDir) }
                }.help(L("앱을 시작할 때 하루 한 번 프로필 전체를 복사해 최근 14개를 둡니다. 되돌리기: 프로필 가져오기 → 그 날짜의 파일 → 모두 바꾸기"))
                LabeledContent(L("펌웨어"), value: L("\(service.firmware["currentVersion"].string ?? "-") / 최신 \(service.firmware["latestVersion"].string ?? "-")"))
            }
            if tab == 1 {
                toggle(L("활성 앱에 따라 프로필 자동 전환"), "autoProfileSwitchingEnabled")
                toggle(L("프로필을 옮기면 그 앱을 앞으로 (실행 중일 때만)"), "activateAppOnProfile")
                toggle(L("콘솔을 조작하면 프로필의 앱을 앞으로 (실행 중일 때만)"), "activateAppOnInput")
                    .help(L("Knobtile 창이나 다른 앱이 앞에 있어도, 노브·버튼을 쓰면 현재 프로필의 앱을 먼저 앞으로 가져온 뒤 기능을 실행합니다. 앱이 지정되지 않은 프로필에서는 아무 일도 하지 않습니다."))
                toggle(L("모드 전환 사용"), "modeSwitchingEnabled")
                Picker(L("더블클릭 간격"), selection: Binding(get: { service.preferences["doubleDelay"].int ?? 250 }, set: { service.dispatch("UPDATE_PREFERENCE", ["update": ["type": "doubleDelay", "value": $0]]) })) {
                    Text(L("0.2초")).tag(200); Text(L("0.25초")).tag(250); Text(L("0.35초")).tag(350); Text(L("0.5초")).tag(500); Text(L("0.8초")).tag(800)
                }.help(L("두 번째 클릭을 기다리는 시간. 길수록 더블클릭이 쉽지만, 더블클릭이 연결된 버튼의 한 번 클릭이 그만큼 늦게 실행됨"))
            }
            if tab == 2 {
                toggle(L("값 알림 (컨트롤을 움직이면 기능 이름과 값을 화면 아래에 잠깐 표시)"), "osdValues")
                toggle(L("상시 맵 (판 구성과 기능 이름을 화면 모서리에 항상 표시 · ⌃⌥M)"), "mapPinned")
                Picker(L("상시 맵 위치"), selection: Binding(get: { service.preferences["mapCorner"].int ?? 3 }, set: { service.dispatch("UPDATE_PREFERENCE", ["update": ["type": "mapCorner", "value": $0]]) })) {
                    Text(L("왼쪽 위")).tag(0); Text(L("오른쪽 위")).tag(1); Text(L("오른쪽 아래")).tag(2); Text(L("왼쪽 아래")).tag(3)
                }
                LabeledContent(L("Core 화면 기준 각도")) {
                    HStack {
                        Text("\(service.preferences["screenRotation"].int ?? 0)°")
                        Button(L("90° 회전")) { service.dispatch("ROTATE_SCREEN") }.help(L("판이 0°일 때 Core 화면이 바로 보이도록 한 번 맞춥니다. 그 뒤로는 판의 전체 돌리기를 따라 돕니다."))
                    }
                }
                toggle(L("동적 색상"), "dynamicColorEnabled")
                Toggle(L("창을 항상 맨 위에"), isOn: $onTop).help(L("다른 앱을 쓰는 동안에도 Knobtile 창이 가려지지 않습니다."))
            }
            if tab == 3 {
                Section("LED") {
                    LabeledContent(L("밝기")) { Slider(value: ledNum("brightness", 100), in: 10...250, step: 10) { } minimumValueLabel: { Text("10") } maximumValueLabel: { Text("250") } }
                        .help(L("기본 100. 펌웨어의 최대값이 확인되지 않아 250까지 열어 둠: 100 위로 올려도 더 밝아지지 않으면 100이 최대"))
                    // 색 맞춤: per connected module, pull G/B down until an unassigned (white) LED looks white
                    ForEach(service.hardwarePaths.sorted { $0.key < $1.key }, id: \.value.u) { path, h in
                        let g = (service.preferences["led"]["balance"][h.u].any as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? Leds.neutral
                        LabeledContent(L("색 맞춤 · \(path.isEmpty ? "Core" : (LayoutView.typeNames[h.t & 0x1f] ?? L("모듈")) + " " + path)")) {
                            HStack(spacing: 4) {
                                ForEach(0..<3, id: \.self) { i in
                                    Text(["R", "G", "B"][i]).font(.caption).foregroundStyle([Color.red, .green, .blue][i])
                                    Slider(value: Binding(get: { g.count == 3 ? g[i] : Leds.neutral[i] }, set: { v in
                                        var n = g.count == 3 ? g : Leds.neutral; n[i] = v
                                        var all = (service.preferences["led"]["balance"].any as? [String: Any]) ?? [:]; all[h.u] = n; setLed("balance", all)
                                    }), in: 0.05...1).frame(width: 70)
                                }
                                Button(L("기본")) { var all = (service.preferences["led"]["balance"].any as? [String: Any]) ?? [:]; all[h.u] = nil; setLed("balance", all) }
                            }
                        }
                    }
                    Picker(L("야간 밝기 (22–07시)"), selection: ledNum("night", 0)) { Text(L("끔")).tag(0.0); Text("40 %").tag(40.0); Text("20 %").tag(20.0) }
                    Picker(L("유휴"), selection: ledNum("idleMinutes", 5)) { Text(L("1분")).tag(1.0); Text(L("5분")).tag(5.0); Text(L("15분")).tag(15.0); Text(L("30분")).tag(30.0) }
                    Picker(L("유휴 때"), selection: ledStr("idleMode", "dim")) { Text(L("유지")).tag("keep"); Text(L("어둡게")).tag("dim"); Text(L("별빛")).tag("starlight"); Text(L("숨쉬기")).tag("breathe") }
                    ledToggle(L("앱이 앞에 없으면 감광"), "awayDim")
                }
                Section(L("LED 장면")) {
                    ledToggle(L("Core 연결 · 체인 흐름"), "boot")
                    ledToggle(L("앱 전환 · 웰컴 쓸기 (페이지 색 또는 앱 아이콘 색)"), "welcome")
                    ledToggle(L("페이지 전환 · 파도"), "page")
                    ledToggle(L("누름 플래시"), "pressFlash")
                    ledToggle(L("누르는 동안 페이지 · 숨쉬기"), "holdBreathe")
                    ledToggle(L("조작 물결"), "ripple")
                    ledToggle(L("모듈 꽂기 · 물결"), "plug")
                    ledToggle(L("정시 · 시 수만큼 별빛"), "hourly")
                    Text(L("색 메시지는 80 ms에 최대 8개. 앱이 꺼지면 효과도 멈춥니다.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if tab == 4 { // like Lightroom's plug-in manager: a list, 추가, 제거. The engine reads plugins once at launch, hence 다시 시작.
                Section(L("설치된 플러그인")) {
                    LabeledContent("System") { HStack { starterButton(""); Text(L("기본")).foregroundStyle(.secondary) } }
                    ForEach(plugins, id: \.dir) { p in
                        LabeledContent(p.name) {
                            HStack {
                                if service.app(id: p.id) == nil { Text(L("다시 시작하면 적용")).font(.caption).foregroundStyle(.secondary) }
                                starterButton(p.id)
                                Button(L("제거"), role: .destructive) { try? FileManager.default.trashItem(at: p.dir, resultingItemURL: nil); plugins = Catalog.installed; pluginNote = L("다시 시작하면 적용됩니다.") }
                            }
                        }
                    }
                    HStack {
                        Button(L("추가…")) {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
                            panel.message = L("플러그인 폴더(plugin.json이 들어 있는 폴더)를 고르세요.")
                            guard panel.runModal() == .OK else { return }
                            let bad = panel.urls.filter { Catalog.install($0) == nil }.map(\.lastPathComponent)
                            plugins = Catalog.installed
                            pluginNote = bad.isEmpty ? L("다시 시작하면 적용됩니다.") : L("플러그인이 아닙니다: \(bad.joined(separator: ", "))")
                        }
                        Button(L("폴더 열기")) { try? FileManager.default.createDirectory(at: Catalog.userDir, withIntermediateDirectories: true); NSWorkspace.shared.open(Catalog.userDir) }
                        Spacer()
                        Button(L("Knobtile 다시 시작")) { // the new copy starts after this one has let go of the serial port
                            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", "sleep 1; open \"$0\"", Bundle.main.bundlePath]
                            try? p.run(); NSApp.terminate(nil)
                        }
                    }
                    if !pluginNote.isEmpty { Text(pluginNote).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        }
        .frame(width: 480, height: 640)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("닫기")) { dismiss() } } }
    }

    // preferences["led"] is one dictionary; each control rewrites it with its key changed.
    private func setLed(_ key: String, _ value: Any) {
        var d = (service.preferences["led"].any as? [String: Any]) ?? [:]; d[key] = value
        service.dispatch("UPDATE_PREFERENCE", ["update": ["type": "led", "value": d]])
    }
    private func led(_ key: String) -> JSON { let v = service.preferences["led"][key]; return v.isNull ? JSON(any: Engine.ledDefaults[key] ?? NSNull()) : v }
    private func ledNum(_ key: String, _ def: Double) -> Binding<Double> { Binding(get: { led(key).double ?? def }, set: { setLed(key, $0) }) }
    private func ledStr(_ key: String, _ def: String) -> Binding<String> { Binding(get: { led(key).string ?? def }, set: { setLed(key, $0) }) }
    private func ledToggle(_ label: String, _ key: String) -> some View { Toggle(label, isOn: Binding(get: { led(key).bool ?? false }, set: { setLed(key, $0) })) }

    // The update type is the preference key itself (service constants are camelCase keys).
    private func toggle(_ label: String, _ key: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { service.preferences[key].bool ?? false },
            set: { service.dispatch("UPDATE_PREFERENCE", ["update": ["type": key, "value": $0]]) }))
    }
}

extension String {
    /// 기능 찾기: plain substring, or the words' first letters ("mh" finds "Midtones Hue", "cgs" finds "Color Grading … Shadows").
    func found(_ q: String) -> Bool {
        if localizedCaseInsensitiveContains(q) { return true }
        let k = q.lowercased().filter { $0.isLetter || $0.isNumber }
        guard k.count >= 2 else { return false }
        let initials = String(split { !($0.isLetter || $0.isNumber) }.compactMap(\.first)).lowercased()
        var i = initials.startIndex // letters in order, gaps allowed: "cgs" skips the words in between
        for ch in k { guard let j = initials[i...].firstIndex(of: ch) else { return false }; i = initials.index(after: j) }
        return true
    }
}

extension Color {
    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
    init(hex: String) {
        var s = hex; if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}


/// The board and the 연결 화면 sidebar side by side, with the draggable edge between them. The width being dragged lives here, not in
/// ContentView: a state change there re-evaluated the whole window on every step (about 25 ms each), which made both sidebars' edges stutter.
struct SidebarSplit<Left: View, Right: View>: View {
    let left: Left, right: Right?
    @AppStorage("wiringWidth") private var saved = 520.0
    @State private var drag: Double?        // while dragging: the saved width (UserDefaults, observed app-wide) is written once at the end
    @State private var atDragStart: Double?
    // 460 is what the sidebar's content needs: with a lower floor the saved width went below what was drawn and the first part of a drag changed nothing
    private static var floor: Double { 460 }

    var body: some View {
        GeometryReader { g in
            let width = min(max(drag ?? saved, Self.floor), max(Self.floor, g.size.width * 0.6)) // the board keeps 40 % however wide the sidebar was dragged
            HStack(spacing: 0) {
                left.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                if let right {
                    // a 1 pt line with a 14 pt grab zone over both neighbours, like the left sidebar's edge; zIndex keeps the zone above the sidebar drawn after it
                    Divider().overlay { Color.clear.frame(width: 14).contentShape(Rectangle())
                        .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in let s = atDragStart ?? width; atDragStart = s; drag = min(max(s - v.translation.width, Self.floor), 900) } // starts from the width on screen
                            .onEnded { _ in atDragStart = nil; if let d = drag { saved = d }; drag = nil }) }.zIndex(1)
                    right.frame(width: width).transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.2), value: right == nil)
        }
        // debug: {"sweep": seconds, "out": file} drags the edge back and forth by itself and writes how many steps per second were reached (profiling without a mouse)
        .onReceive(snapshotNotes) { n in
            guard let secs = (n.userInfo?["sweep"] as? String).flatMap(Double.init) else { return }
            let t0 = Date(); var ticks = 0
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { t in
                ticks += 1; let p = Date().timeIntervalSince(t0) / secs
                if p >= 1 { drag = nil; t.invalidate(); try? "\(ticks) ticks in \(secs) s".write(toFile: n.userInfo?["out"] as? String ?? "/dev/null", atomically: true, encoding: .utf8) }
                else { drag = 460 + 440 * abs(sin(p * .pi * 3)) }
            }
        }
    }
}
/// Number field that writes only on Return or when focus leaves.
/// TextField(value:format:) writes on every keystroke, so "0." became 0 and the point could not be typed.
struct NumField: View {
    @Binding var value: Double?
    var prompt = ""
    @State private var text = ""
    @FocusState private var focused: Bool
    private var shown: String { value.map { $0.formatted(.number.grouping(.never).precision(.fractionLength(0...6))) } ?? "" }
    var body: some View {
        TextField("", text: $text, prompt: Text(prompt))
            .focused($focused)
            .onAppear { text = shown }
            .onChange(of: value) { text = shown }
            .onChange(of: focused) { _, f in if !f { commit() } }
            .onSubmit(commit)
    }
    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        if t.isEmpty { if value != nil { value = nil } }
        else if let v = Double(t), v.isFinite { if v != value { value = v } }
        else { text = shown } // not a number: back to the stored value
    }
}

extension EnvironmentValues {
    /// 보조 디스플레이 only: no grey fill behind the control in use (the board shows it as a flashing block, 2026-11-17).
    @Entry var noActiveFill = false
}
