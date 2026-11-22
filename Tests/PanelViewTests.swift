import XCTest
import SwiftUI
@testable import Engine
@testable import Knobtile

/// The screen panel's three shapes lay out without a device: icon strip, rows with notes, 맵 보기. Writes PNGs to look at when changing them.
final class PanelViewTests: PluginCase {
    @MainActor func testPanelShapesRender() throws {
        let service = ServiceClient()
        func shot(_ name: String, _ size: NSSize?) throws {
            let v = NSHostingView(rootView: SwitcherView().environmentObject(service).environmentObject(service.live))
            v.frame = NSRect(origin: .zero, size: size ?? v.fittingSize); v.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(v.frame.width, 100, name)
            let rep = try XCTUnwrap(v.bitmapImageRepForCachingDisplay(in: v.bounds))
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("knobtile-panel-\(name).png"))
        }
        service.panel = .init(kind: "pages", title: "Lightroom Classic", items: ["라이브러리", "현상", "내보내기"].map { .init(label: $0) }, index: 1)
        try shot("strip", nil)
        service.panel = .init(kind: "list:자주 쓰는 것", title: "자주 쓰는 것", items: [.init(label: "열기: DaVinci Resolve", note: "앱"), .init(label: "단축어: 다크 모드 전환", note: "단축어"), .init(label: "화면 일부 캡처", note: "⇧⌘4")], index: 2)
        try shot("rows", nil)
        service.panel = .init(kind: "map", title: "프로필", items: [], index: 0)
        try shot("map", NSSize(width: 900, height: 560))
    }

    /// A first run (no state file, no device) lays out: the main window with its one empty profile, and 환경설정 › 플러그인 with the starter buttons.
    @MainActor func testFirstRunRenders() throws {
        let service = ServiceClient(), e = Engine(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("mc-first-\(UUID().uuidString).json"))
        service.engine = e
        service.profiles = e.store.profiles.map(JSON.init(any:)); service.apps = e.catalog.raw.map(JSON.init(any:))
        XCTAssertEqual(service.profiles.count, 1)
        // a function of an app without a plugin: the "plugin missing" line must show above the board
        e.store.assign("m::button1", ["app": "", "preset": "", "settings": ["press": ["input": "x", "app": "com.example.none"]]])
        service.profiles = e.store.profiles.map(JSON.init(any:))
        XCTAssertTrue(service.missingPlugin(service.activeProfile))
        UserDefaults.standard.set(4, forKey: "prefsTab")
        for (name, view, size) in [("main", AnyView(ContentView()), NSSize(width: 1100, height: 640)), ("plugins", AnyView(PreferencesView()), NSSize(width: 560, height: 420))] {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false) // a split view lays out only inside a window
            let v = NSHostingView(rootView: view.environmentObject(service).environmentObject(service.live))
            w.contentView = v; v.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date() + 0.5)
            let rep = try XCTUnwrap(v.bitmapImageRepForCachingDisplay(in: v.bounds))
            v.cacheDisplay(in: v.bounds, to: rep)
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("knobtile-first-\(name).png")
            try rep.representation(using: .png, properties: [:])?.write(to: out); print("PNG", out.path)
        }
    }

    /// 패널 목록 편집 사이드바 lays out with a list in it (rows, nodes, finder, dock).
    @MainActor func testPanelListSidebarRenders() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-view-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["profiles": [["id": "p1", "title": "하나", "app": "", "tags": [], "lastActivated": 2, "assignments": [:] as [String: Any]]], "preferences": [:] as [String: Any]]).write(to: url)
        let service = ServiceClient()
        service.engine = Engine(storeURL: url)
        service.setPanelLists([["name": "자주 쓰는 것", "items": [["key": "4", "modifiers": ["shift", "command"], "label": "캡처", "fn": "키 입력 ⇧⌘4"], ["open": "com.apple.Safari", "label": "열기: Safari"], ["shortcut": "다크 모드", "label": "단축어: 다크 모드"]]]])
        XCTAssertEqual(service.panelLists.count, 1)
        let v = NSHostingView(rootView: PanelWiringView(name: "자주 쓰는 것").environmentObject(service).environmentObject(service.live))
        v.frame = NSRect(x: 0, y: 0, width: 520, height: 640); v.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("knobtile-panel-list-sidebar.png")
        try rep.representation(using: .png, properties: [:])?.write(to: out)
        print("PNG", out.path)
    }

    /// 상시 맵 lays out small (400 x 330) from the starter bundle's 현상 page, and TOGGLE_MAP flips its preference.
    @MainActor func testPinnedMapRenders() throws {
        let bundle = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Plugins/lightroom/starter.ko.json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: bundle)) as? [String: Any])
        var profiles = try XCTUnwrap(state["profiles"] as? [[String: Any]])
        for i in profiles.indices where profiles[i]["title"] as? String == "현상" { profiles[i]["lastActivated"] = 9999 }
        state["profiles"] = profiles; state["preferences"] = [:] as [String: Any]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-map-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        let service = ServiceClient(), e = Engine(storeURL: url)
        service.engine = e
        service.profiles = e.store.profiles.map(JSON.init(any:))
        XCTAssertEqual(service.activeProfile?["title"].string, "현상")
        e.dispatch("TOGGLE_MAP"); XCTAssertEqual(e.store.preferences["mapPinned"] as? Bool, true)
        e.dispatch("TOGGLE_MAP"); XCTAssertEqual(e.store.preferences["mapPinned"] as? Bool, false)
        let v = NSHostingView(rootView: MapView().environmentObject(service).environmentObject(service.live))
        v.frame = NSRect(x: 0, y: 0, width: 400, height: 330); v.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date() + 0.3) // the board fits itself after its first layout
        let rep = try XCTUnwrap(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("knobtile-pinned-map.png")
        try rep.representation(using: .png, properties: [:])?.write(to: out)
        print("PNG", out.path)
    }
}

/// 2026-11-16: a control wired while plugged in showed 미할당 once unplugged — the picked control still named the hardware uuid
/// while the board showed its module under the board id. The pick follows its board module.
final class UnplugPickTests: PluginCase {
    @MainActor func testPickedControlSurvivesUnplug() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-unplug-\(UUID().uuidString).json")
        let service = ServiceClient(), e = Engine(storeURL: url)
        service.engine = e
        let core: [String: Any] = ["u": "CORE", "t": 25, "i": 0]
        var plugged = core; plugged["c"] = [[:], [:], ["u": "HB", "t": 8, "i": 1]]
        e.store.hardware = ["": ("CORE", 25), "2": ("HB", 8)]; service.layout = JSON(any: plugged)
        e.store.assign("HB::button1", ["preset": "x"]) // applies the module to the profile
        service.layout = JSON(any: plugged)            // drop the memo like a store change would
        let m = try XCTUnwrap(service.modules().first { $0.uuid == "HB::button1" })
        XCTAssertNotNil(m.host)
        e.store.hardware = ["": ("CORE", 25)]; service.layout = JSON(any: core) // unplugged
        let r = try XCTUnwrap(service.refreshed(m))
        XCTAssertEqual(r.uuid, m.host! + "::button1")
        XCTAssertEqual(service.assignment(r.uuid)["preset"].string, "x")
        e.store.hardware = ["": ("CORE", 25), "2": ("HB", 8)]; service.layout = JSON(any: plugged) // back in
        XCTAssertEqual(service.refreshed(r)?.uuid, "HB::button1")
    }
}

/// 2026-11-16: a design module may lie on a plugged-in, unapplied module only with the same shape; a quarter-turned one must bounce back.
final class TurnedOverlapTests: PluginCase {
    @MainActor func testOnlySameShapeMayCoverTemp() throws {
        let e = Engine(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("mc-turn-\(UUID().uuidString).json"))
        let service = ServiceClient(); service.engine = e
        e.store.hardware = ["": ("CORE", 25), "2": ("HB", 8)]
        service.layout = JSON(any: ["u": "CORE", "t": 25, "i": 0, "c": [[:], [:], ["u": "HB", "t": 8, "i": 1]]] as [String: Any])
        let shown = service.shown, geo = Board(modules: shown.map(\.pose))
        let hw = try XCTUnwrap(shown.last { $0.link == .temp }).pose
        var same = hw; same.u = "v:x"; same.r = (hw.r + 2) % 4 // same shape, pins the other way: may lie there (shows red)
        XCTAssertTrue(LayoutView.fits(same, moving: nil, shown, geo))
        let turned = try XCTUnwrap((1...3).lazy.compactMap { r -> Pose? in var p = hw; p.u = "v:x"; p.r = (p.r + r) % 4; return p.w != hw.w && Board(modules: [p]).overlaps(hw) ? p : nil }.first)
        XCTAssertFalse(LayoutView.fits(turned, moving: nil, shown, geo))
        // plugged in after a different-shape design module was laid out: the design is red, the hardware still drawn as it is
        var b = e.store.board(e.store.activeProfile); b.modules.append(turned); e.store.setBoard(b)
        service.layout = JSON(any: ["u": "CORE", "t": 25, "i": 0, "c": [[:], [:], ["u": "HB", "t": 8, "i": 1]]] as [String: Any])
        XCTAssertEqual(service.shown.map(\.link).suffix(2), [.turned, .temp])
        XCTAssertEqual(service.shown.last?.pose.r, hw.r)
        let bi = b.modules.count - 1
        service.fixDirection(bi) // 문제 해결: turns the design (never the hardware) onto it, passing the same overlap rule
        service.layout = JSON(any: ["u": "CORE", "t": 25, "i": 0, "c": [[:], [:], ["u": "HB", "t": 8, "i": 1]]] as [String: Any])
        XCTAssertEqual(service.shown.map(\.link).suffix(1), [.connected])
        b = e.store.board(e.store.activeProfile)
        // the same shape covers it
        b.modules[b.modules.count - 1] = same; e.store.setBoard(b)
        service.layout = JSON(any: ["u": "CORE", "t": 25, "i": 0, "c": [[:], [:], ["u": "HB", "t": 8, "i": 1]]] as [String: Any])
        XCTAssertEqual(service.shown.map(\.link).last, .turned)
    }
}
