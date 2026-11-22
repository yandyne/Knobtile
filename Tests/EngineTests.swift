import XCTest
import AppKit
@testable import Engine

/// The app plugins are not inside the app: the tests read them from the repo's Plugins/ and never from this Mac's installed ones.
let repoPlugins = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Plugins")
class PluginCase: XCTestCase {
    /// The public repository carries only the lightroom plugin: a test of another plugin is skipped there.
    func need(_ plugins: String...) throws {
        for p in plugins where !FileManager.default.fileExists(atPath: repoPlugins.appendingPathComponent(p).path) { throw XCTSkip("plugin \(p) is not in this repository") }
    }
    override class func setUp() {
        if Catalog.dirs.last != repoPlugins { Catalog.dirs = [Catalog.dirs[0], repoPlugins]; Catalog.shared = Catalog() }
    }
}

final class EngineTests: PluginCase {
    func testLineFormat() {
        XCTAssertEqual(AppLink.line(input: "Exposure", operation: "+", params: [-0.1], range: [-5, 5]), "Exposure\t+\t-0.1\t-5.0\t5.0")
        XCTAssertEqual(AppLink.line(input: "Exposure", operation: "?", params: [], range: [-5, 5]), "Exposure\t?\t\t-5.0\t5.0")
        XCTAssertEqual(AppLink.line(input: "WhiteBalance = Auto", operation: "", params: [], range: nil), "WhiteBalance = Auto")
    }

    func testDialSensitivityAndPressTurn() {
        let rt = ModuleRuntime(Submodule(uuid: "d", kind: .dial, ledIndex: nil) { $0 })
        var turns: [Double] = [], events: [String] = []
        rt.settings = ["turn": { turns.append($0) }, "press": { _ in events.append("press") }, "pressAndTurn": { _ in events.append("pat") }, "rightTurn": { _ in events.append("right") }]
        rt.sensitivity = 8 // threshold 2 ticks
        rt.actuate([0, 1, 0], noop: false); XCTAssertEqual(turns, [])
        rt.actuate([0, 1, 0], noop: false); XCTAssertEqual(turns, [1]); XCTAssertEqual(events, ["right"])
        rt.actuate([0, -4, 0], noop: false); XCTAssertEqual(turns, [1, -2])
        rt.actuate([1, 0, 0], noop: false); rt.actuate([0, 0, 0], noop: false) // press + release without turning
        XCTAssertEqual(events.last, "press")
        rt.actuate([1, 0, 0], noop: true); XCTAssertEqual(events.count, 2) // state reports never execute
    }

    func testButtonSimplePress() {
        let rt = ModuleRuntime(Submodule(uuid: "b", kind: .button, ledIndex: nil) { $0 })
        var n = 0
        rt.settings = ["press": { _ in n += 1 }]
        rt.actuate([1], noop: false); XCTAssertEqual(n, 1) // fires on down
        rt.actuate([0], noop: false); XCTAssertEqual(n, 1)
        rt.simplePress = false
        rt.actuate([1], noop: false); XCTAssertEqual(n, 1)
        rt.actuate([0], noop: false); XCTAssertEqual(n, 2) // fires on up when hold handlers exist
    }

    func testButtonDoublePressAndHoldDelay() {
        let rt = ModuleRuntime(Submodule(uuid: "b", kind: .button, ledIndex: nil) { $0 })
        var log: [String] = []
        rt.settings["press"] = { _ in log.append("press") }; rt.settings["doublePress"] = { _ in log.append("double") }
        rt.settings["pressAndHold"] = { _ in log.append("hold") }
        rt.simplePress = false; rt.holdDelay = 0.3
        rt.actuate([1], noop: false); rt.actuate([0], noop: false)
        XCTAssertEqual(log, [])                                   // single press waits for a second one
        RunLoop.main.run(until: Date() + 0.3); XCTAssertEqual(log, ["press"])
        rt.actuate([1], noop: false); rt.actuate([0], noop: false); rt.actuate([1], noop: false); rt.actuate([0], noop: false)
        XCTAssertEqual(log, ["press", "double"])                  // two releases inside 250 ms → doublePress, no press
        RunLoop.main.run(until: Date() + 0.3); XCTAssertEqual(log, ["press", "double"])
        rt.actuate([1], noop: false); RunLoop.main.run(until: Date() + 0.35); rt.actuate([0], noop: false)
        XCTAssertEqual(log, ["press", "double", "hold"])          // hold fired at holdDelay; release adds nothing
        rt.doubleDelay = 0.6; rt.holdDelay = 2                    // the preference: a slow second click still counts
        rt.actuate([1], noop: false); rt.actuate([0], noop: false); RunLoop.main.run(until: Date() + 0.35)
        rt.actuate([1], noop: false); rt.actuate([0], noop: false)
        XCTAssertEqual(log, ["press", "double", "hold", "double"])
    }

    /// The main thread stalls while a button is down and the release waits in the queue behind it: a short press, not a hold.
    func testStalledMainThreadIsNotAHold() {
        let rt = ModuleRuntime(Submodule(uuid: "b", kind: .button, ledIndex: nil) { $0 })
        var log: [String] = []
        rt.settings["press"] = { _ in log.append("press") }; rt.settings["pressAndHold"] = { _ in log.append("hold") }
        rt.simplePress = false; rt.holdDelay = 0.2
        rt.actuate([1], noop: false)
        DispatchQueue.main.async { rt.actuate([0], noop: false) } // the release arrived in time, the engine is busy
        Thread.sleep(forTimeInterval: 0.3)
        RunLoop.main.run(until: Date() + 0.2)
        XCTAssertEqual(log, ["press"])
    }

    func testFunctionWaitsForItsApp() {
        let rt = ModuleRuntime(Submodule(uuid: "b", kind: .button, ledIndex: nil) { $0 })
        var log: [String] = [], behind = true
        rt.settings["press"] = { _ in log.append("press") }; rt.willExec = { behind }
        rt.exec("press"); XCTAssertEqual(log, []) // the app is coming forward
        behind = false; rt.exec("press"); XCTAssertEqual(log, ["press"])
        RunLoop.main.run(until: Date() + 0.3); XCTAssertEqual(log, ["press", "press"])
    }

    func testSubmoduleDecoding() {
        let core = submodules(node: "C", typeId: 25)
        XCTAssertEqual(core.map(\.uuid), ["C::button1", "C::button2"])
        XCTAssertEqual(core[1].read([2, 0, 0, 0, 0, 0, 0, 0]), [1])
        let d3 = submodules(node: "D", typeId: 9)
        XCTAssertEqual(d3[2].read([0b0100_0100, 0, 0, 255, 0, 0, 0, 0]), [1, -1, 1]) // dial3 pressed, one ccw tick, tapped
        XCTAssertEqual(submodules(node: "S", typeId: 2)[0].read([1, 0, 3, 0, 0, 0]), [1, 3, 0])
        // Orbiter (Owl): ring ticks signed, Core tilt X/Y int8 in bytes 5/6, magnet field bytes ignored; from the 2026-11-12 capture
        XCTAssertEqual(submodules(node: "O", typeId: 24, turn: 2)[0].read([254, 1, 44, 255, 200, 130, 60, 0]), [-2, -126, 60]) // connector at the top: the sensor's own axes
        // 방향 고정: connector at the bottom (0) or right (3) reads the body backwards, LED too; left (1) and top (2) are the body's own order
        for (turn, first) in [(0, 2), (1, 0), (2, 0), (3, 2), (4, 2)] {
            let b = submodules(node: "B", typeId: 8, turn: turn)
            XCTAssertEqual(b[0].uuid, "B::button1"); XCTAssertEqual(b[0].ledIndex, first)
            XCTAssertEqual(b[0].read([1 << first]), [1]); XCTAssertEqual(b[1].read([2]), [1])
        }
        XCTAssertEqual(submodules(node: "D", typeId: 9, turn: 0)[0].read([0b0100_0100, 1, 2, 250, 0, 0]), [1, -6, 1])
        XCTAssertEqual(submodules(node: "S", typeId: 10, turn: 3)[0].read([0, 10, 20, 30]), [225])
        // Orbiter raw (x 100, y 20) as (screen right, screen up) per turn; each turn is the one before turned clockwise
        XCTAssertEqual((0..<4).map { submodules(node: "O", typeId: 24, turn: $0)[0].read([0, 0, 0, 0, 0, 100, 20, 0]).suffix(2).map { $0 } }, [[-100, -20], [-20, 100], [100, 20], [20, -100]])
    }

    func testRootInheritsAndUnpluggedCoreKeepsAssignments() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-root-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let state: [String: Any] = ["profiles": [["id": "p1", "title": "T", "app": "", "tags": [], "lastActivated": 1,
            "assignments": ["C::button1": ["preset": "profiles.next", "app": "", "settings": ["press": ["dispatch": ["type": "NEXT_PROFILE"]], "pressAndHold": ["ui": ["type": "SHOW_LAYOUT_PREVIEW"]]]]]]], "preferences": [:]]
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        let e = Engine(storeURL: url)
        e.device.onLayout?(["u": "C", "i": 0, "t": 25, "c": []])
        RunLoop.main.run(until: Date() + 0.1)
        // default root: both Core buttons' 길게 = 전환 패널; the preset's 앱 창 보이기 is dropped so it shows through, the profile's 누름 stays
        XCTAssertEqual(e.inheritedSlots["C::button1"], ["pressAndHold"])
        XCTAssertEqual(((e.effective["C::button1"]?["pressAndHold"] as? [String: Any])?["dispatch"] as? [String: Any])?["type"] as? String, "PROFILE_SWITCHER")
        XCTAssertEqual(((e.effective["C::button1"]?["press"] as? [String: Any])?["dispatch"] as? [String: Any])?["type"] as? String, "NEXT_PROFILE")
        XCTAssertEqual(e.inheritedSlots["C::button2"], ["pressAndHold"])
        // the profile overrides the slot → no inheritance; editing the root writes a path key, not the Core's uuid
        e.store.assign("C::button1", ["preset": "", "app": "", "settings": ["pressAndHold": ["key": "a"]]])
        XCTAssertEqual(e.inheritedSlots["C::button1"], [])
        e.store.editingRoot = true
        e.store.assign("C::button2", nil as [String: Any]?)
        XCTAssertNil((e.store.root["assignments"] as? [String: Any] ?? [:])["::button2"])
        XCTAssertEqual(e.inheritedSlots["C::button2"], [])
        e.store.editingRoot = false
        // unplug: a profile without a layout still finds its Core assignments
        e.store.hardware = [:] // what layoutChanged(nil) does on disconnect
        XCTAssertEqual(e.store.board(e.store.activeProfile).modules[0].u, "C")
        XCTAssertNotNil(e.store.assignments(e.store.activeProfile)["C::button1"])
    }

    func testStoreCycling() {
        let c = Catalog()
        XCTAssertGreaterThanOrEqual(c.apps.count, 2) // System and at least lightroom
        XCTAssertNotNil(c.app("com.adobe.lightroom")?.inputs["Exposure"])
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mc-test-state.json")
        try? FileManager.default.copyItem(at: Store.legacyState, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let s = Store(catalog: c, url: tmp)
        let ids = s.profiles.map { $0["id"] as! String }
        let apps = Set(s.profiles.map { $0["app"] as? String ?? "" })
        if apps.count > 1 {
            let before = s.activeProfile
            s.nextProfile(autoSwitch: true)
            XCTAssertNotEqual(s.activeProfile["app"] as? String, before["app"] as? String, "Next Profile moves to another app's 묶음")
            s.previousProfile(autoSwitch: true)
            XCTAssertEqual(s.activeProfile["id"] as! String, before["id"] as! String)
        }
        if apps.count > 1 {
            let e = Engine(storeURL: tmp)
            e.dispatch("PROFILE_SWITCHER")
            let sw = e.panel!
            XCTAssertNotEqual(sw.items[sw.index].app, e.store.activeProfile["app"] as? String ?? "", "opens on another 묶음")
            e.dispatch("SWITCHER_NEXT"); e.dispatch("SWITCHER_PREVIOUS")
            XCTAssertEqual(e.panel?.index, sw.index)
            e.dispatch("SWITCHER_COMMIT")
            XCTAssertNil(e.panel)
            XCTAssertEqual(e.store.activeProfile["app"] as? String ?? "", sw.items[sw.index].app, "release switches to the highlighted 묶음")
        }
        for id in ids { s.closeProfile(id) }
        XCTAssertEqual(s.profiles.count, 1, "closing every profile leaves a fresh one")
    }
}

final class ColorTests: PluginCase {
    func testBlackMeansUnset() {
        // black is CommandPost's "not yet recolored" placeholder → LED stays visible
        XCTAssertTrue(Engine.ledColor("#000000") == (255, 255, 255))
        XCTAssertTrue(Engine.ledColor("#ff8000") == (255, 56, 0)) // gamma
        let l = Leds { _ in }; l.balance = [7: [1, 1, 0.5]]
        XCTAssertEqual(l.wire((255, 255, 255), 1), 255 | 150 << 8 | 69 << 16) // default balance: blue-heavy LEDs
        XCTAssertEqual(l.wire((0, 0, 200), 1), 200 << 16) // strongest channel keeps its level
        XCTAssertEqual(l.wire((255, 255, 255), 7), 255 | 255 << 8 | 128 << 16) // per-module balance
        XCTAssertTrue(Engine.ledColor("#000080") == (0, 0, 255)) // full strength
        XCTAssertTrue(Engine.ledColor(nil) == (255, 255, 255))
    }
}

@testable import CoreV2

/// Whole path without hardware: fake layout + fake dial ticks → preset → System (volume is readable back; keystrokes are not).
final class EndToEndTests: PluginCase {
    /// A connected module that is not on the profile's board carries no assignments; applying it takes over its own app's imported ones only.
    func testUndoBoardEdit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-undo-\(UUID().uuidString).json")
        let state: [String: Any] = ["profiles": [["id": "p1", "title": "T", "app": "lr", "tags": [], "lastActivated": 1, "layout": Board.empty(coreU: "C").json,
            "assignments": ["C::button1": ["app": "", "preset": "x"]]]], "preferences": [:]]
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        let store = Store(catalog: Catalog(), url: url)
        store.setModuleName("C", "판"); XCTAssertEqual(store.moduleName("C"), "판")
        store.setBoard(Board(modules: [])) // removing the module drops its assignments and name
        XCTAssertTrue((store.activeProfile["assignments"] as? [String: Any] ?? [:]).isEmpty)
        store.undo(); XCTAssertEqual(store.board(store.activeProfile).modules.count, 1); XCTAssertEqual(store.moduleName("C"), "판")
        XCTAssertNotNil((store.activeProfile["assignments"] as? [String: Any])?["C::button1"])
        store.undo(); XCTAssertEqual(store.moduleName("C"), "")
    }

    func testTempModuleStartsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-temp-\(UUID().uuidString).json")
        let state: [String: Any] = ["profiles": [["id": "p1", "title": "T", "app": "lr", "tags": [], "lastActivated": 1,
            "layout": Board.empty(coreU: "C").json,
            "assignments": ["D::dial1": ["app": "", "preset": "system.volume"], "D::dial2": ["app": "fcp", "preset": "x"]]]], "preferences": [:]]
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        let store = Store(catalog: Catalog(), url: url)
        store.hardware = ["": (u: "C", t: 25), "2": (u: "D", t: 9)]
        XCTAssertTrue(store.assignments(store.activeProfile).isEmpty)
        let i = try XCTUnwrap(store.adopt("2")), u = store.board(store.activeProfile).modules[i].u
        XCTAssertEqual(Set(store.assignments(store.activeProfile).keys), ["D::dial1"]) // re-keyed to the hardware; the other app's entry stays behind
        XCTAssertNotNil((store.activeProfile["assignments"] as? [String: Any])?[u + "::dial1"])
    }

    /// 켜짐 방식: 하나만 켜짐 turns the others off; 켜짐 유지 flips on each press.
    func testButtonModes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-lit-\(UUID().uuidString).json")
        let state: [String: Any] = ["profiles": [["id": "p1", "title": "T", "app": "", "tags": [], "lastActivated": 1,
                                                  "assignments": ["B": ["settings": ["buttonMode": "one"]], "T": ["settings": ["buttonMode": "toggle"]]]]], "preferences": [:]]
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        let engine = Engine(storeURL: url)
        engine.device.onLayout?(["u": "C", "i": 0, "t": 25, "c": [["u": "T", "i": 2, "t": 1], NSNull(), ["u": "B", "i": 1, "t": 8]]] as [String: Any]) // B on the right port: connector left, the body's own order)
        RunLoop.main.run(until: Date() + 0.1)
        func tap(_ id: Int, _ bits: Int) {
            for v in [bits, 0] { engine.device.onInputs?([CoreDevice.Input(localId: id, values: [v, 0, 0, 0, 0, 0, 0, 0], noop: false)]); RunLoop.main.run(until: Date() + 0.05) }
        }
        tap(1, 1); XCTAssertEqual(engine.lit, ["p1|B::button1"])
        tap(1, 4); XCTAssertEqual(engine.lit, ["p1|B::button3"]) // the first went off
        tap(1, 4); XCTAssertEqual(engine.lit, ["p1|B::button3"]) // pressing the lit one keeps it
        tap(2, 1); XCTAssertEqual(engine.lit, ["p1|B::button3", "p1|T"])
        tap(2, 1); XCTAssertEqual(engine.lit, ["p1|B::button3"])
    }

    func testThenPutsPointerAtFunctionDefault() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-e2e-\(UUID().uuidString).json")
        // press runs a harmless ui action (nothing reaches a real app); the 회전 wire only names the function whose default is used
        let settings: [String: Any] = ["turn": ["input": "Tint", "app": "com.adobe.lightroom", "step": 1],
                                       "press": ["ui": ["type": "HIDE_LAYOUT_PREVIEW"], "then": ["value": "default"]]]
        let state: [String: Any] = ["profiles": [["id": "p1", "title": "T", "app": "", "tags": [], "lastActivated": 1,
                                                  "assignments": ["D::dial1": ["preset": "", "app": "", "settings": settings]]]], "preferences": [:]]
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        let engine = Engine(storeURL: url)
        var got: [Double] = []
        engine.onPointer = { _, f in got.append(f) }
        engine.device.onLayout?(["u": "C", "i": 0, "t": 25, "c": [NSNull(), NSNull(), ["u": "D", "i": 1, "t": 9]]] as [String: Any])
        RunLoop.main.run(until: Date() + 0.1)
        for down in [1, 0] { engine.device.onInputs?([CoreDevice.Input(localId: 1, values: [down, 0, 0, 0, 0, 0, 0, 0], noop: false)]) }
        RunLoop.main.run(until: Date() + 0.5)
        XCTAssertEqual(got, [0.5]) // range −150…150, default 0
    }

    func testDialTurnAdjustsSystemVolume() throws {
        guard let v0 = System.volume() else { throw XCTSkip("no output device") }
        defer { System.setVolume(percent: Double(v0) * 100) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-e2e-\(UUID().uuidString).json")
        let state: [String: Any] = ["profiles": [["id": "p1", "title": "T", "app": "", "tags": [], "lastActivated": 1,
                                                  "assignments": ["D::dial1": ["preset": "system.volume"]]]], "preferences": [:]]
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        let engine = Engine(storeURL: url)
        engine.device.onLayout?(["u": "C", "i": 0, "t": 25, "c": [NSNull(), NSNull(), ["u": "D", "i": 1, "t": 9]]] as [String: Any])
        RunLoop.main.run(until: Date() + 0.1) // handlers hop to main
        System.setVolume(percent: 50)
        engine.device.onInputs?([CoreDevice.Input(localId: 1, values: [0, 10, 0, 0, 0, 0, 0, 0], noop: false)])
        RunLoop.main.run(until: Date() + 0.1)
        XCTAssertEqual(Double(System.volume()! * 100), 60, accuracy: 3)
        engine.device.onInputs?([CoreDevice.Input(localId: 1, values: [0, -10, 0, 0, 0, 0, 0, 0], noop: true)]) // state report: ignored
        RunLoop.main.run(until: Date() + 0.1)
        XCTAssertEqual(Double(System.volume()! * 100), 60, accuracy: 3)
    }

    // MARK: 추가 기능 (계획.md (46)(48)(49))

    func testDailyBackupKeepsNewest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-\(UUID().uuidString)"), state = dir.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: state)
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        for d in 0..<5 { XCTAssertNotNil(Store.backup(state, day: day0 + Double(d) * 86400, keep: 3)) }
        XCTAssertNil(Store.backup(state, day: day0 + 4 * 86400, keep: 3), "one copy per day")
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Backups").path).sorted()
        XCTAssertEqual(left.count, 3)
        XCTAssertNil(Store.backup(dir.appendingPathComponent("none.json")), "no state file yet: nothing to copy")
    }

    func testAccelAndTextChunksAndOneShotOnly() {
        XCTAssertEqual(ActionDecoder.accel(ticks: 1, dt: 0.2), 1)      // slow: one step per tick, as without 가속
        XCTAssertEqual(ActionDecoder.accel(ticks: 1, dt: 60), 1)       // first tick after a pause
        XCTAssertEqual(ActionDecoder.accel(ticks: 3, dt: 0.05), 2, accuracy: 0.01)
        XCTAssertEqual(ActionDecoder.accel(ticks: 20, dt: 0.01), 4)    // capped
        let long = String(repeating: "한", count: 19) + "😀😀"            // an emoji is two UTF-16 units: never split
        XCTAssertEqual(System.chunks(long).map(\.count), [19, 4])
        XCTAssertEqual(System.chunks("").count, 0)
        let c = Catalog(), d = ActionDecoder(catalog: c, appId: "", appLink: AppLink(catalog: c), dispatch: { _ in }, ui: { _ in })
        for v in [["open": "com.apple.finder"], ["shortcut": "x"], ["text": "x"], ["panel": "map"]] {
            XCTAssertNotNil(d.decode(v, kind: .pulse)); XCTAssertNil(d.decode(v, kind: .nudge), "a turn must never run \(v) per tick")
        }
    }

    /// (51) A wire names a shortcut; the key is looked up when it fires, so the user's re-key wins and an own item works.
    func testNamedShortcut() {
        var sent: [String] = []
        System.dry = { sent.append($0) }; defer { System.dry = nil; Keymap.user = [:] }
        let c = Catalog(), d = ActionDecoder(catalog: c, appId: "", appLink: AppLink(catalog: c), dispatch: { _ in }, ui: { _ in })
        let next = d.decode(["keys": "lrc.photoNext"], kind: .pulse)
        next?(1)
        Keymap.user = ["com.adobe.lightroom": ["lrc.photoNext": ["key": "n", "modifiers": ["command"]], "user.x": ["label": "Lrc.Mine", "key": "k", "modifiers": []]]]
        next?(1); d.decode(["keys": "user.x"], kind: .pulse)?(1); d.decode(["keys": "gone"], kind: .pulse)?(1)
        XCTAssertEqual(sent, ["key right", "key command+n", "key k"])
        XCTAssertEqual(Keymap.items(app: "com.adobe.lightroom").first { $0.id == "lrc.photoNext" }?.changed, true)
        XCTAssertEqual(Keymap.find("lrc.photoPrev")?.opposite, "lrc.photoNext")
        for app in Keymap.apps { for i in Keymap.items(app: app) { XCTAssertNotNil(System.keyCodes[i.key], "\(i.id): unknown key \(i.key)") } }
        let ids = Keymap.apps.flatMap { Keymap.items(app: $0).map(\.id) }
        XCTAssertEqual(ids.count, Set(ids).count, "ids must be unique across apps")
    }

    /// Core + a button (T, port 0) + a dial×3 (D, port 2); two pages of one 묶음, p1 active.
    private func rig(_ assignments: [String: Any]) throws -> Engine {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-new-\(UUID().uuidString).json")
        let state: [String: Any] = ["profiles": [["id": "p1", "title": "하나", "app": "", "tags": [], "lastActivated": 2, "assignments": assignments],
                                                 ["id": "p2", "title": "둘", "app": "", "tags": [], "lastActivated": 1, "assignments": [:] as [String: Any]]], "preferences": [:] as [String: Any]]
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        let engine = Engine(storeURL: url)
        engine.device.onLayout?(["u": "C", "i": 0, "t": 25, "c": [["u": "T", "i": 2, "t": 1], NSNull(), ["u": "D", "i": 1, "t": 9]]] as [String: Any])
        RunLoop.main.run(until: Date() + 0.1)
        return engine
    }
    private func feed(_ e: Engine, _ id: Int, _ v: [Int]) {
        e.device.onInputs?([CoreDevice.Input(localId: id, values: v + Array(repeating: 0, count: 8 - v.count), noop: false)]); RunLoop.main.run(until: Date() + 0.05)
    }

    func testAlternateRunsAThenB() throws {
        let e = try rig(["T": ["settings": ["press": ["alternate": [["ui": ["type": "SHOW_LAYOUT_PREVIEW"]], ["ui": ["type": "HIDE_LAYOUT_PREVIEW"]]]]]]])
        var got: [Bool] = []
        e.onPreview = { got.append($0) }
        for _ in 0..<3 { feed(e, 2, [1]); feed(e, 2, [0]) }
        XCTAssertEqual(got, [true, false, true])
    }

    func testDialHoldsPanelTurnsThroughItAndReleasePicks() throws {
        let e = try rig(["D::dial1": ["settings": ["pressDown": ["panel": "pages"], "turn": ["ui": ["type": "SHOW_LAYOUT_PREVIEW"]], "press": ["ui": ["type": "SHOW_LAYOUT_PREVIEW"]]]]])
        var ran = 0
        e.onPreview = { _ in ran += 1 }
        feed(e, 1, [1])                                              // press: the list opens on the page used before
        XCTAssertEqual(e.panel?.items.map(\.label), ["하나", "둘"]); XCTAssertEqual(e.panel?.index, 1)
        feed(e, 1, [1, 8]); XCTAssertEqual(e.panel?.index, 0)        // held and turned: one item on
        feed(e, 1, [1, -8]); XCTAssertEqual(e.panel?.index, 1)
        feed(e, 1, [0])                                              // release picks
        XCTAssertNil(e.panel); XCTAssertEqual(e.store.activeProfile["id"] as? String, "p2")
        RunLoop.main.run(until: Date() + 0.4)
        XCTAssertEqual(ran, 0, "while the panel is open the dial's own turn and press stay quiet")
    }

    func testRenamingAListKeepsItsWires() throws {
        let e = try rig([:])
        e.store.setPanels([["name": "자주", "items": [["key": "4", "label": "캡처"]]], ["name": "다른", "items": []]])
        e.store.assign("u::button1", ["app": "", "preset": "", "settings": ["pressAndHold": ["panel": "list:자주"], "press": ["panel": "list:다른"]]])
        e.store.renamePanel("자주", to: "다른") // taken: nothing changes
        XCTAssertEqual(e.store.panels.map { $0["name"] as? String }, ["자주", "다른"])
        e.store.renamePanel("자주", to: "즐겨찾기")
        XCTAssertEqual(e.store.panels.map { $0["name"] as? String }, ["즐겨찾기", "다른"])
        let wires = try JSONSerialization.data(withJSONObject: e.store.activeProfile["assignments"] ?? [:], options: .sortedKeys)
        let text = String(decoding: wires, as: UTF8.self)
        XCTAssertTrue(text.contains("list:즐겨찾기") && text.contains("list:다른") && !text.contains("list:자주"), text)
        e.dispatch("PANEL:list:즐겨찾기"); XCTAssertEqual(e.panel?.items.map(\.label), ["캡처"])
        e.store.undo(); XCTAssertEqual(e.store.panels.first?["name"] as? String, "자주")
    }

    func testListPanelRunsItsItemAndHoldStackNextComesBack() throws {
        let e = try rig([:])
        e.store.setPanels([["name": "자주", "items": [["ui": ["type": "SHOW_LAYOUT_PREVIEW"], "label": "창 보이기"], ["key": "4", "modifiers": ["shift", "command"], "label": "캡처"]]]])
        var shown = 0
        e.onPreview = { if $0 { shown += 1 } }
        e.dispatch("PANEL:list:없는 목록"); XCTAssertNil(e.panel)
        e.dispatch("PANEL:list:자주")
        XCTAssertEqual(e.panel?.items.map(\.label), ["창 보이기", "캡처"]); XCTAssertEqual(e.panel?.items[1].note, "⇧⌘4")
        e.dispatch("SWITCHER_COMMIT"); XCTAssertEqual(shown, 1)
        e.store.updateProfile("p2", ["app": "com.adobe.lightroom"]); e.dispatch("ACTIVATE_BUNDLE:com.adobe.lightroom")
        XCTAssertEqual(e.store.activeProfile["id"] as? String, "p2"); e.dispatch("ACTIVATE_BUNDLE:"); XCTAssertEqual(e.store.activeProfile["id"] as? String, "p1")
        e.dispatch("PANEL:map"); XCTAssertEqual(e.panel?.kind, "map"); e.dispatch("SWITCHER_CANCEL"); XCTAssertNil(e.panel)

        e.store.assign("D::dial1", ["settings": ["name": "x"]])       // applies D to the profile, so it can host a stack
        let host = e.store.snapshot(e.store.activeProfile)["2"]!.u
        e.store.addStackMember(host); XCTAssertEqual(e.store.stack(host).index, 1)
        e.dispatch("HOLD_STACK_NEXT:" + host); XCTAssertEqual(e.store.stack(host).index, 0)
        e.dispatch("RELEASE_SCREEN"); XCTAssertEqual(e.store.stack(host).index, 1)
        e.dispatch("PANEL:stack:" + host); XCTAssertEqual(e.panel?.items.count, 2); XCTAssertEqual(e.panel?.index, 0) // opens on the next 층
        e.dispatch("SWITCHER_COMMIT"); XCTAssertEqual(e.store.stack(host).index, 0)
    }
}

/// Runs a plugin's helper on `lines` and returns what it printed (stdout, stderr).
func runHelper(_ plugin: String, _ lines: [String], env: [String: String] = [:]) throws -> (out: String, err: String) {
    let dir = repoPlugins.appendingPathComponent(plugin)
    let d = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("plugin.json"))) as? [String: Any])
    let cmd = try XCTUnwrap((d["connect"] as? [String: Any])?["command"] as? [String])
    let p = Process(); p.currentDirectoryURL = dir; p.executableURL = URL(fileURLWithPath: cmd[0], relativeTo: dir); p.arguments = Array(cmd.dropFirst())
    p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
    let out = Pipe(), err = Pipe(), stdin = Pipe(); p.standardOutput = out; p.standardError = err; p.standardInput = stdin
    var e = Data(), o = Data(); let done = DispatchGroup() // drain both while we write: a full pipe stops the helper, and then our write too
    done.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); done.leave() }
    done.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); done.leave() }
    try p.run()
    try stdin.fileHandleForWriting.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8)); try stdin.fileHandleForWriting.close() // EOF ends the helper
    p.waitUntilExit(); done.wait()
    return (String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
}

/// Every script the Capture One helper writes must compile against the installed app's dictionary (osacompile reads the sdef without launching it).
final class CaptureOneTests: PluginCase {
    func testScriptsCompile() throws {
        try need("captureone")
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.captureone.captureone16") != nil else { throw XCTSkip("Capture One not installed") }
        let lines = ["exposure\t+\t0.03", "exposure\t=\t0", "blackAndWhiteRedSensitivity\t+\t1.0", "highlightRecovery20\t+\t1.0",
            "increaseRating", "toggleFiveStarRating", "toggleGreenColorTag", "decreaseColorTag",
            "adjustFocusDynamic\t+\t-5.0", "adjustFocusCoarse\t+\t1.0", "toggleLiveView", "toggleAutoFocus",
            "resetWhiteBalance", "blackAndWhite", "copyAdjustments", "applyAdjustments", "clearMask"]
        let scripts = try runHelper("captureone", lines + ["toggleFilterRedColorTag", "levelTargetHighlightRgb\t=\t200.0"], env: ["KNOBTILE_SCRIPT_ONLY": "1"]).out
        XCTAssertTrue(scripts.hasSuffix("null\ntell adjustments of primary variant\nset level target highlight rgb to 200.0\nend tell\n"), scripts)
        XCTAssertEqual(scripts.components(separatedBy: "null").count, 2, "a listed function has no script: \(scripts)")
        let src = "tell application id \"com.captureone.captureone16\"\n" + scripts.replacingOccurrences(of: "null\n", with: "") + "end tell\n"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try src.write(to: dir.appendingPathComponent("t.applescript"), atomically: true, encoding: .utf8)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        p.arguments = ["-o", dir.appendingPathComponent("t.scpt").path, dir.appendingPathComponent("t.applescript").path]
        let err = Pipe(); p.standardError = err
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
    /// Every function the list offers has a script (the list and the helper are written apart).
    func testEveryListedFunctionHasAScript() throws {
        try need("captureone")
        let names = try XCTUnwrap(Catalog().app("com.phaseone.captureone")).inputs.keys.sorted()
        let out = try runHelper("captureone", names.map { $0 + "\t+\t1.0" }, env: ["KNOBTILE_SCRIPT_ONLY": "1"]).out
        XCTAssertFalse(out.contains("null"), out)
    }
}

/// Every function of the Resolve list is one the helper knows, and the helper loads and runs (without Resolve it only warns) in the real fuscript.
final class ResolveTests: PluginCase {
    func testListedFunctionsAndLua() throws {
        try need("resolve")
        let app = try XCTUnwrap(Catalog().app("com.blackmagic-design.DaVinciResolve"))
        let fuscript = try XCTUnwrap((app.connections.first?["command"] as? [String])?.first)
        guard FileManager.default.isExecutableFile(atPath: fuscript) else { throw XCTSkip("Resolve not installed") }
        // With Resolve open the helper reaches the real project: this test then nudged every function on the user's timeline (2026-11-22).
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.blackmagic-design.DaVinciResolve").isEmpty else { throw XCTSkip("Resolve is running: not touching its project") }
        let r = try runHelper("resolve", ["@hello\t1"] + app.inputs.keys.sorted().map { $0 + "\t+\t1.5" } + ["toggleNode", "cdlNode\t+\t2.0", "markerBlack", "slopeAlpha\t=\t1", "@later\tx"])
        XCTAssertTrue(r.out.contains("@hello\t1\n"), r.out)
        XCTAssertTrue(r.out.contains("@key\td\tcommand\n"), r.out)
        XCTAssertEqual(r.out.components(separatedBy: "@key\t'\tshift,alt\n").count, 5, r.out) // the list's own cdlNode line (1.5 → 2) and ours
        XCTAssertEqual(r.out.components(separatedBy: "\n").filter { $0.hasPrefix("!") }, ["!\tunsupported markerBlack", "!\tunsupported slopeAlpha"])
        XCTAssertFalse((r.out + r.err).contains("[string"), r.out + r.err) // Lua runtime error
    }

    func testOrbiterDeadzoneAndSmoothing() {
        let rt = ModuleRuntime(Submodule(uuid: "o", kind: .orbiter, ledIndex: nil) { $0 })
        rt.tiltDeadzone = 0.1; rt.tiltSmoothing = 0.5
        rt.actuate([0, 5, 0], noop: false)   // 5/127 ≈ 0.04 < deadzone → 0
        XCTAssertEqual(rt.tilt.x, 0)
        rt.actuate([0, 127, 0], noop: false) // smoothing: halfway to 1
        XCTAssertEqual(rt.tilt.x, 0.5, accuracy: 0.001)
        rt.actuate([0, 0, 0], noop: false)
        XCTAssertEqual(rt.tilt.x, 0.25, accuracy: 0.001)
    }

    func testPageFollowsChangesOnly() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mc-page-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let e = Engine(storeURL: tmp), r = "com.blackmagic-design.DaVinciResolve"
        let edit = e.store.addProfile(title: "편집", app: r) // page-less: the 묶음 default
        let color = e.store.addProfile(title: "컬러", app: r); e.store.updateProfile(color, ["screen": "color"])
        e.frontmost(bundle: r)
        e.store.activate(edit); e.screenDetected(app: r, "color")
        XCTAssertEqual(e.store.activeProfile["id"] as? String, color) // Resolve came forward on the color page
        e.store.activate(edit); e.screenDetected(app: r, "color")
        XCTAssertEqual(e.store.activeProfile["id"] as? String, edit) // picked on the console: the same page read again must not pull it back
        e.screenDetected(app: r, "edit"); e.screenDetected(app: r, "color")
        XCTAssertEqual(e.store.activeProfile["id"] as? String, color) // the page really changed
    }

    func testBundleScreenFallsBackToDefault() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mc-bundle-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let s = Store(catalog: Catalog(), url: tmp)
        let base = s.addProfile(title: "LrC", app: "com.adobe.lightroom")
        let dev = s.addProfile(title: "현상", app: "com.adobe.lightroom"); s.updateProfile(dev, ["screen": "develop"])
        s.addProfile(title: "Resolve", app: "com.blackmagic-design.DaVinciResolve")
        XCTAssertEqual(s.profile(app: "com.adobe.lightroom", screen: "develop")?["id"] as? String, dev)
        XCTAssertEqual(s.profile(app: "com.adobe.lightroom", screen: "library")?["id"] as? String, base) // no library profile → bundle default
        XCTAssertNil(s.profile(app: "com.apple.finder", screen: "x"))
        // one board per bundle: a board change on any member reaches all of them, a newcomer takes it
        s.hardware = ["": ("CORE", 25), "2": ("HFL", 1)]
        s.activate(dev); s.adopt("2")
        XCTAssertEqual(s.board(s.profile(base)!).modules.count, 2)
        XCTAssertEqual(s.board(s.profile(dev)!).modules.count, 2)
        let other = s.addProfile(title: "x", app: "")
        s.updateProfile(other, ["app": "com.adobe.lightroom"])
        XCTAssertEqual(s.board(s.profile(other)!).modules.count, 2)
        // Next Page cycles the bundle only: base → dev → other → base; Resolve never appears
        s.activate(base)
        s.nextScreen(by: 1); XCTAssertEqual(s.activeProfile["id"] as? String, dev)
        s.nextScreen(by: 1); XCTAssertEqual(s.activeProfile["id"] as? String, other)
        s.nextScreen(by: 1); XCTAssertEqual(s.activeProfile["id"] as? String, base)
        s.nextScreen(by: -1); XCTAssertEqual(s.activeProfile["id"] as? String, other)
        // two screen pages: the button toggles between them and the default only enters the loop as a starting point
        let lib = s.addProfile(title: "라이브러리", app: "com.adobe.lightroom"); s.updateProfile(lib, ["screen": "library"])
        s.activate(base)
        s.nextScreen(by: 1); XCTAssertEqual(s.activeProfile["id"] as? String, dev)
        s.nextScreen(by: 1); XCTAssertEqual(s.activeProfile["id"] as? String, lib)
        s.nextScreen(by: 1); XCTAssertEqual(s.activeProfile["id"] as? String, dev)
    }

    func testProfileBindsTypeAtPositionNotSerial() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pos-\(UUID()).json")
        let store = Store(catalog: Catalog(), url: url)
        store.hardware = ["": ("CORE", 25), "2": ("BTN-A", 1)]
        store.assign("BTN-A", ["preset": "x"])                                // assigning adopts the module into the profile
        XCTAssertEqual(store.assignments(store.activeProfile)["BTN-A"] as? [String: String], ["preset": "x"])
        store.hardware = ["": ("CORE", 25), "2": ("BTN-B", 1)]            // another button module in the same place
        XCTAssertEqual(store.assignments(store.activeProfile)["BTN-B"] as? [String: String], ["preset": "x"])
        XCTAssertNil(store.assignments(store.activeProfile)["BTN-A"])
        store.hardware = ["": ("CORE", 25), "2": ("DIAL", 2)]             // a dial there: nothing applies to hardware (the ghost keeps its own id for the board)
        XCTAssertTrue(store.assignments(store.activeProfile).keys.allSatisfy { $0.hasPrefix("v:") })
        store.hardware = ["": ("CORE", 25), "3": ("BTN-C", 1)]            // same type elsewhere: ghost at 2 until moved to 3
        XCTAssertTrue(store.assignments(store.activeProfile).keys.allSatisfy { $0.hasPrefix("v:") })
        var b = store.board(store.activeProfile)
        b.modules[1] = b.pose(at: "3", t: 1, u: b.modules[1].u)!             // the logical module keeps its own id when moved
        store.setBoard(b)
        XCTAssertEqual(store.assignments(store.activeProfile)["BTN-C"] as? [String: String], ["preset": "x"])
    }

    /// 2026-11-16: a module only on the board (unplugged) showed none of the root's wiring; plugged in it did.
    func testBoardOnlyModuleShowsRootWiring() throws {
        let e = Engine(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("rootghost-\(UUID()).json"))
        let store = e.store
        store.hardware = ["": ("CORE", 25), "2": ("HB", 8)]
        XCTAssertNotNil(store.adopt("2"))
        store.editingRoot = true; store.assign("HB::button1", ["settings": ["press": ["key": "a"]]]); store.editingRoot = false
        store.hardware = ["": ("CORE", 25)]                                    // unplugged: only the board has it
        let u = try XCTUnwrap(store.snapshot(store.activeProfile)["2"]?.u) + "::button1"
        let eff = try XCTUnwrap(e.effective(u, type: "button"))
        XCTAssertEqual(eff.inherited, ["press"])
        XCTAssertEqual(e.rootSettings(u, type: "button")["press"] as? [String: String], ["key": "a"])
    }

    /// 2026-11-16: root wiring was kept by port path, so moving or stacking a design module lost it. It belongs to the virtual module.
    func testWiringFollowsMovedAndStackedModule() throws {
        let e = Engine(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("follow-\(UUID()).json"))
        let s = e.store
        s.hardware = ["": ("CORE", 25)]
        var b = s.board(s.activeProfile)
        b.modules.append(b.pose(at: "3", t: 9, u: "v:a")!); b.modules.append(b.pose(at: "1", t: 9, u: "v:h")!)
        s.setBoard(b)
        s.assign("v:a::dial1", ["preset": "own"])
        s.editingRoot = true; s.assign("v:a::dial2", ["settings": ["press": ["key": "a"]]]); s.editingRoot = false
        b = s.board(s.activeProfile); b.modules[1].x += 40; s.setBoard(b) // moved away from port 3
        XCTAssertEqual(s.assignments(s.activeProfile)["v:a::dial1"] as? [String: String], ["preset": "own"])
        XCTAssertEqual(try XCTUnwrap(e.effective("v:a::dial2", type: "dial")).inherited, ["press"])
        b = s.board(s.activeProfile); b.modules[1] = b.pose(at: "2", t: 9, u: "v:a")!; s.setBoard(b)
        s.hardware = ["": ("CORE", 25), "2": ("HW", 9)] // real module at its new place takes its wiring
        XCTAssertNotNil(s.rootAssignments()["HW::dial2"])
        XCTAssertNotNil(s.assignments(s.activeProfile)["HW::dial1"])
        s.hardware = ["": ("CORE", 25)]
        s.stackInto("v:h", "v:a"); s.switchStack("v:h", to: 1) // into another module's stack, then attached
        XCTAssertEqual(s.assignments(s.activeProfile)["v:h::dial1"] as? [String: String], ["preset": "own"])
        XCTAssertNotNil(s.rootAssignments()["v:h::dial2"])
    }

    func testOldRootWiringMovesToModule() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rootmove-\(UUID()).json")
        let s = Store(catalog: Catalog(), url: url)
        var b = s.board(s.activeProfile); b.modules.append(b.pose(at: "3", t: 9, u: "v:a")!); s.setBoard(b)
        s.save()
        var j = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        j["root"] = ["assignments": ["::button1": ["preset": "core"], "3::dial2": ["preset": "old"], "9::dial1": ["preset": "nowhere"]]]
        try JSONSerialization.data(withJSONObject: j).write(to: url)
        let r = Store(catalog: Catalog(), url: url).root["assignments"] as? [String: Any] ?? [:]
        XCTAssertEqual(Set(r.keys), ["::button1", "v:a::dial2", "9::dial1"])
    }

    func testApplyMakesLogicalCopy() {
        let store = Store(catalog: Catalog(), url: FileManager.default.temporaryDirectory.appendingPathComponent("replug-\(UUID()).json"))
        store.hardware = ["": ("CORE", 25), "2": ("HFL", 9)]
        store.assign("HFL::dial1", ["preset": "z"])                          // assigning to the connected module applies it: a logical copy with its own id
        let u = store.snapshot(store.activeProfile)["2"]!.u
        XCTAssertTrue(u.hasPrefix("v:"))
        XCTAssertEqual(store.assignments(store.activeProfile)["HFL::dial1"] as? [String: String], ["preset": "z"])
        store.hardware = ["": ("CORE", 25), "0": ("HFL", 9)]                 // same physical module unplugged and put on port 0
        XCTAssertNil(store.assignments(store.activeProfile)["HFL::dial1"])   // the copy stays at port 2; nothing is assigned at port 0
        XCTAssertEqual(store.adopt("0"), 2)                                   // applying there makes a second logical module
        XCTAssertEqual(store.snapshot(store.activeProfile)["2"]?.u, u)
        XCTAssertEqual(store.board(store.activeProfile).modules.count, 3)
    }

    func testVirtualModuleTakesRealOneLater() {
        let store = Store(catalog: Catalog(), url: FileManager.default.temporaryDirectory.appendingPathComponent("virt-\(UUID()).json"))
        var b = store.board(store.activeProfile)
        b.modules.append(b.pose(at: "3", t: 9, u: "v:abc")!)                 // designed without hardware: a dial×3 on port 3
        store.setBoard(b)
        XCTAssertEqual(store.snapshot(store.activeProfile)["3"]?.u, "v:abc")
        XCTAssertEqual(store.snapshot(store.activeProfile)[""]?.u, "v:core")
        store.assign("v:abc::dial2", ["preset": "y"])
        store.hardware = ["": ("CORE", 25), "3": ("REAL", 9)]
        XCTAssertEqual(store.assignments(store.activeProfile)["REAL::dial2"] as? [String: String], ["preset": "y"])
        b = store.board(store.activeProfile); b.modules.removeLast(); store.setBoard(b)
        XCTAssertTrue(store.assignments(store.activeProfile).isEmpty)
    }

    /// Geometry: ports, pins, connection by cell, paths, snapping, legacy conversion.
    func testBoardGeometry() {
        var b = Board.empty()
        let core = b.modules[0]
        XCTAssertEqual(Board.ports(core).map(\.cell), [.init(0, -1), .init(1, -1), .init(2, 0), .init(1, 1), .init(0, 1)]) // clockwise from USB
        let d = b.pose(at: "2", t: 9, u: "D")!                              // dial×3 on the right port: pins face left, box to the right
        XCTAssertEqual([d.x, d.y, d.r, d.w, d.h], [2, 0, 1, 2, 1]) // pins face left (r = 1), box to the right of the Core
        b.modules.append(d)
        let o = b.pose(at: "2/2", t: 24, u: "O")!                            // Orbiter chained on the dial's top port
        b.modules.append(o)
        XCTAssertEqual(b.paths(), [0: "", 1: "2", 2: "2/2"])
        XCTAssertEqual(b.derived()["2/2"]?.t, 24)
        // moved one cell away: loose, no path, and no pull-back (snap only reports a joint at the exact cell)
        b.modules[2].x += 1
        XCTAssertNil(b.paths()[2])
        XCTAssertEqual(b.snap(b.modules[2], moving: 2).pose, b.modules[2]); XCTAssertNil(b.snap(b.modules[2], moving: 2).port)
        b.modules[2] = o
        let s = b.snap(o, moving: 2)
        XCTAssertEqual(s.pose, o); XCTAssertEqual(s.port.map { "\($0.parent)/\($0.port)" }, "1/2")
        // wrong orientation: not a candidate
        var turned = o; turned.r = (o.r + 1) % 4
        XCTAssertFalse(b.candidates(for: turned, moving: 2).contains { $0.parent == 1 && $0.port == 2 })
        XCTAssertTrue(b.overlaps(Pose(t: 1, x: 0, y: 0, r: 0, u: "X")))
        // contact rules: nothing on the Core's USB side; pins against pins is not allowed; female against female and pins against plain are
        XCTAssertFalse(b.placeable(Pose(t: 1, x: -1, y: 0, r: 0, u: "X")))                // left of the Core = USB
        XCTAssertTrue(b.placeable(Pose(t: 1, x: 0, y: -2, r: 2, u: "X")))                 // pins up, its female bottom port against the Core's top ports: butts
        XCTAssertTrue(b.placeable(Pose(t: 1, x: 0, y: -2, r: 0, u: "X")))                 // pins down into Core port 0: a connection
        var loose = Board.empty(); loose.modules.append(Pose(t: 1, x: 5, y: 5, r: 0, u: "A")) // pins down, pins unit at (5,6)
        XCTAssertFalse(loose.placeable(Pose(t: 1, x: 5, y: 7, r: 2, u: "B")))             // pins up at (5,7): pins against pins
        XCTAssertTrue(loose.placeable(Pose(t: 1, x: 5, y: 7, r: 0, u: "B")))              // its female top port under A's pins: a connection
        // dragging B's female port onto A's pins snaps the other way round (B becomes A's parent geometrically)
        let rs = loose.snap(Pose(t: 1, x: 5, y: 7, r: 0, u: "B"))
        XCTAssertEqual([rs.pose.x, rs.pose.y], [5, 7]); XCTAssertEqual(rs.ownPort, 2); XCTAssertNil(rs.port)
        XCTAssertNil(loose.snap(Pose(t: 1, x: 6, y: 8, r: 0, u: "B")).ownPort)
        // legacy path-keyed layout converts to the same geometry
        let legacy: [String: [String: Any]] = ["": ["u": "C", "t": 25, "r": 0], "2": ["u": "D", "t": 9], "2/2": ["u": "O", "t": 24], "free:a": ["u": "F", "t": 1, "x": 5, "y": 5, "r": 1]]
        let lb = Board(layout: legacy)!
        XCTAssertEqual(lb.derived().mapValues(\.u), ["": "C", "2": "D", "2/2": "O"])
        XCTAssertEqual(Board.pins(lb.modules[3])!.cell, .init(5, 5))
        XCTAssertEqual(Board(layout: lb.json)!, lb)
    }

    /// LED player: base colors go out grouped per module, only changes are sent, effects overlay then return to base, budget caps a tick.
    func testPlugRippleAndPreviewFrame() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mc-plug-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: ["profiles": [], "preferences": ["led": ["boot": false]]]).write(to: url)
        let engine = Engine(storeURL: url)
        var frame: [String: RGB] = [:]
        engine.leds.onFrame = { frame = $0 }
        engine.device.onLayout?(["u": "C", "i": 0, "t": 25, "c": []])
        RunLoop.main.run(until: Date() + 0.1)
        XCTAssertFalse(engine.leds.playing) // boot chain off
        engine.device.onLayout?(["u": "C", "i": 0, "t": 25, "c": [NSNull(), NSNull(), ["u": "D", "i": 1, "t": 9]]] as [String: Any])
        RunLoop.main.run(until: Date() + 0.1)
        XCTAssertTrue(engine.leds.playing) // a new module arrived: ripple
        XCTAssertNotNil(frame["D::dial2"]) // preview frame covers the new LEDs
        engine.device.onLayout?(["u": "C", "i": 0, "t": 25, "c": []])
        RunLoop.main.run(until: Date() + 0.1)
        XCTAssertFalse(engine.leds.playing) // unplug: nothing new, effects cleared
    }

    func testLedsDiffGroupingAndEffects() {
        var out: [[String: Any]] = []
        let leds = Leds { out.append($0) }
        var t: [String: Leds.LED] = [:]
        for i in 0..<3 { t["d::dial\(i + 1)"] = Leds.LED(localId: 2, index: i, x: 3, y: Double(i), depth: 1) }
        t["c::button1"] = Leds.LED(localId: 1, index: nil, x: 0, y: 0, depth: 0); t["c::button2"] = Leds.LED(localId: 1, index: nil, x: 1, y: 0, depth: 0)
        leds.reset(t)
        for k in t.keys { leds.base[k] = (10, 20, 30) }
        leds.tick()
        XCTAssertEqual(out.count, 2) // one whole-module message per module (Core + dial×3 all alike)
        XCTAssertEqual((out.map { ($0["set_module"] as! [Int])[1] }), [0x02, 0x02])
        out = []; leds.tick(); XCTAssertEqual(out.count, 0) // nothing changed
        leds.set("d::dial2", live: (255, 0, 0)); leds.tick()
        XCTAssertEqual(out.map { ($0["set_module"] as! [Int])[1] }, [0x05, 0x05]) // only the changed LED, indexed, + commit
        XCTAssertEqual((out[1]["set_module"] as! [Int])[2], 0x7f << 24)
        out = []; leds.set("d::dial2", live: nil); leds.tick(); XCTAssertEqual(out.count, 2) // back to base: that LED + commit
        var fr: [String: RGB] = [:]; leds.onFrame = { fr = $0 }
        leds.set("d::dial2", live: (1, 2, 3)); leds.wash((9, 9, 9), owner: "d::dial2"); leds.tick() // 데코레이션: all but the owner
        XCTAssertTrue(fr["c::button1"]! == (9, 9, 9) && fr["d::dial1"]! == (9, 9, 9) && fr["d::dial2"]! == (1, 2, 3))
        leds.set("d::dial2", live: nil); leds.wash(nil); leds.tick(); XCTAssertTrue(fr["c::button1"]! == (10, 20, 30))
        var frames: [[String: RGB]] = []; leds.onFrame = { frames.append($0) }
        leds.play(.init(kind: .flash, color: (255, 255, 255), duration: 0.16, uuid: "c::button1")); // tick ran inside play
        XCTAssertTrue(frames.last!["c::button1"]! == (255, 255, 255)); XCTAssertTrue(frames.last!["c::button2"]! == (10, 20, 30))
        XCTAssertTrue(leds.playing)
        let e = expectation(description: "flash over"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { e.fulfill() }; wait(for: [e], timeout: 1)
        XCTAssertFalse(leds.playing); XCTAssertTrue(frames.last!["c::button1"]! == (10, 20, 30))
        // budget: 9 single-LED modules dirty at once → 8 messages this tick, 1 next
        var big: [String: Leds.LED] = [:]; for i in 0..<9 { big["m\(i)"] = Leds.LED(localId: i, index: nil, x: Double(i), y: 0, depth: 1) }
        leds.reset(big); for k in big.keys { leds.base[k] = (1, 2, 3) }
        out = []; leds.tick(); XCTAssertEqual(out.count, Leds.budget); leds.tick(); XCTAssertEqual(out.count, 9)
    }

    func testColorBandsAndIconColor() {
        XCTAssertNil(Engine.colorBand(nil)); XCTAssertNotNil(Engine.colorBand("temp")); XCTAssertNil(Engine.colorBand("nope")); XCTAssertNil(Engine.colorBand(["#ff0000"])); let band = Engine.colorBand(["#0000ff", "#ff0000"])!; XCTAssertTrue(band.0 == (0, 0, 255) && band.1 == (255, 0, 0))
        let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in NSColor(red: 1, green: 0, blue: 0, alpha: 1).setFill(); r.fill(); return true }
        let c = Engine.dominant(img)!
        XCTAssertTrue(c.r > 200 && c.g < 40 && c.b < 40)
    }
}

final class PresetTextTests: PluginCase {
    func testSectionScreenAndDescription() {
        XCTAssertEqual(PresetText.section("Basic.White Balance: As Shot"), "Basic")
        XCTAssertEqual(PresetText.name("Photo.Flag.Toggle Pick").group, "Flag")
        XCTAssertEqual(PresetText.name("Next Page").name, "Next Page")
        XCTAssertEqual(PresetText.screens(app: "com.adobe.lightroom", label: "Basic.Temperature"), ["develop"])
        XCTAssertEqual(PresetText.screens(app: "com.adobe.lightroom", label: "Photo.Rating.Set Rating"), ["library", "develop"])
        XCTAssertEqual(PresetText.screens(app: "com.adobe.lightroom", label: "View.Grid"), ["library"])
        XCTAssertEqual(PresetText.screens(app: "com.adobe.lightroom", label: "View.Develop Before"), ["develop"])
        XCTAssertEqual(PresetText.screens(app: "com.adobe.lightroom", label: "View.Zoom Toggle"), [])
        XCTAssertNil(PresetText.screens(app: "", label: "Next Page"))
        let dial: [String: Any] = ["turn": ["input": "Contrast = ", "step": 1], "pressAndTurn": ["input": "Contrast = ", "step": 10],
                                   "press": ["Contrast = ", "reset"], "doubleTap": ["input": "WhiteBalance = Auto"]]
        XCTAssertEqual(PresetText.describe(dial, type: "dial"), "돌리기 ±1 · 누르고 돌리기 ±10 · 누름 리셋 · 더블탭 Auto")
        XCTAssertEqual(PresetText.describe(["press": ["key": "s", "modifiers": ["shift", "meta"]]], type: "button"), "⇧⌘S")
        XCTAssertEqual(PresetText.describe(["press": ["input": "WhiteBalance = Auto"]], type: "button"), "") // the label already says it
        XCTAssertEqual(PresetText.describe(["press": ["Temperature = ", "increment"]], type: "button"), "+1 단계")
        XCTAssertEqual(PresetText.describe(["pose": ["input": "Temperature = ", "range": [2400, 12000]]], type: "slider"), "범위 2400~12000")
        XCTAssertEqual(PresetText.describe(["tiltX": ["input": "Tint = "], "tiltY": ["input": "Temperature = "], "turn": ["input": "Exposure = "]], type: "orbiter"), "↔ Tint · ↕ Temperature · 돌리기 Exposure")
    }
    /// The hand-written 추천 table must name real catalog labels, each on the page it is recommended for (or page-free).
    func testRecommendedLabelsExist() throws {
        let c = Catalog()
        for (app, screens) in [("com.blackmagic-design.DaVinciResolve", ["color", "edit", "cut", "media"]), ("com.adobe.lightroom", ["library", "develop", ""])] where c.app(app) != nil {
            let labels = Set(try XCTUnwrap(c.app(app)).presets.values.flatMap { $0 }.compactMap { $0["label"] as? String })
            for sc in screens {
                let rec = PresetText.recommended(app: app, screen: sc)
                XCTAssertFalse(rec.isEmpty, "\(app) \(sc)")
                for l in rec {
                    XCTAssertTrue(labels.contains(l), "\(app): \(l) not in catalog")
                    if !sc.isEmpty, let pages = PresetText.screens(app: app, label: l) { XCTAssertTrue(pages.isEmpty || pages.contains(sc), "\(l) is not for \(sc)") }
                }
            }
        }
    }
}

/// The plugin spec's acceptance check (Docs/plugin-spec-v1.md): the example plugin, untouched, registers a function,
/// a nudge reaches its helper and the value comes back. No host code knows about it.
final class PluginTests: PluginCase {
    private func until(_ s: Double, _ ok: () -> Bool) { let end = Date() + s; while !ok() && Date() < end { RunLoop.main.run(until: Date() + 0.002) } }

    func testExamplePluginEndToEnd() throws {
        let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Docs/examples/counter")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: example, to: root.appendingPathComponent("counter"))
        let probe = Process(); probe.executableURL = URL(fileURLWithPath: "/usr/bin/env"); probe.arguments = ["python3", "-c", ""]
        try probe.run(); probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { throw XCTSkip("the example's helper needs python3") }

        let c = Catalog(dirs: [root]), id = "com.example.counter"
        let app = try XCTUnwrap(c.app(id))
        XCTAssertEqual(app.inputs["count"]?.range, [0, 100])
        // no presets in the example: the host made the plain ones
        XCTAssertEqual((app.preset("dial", named: "count")?["pressAndTurn"] as? [String: Any])?["step"] as? Double, 10)
        XCTAssertEqual((app.preset("dial", named: "count")?["press"] as? [String: Any])?["action"] as? String, "reset")
        XCTAssertNotNil(app.preset("slider", named: "count"))

        let link = AppLink(catalog: c)
        var values: [Double] = [], linked = false
        link.onValue = { _, name, v, _ in if name == "count" { values.append(v) } }
        link.onConnected = { _, ok in linked = ok }
        link.send(app: id, input: "count", operation: "+", params: [3.0], range: nil)
        until(5) { !values.isEmpty }
        XCTAssertTrue(linked)
        XCTAssertEqual(values, [53])
        link.send(app: id, input: "count", operation: "=", params: [200.0], range: nil)
        until(5) { values.count == 2 }
        XCTAssertEqual(values.last, 100, "the helper keeps its own range")

        var ms: [Double] = [] // one dial step there and back
        for _ in 0..<50 {
            let n = values.count, t = Date()
            link.send(app: id, input: "count", operation: "+", params: [-1.0], range: nil)
            until(2) { values.count > n }
            ms.append(Date().timeIntervalSince(t) * 1000)
        }
        XCTAssertEqual(values.last, 50)
        ms.sort()
        print(String(format: "plugin round trip: median %.2f ms, worst %.2f ms", ms[25], ms[49]))
        XCTAssertLessThan(ms[25], 50)
    }

    func testAProfileIsMarkedOnlyWhenItUsesAFunctionOfAMissingPlugin() {
        let c = Catalog(dirs: [Catalog.dirs[0]]) // System only, as the app ships
        func p(_ app: String, _ press: [String: Any]) -> [String: Any] { ["app": app, "assignments": ["m::button1": ["app": "", "preset": "", "settings": ["press": press]]]] }
        XCTAssertTrue(c.missing(p("com.blackmagic-design.DaVinciResolve", ["input": "toggleNode"])))
        XCTAssertFalse(c.missing(p("com.adobe.Photoshop", ["key": "b", "modifiers": []])))                 // keys need no plugin
        XCTAssertFalse(c.missing(p("com.blackmagic-design.DaVinciResolve", ["input": "audio_play"])))      // a System function
        XCTAssertFalse(c.missing(p("", ["input": "audio_play"])))
        XCTAssertFalse(Catalog.shared.missing(p("com.adobe.lightroom", ["input": "Exposure"]))) // installed
    }

    /// Every plugin's starter.json imports, uses only functions its plugin has, and brings the 패널 목록 it opens (once).
    func testEveryStarterImportsAndNeedsNothingMissing() throws {
        try need("resolve", "captureone", "photoshop") // the counts below are the full set's
        let store = Store(catalog: Catalog.shared, url: FileManager.default.temporaryDirectory.appendingPathComponent("starter-\(UUID().uuidString).json"))
        let starters = Catalog.shared.raw.compactMap { $0["starter"] as? [String: Any] }
        XCTAssertEqual(starters.count, 5) // System and the four in Plugins/
        for s in starters + starters { XCTAssertTrue(store.restore(s)) }
        XCTAssertEqual(store.profiles.count, 1 + 2 * 7) // the empty first profile, then each starter twice
        XCTAssertFalse(store.profiles.contains(where: Catalog.shared.missing))
        XCTAssertEqual(store.panels.compactMap { $0["name"] as? String }.sorted(), ["Photoshop 도구", "앱 실행"])
    }

    func testStarterComesInTheAppsLanguage() {
        let d = UserDefaults.standard, was = d.string(forKey: "language")
        defer { d.set(was, forKey: "language") }
        func first() -> String? { ((Catalog().raw.first { $0["id"] as? String == "com.adobe.lightroom" }?["starter"] as? [String: Any])?["profiles"] as? [[String: Any]])?.first?["title"] as? String }
        d.set("en", forKey: "language"); XCTAssertEqual(first(), "Library")
        d.set("ko", forKey: "language"); XCTAssertEqual(first(), "라이브러리")
    }

    func testInstallCopiesAPluginAndRefusesOtherFolders() throws {
        let to = FileManager.default.temporaryDirectory.appendingPathComponent("install-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: to) }
        XCTAssertEqual(Catalog.install(repoPlugins.appendingPathComponent("lightroom"), to: to), "Lightroom Classic")
        XCTAssertNotNil(Catalog.install(repoPlugins.appendingPathComponent("lightroom"), to: to), "installing again replaces")
        XCTAssertEqual(Catalog(dirs: [to]).apps.map(\.id), ["com.adobe.lightroom"])
        XCTAssertNil(Catalog.install(repoPlugins, to: to), "a folder without plugin.json")
        XCTAssertNil(Catalog.install(Catalog.dirs[0].appendingPathComponent("system"), to: to), "System is never replaced")
    }

    func testLoaderRefusesNewerSpecAndUserReplacesBundled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, json) in [("new", #"{"spec": 2, "id": "x.new", "name": "New", "apps": []}"#), ("noid", #"{"spec": 1, "name": "No id"}"#),
                             ("lr", #"{"spec": 1, "id": "com.adobe.lightroom", "name": "Mine", "apps": ["a.b"], "later": true}"#)] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            try json.write(to: root.appendingPathComponent(name + "/plugin.json"), atomically: true, encoding: .utf8)
        }
        let c = Catalog(dirs: [Catalog.dirs[0], root])
        XCTAssertNil(c.app("x.new")); XCTAssertEqual(c.app("com.adobe.lightroom")?.name, "Mine") // an unknown field is skipped
        XCTAssertEqual(c.apps.filter { $0.id == "com.adobe.lightroom" }.count, 1)
        if (try? need("photoshop")) != nil { XCTAssertNotNil(Catalog.shared.app("com.adobe.Photoshop"), "a keys-only plugin is an app too"); XCTAssertEqual(Catalog.shared.keys["com.adobe.Photoshop"]?.isEmpty, false) }
        XCTAssertEqual(Catalog(dirs: [Catalog.dirs[0]]).apps.map(\.id), [""], "only System ships inside the app")
    }
}

final class ProfileFileTests: PluginCase {
    func testDial3OnCorePort3Pose() { // a profile seen in use places a dial×3 on Core port 3
        let core = Pose(t: 25, x: 0, y: 0, r: 0, u: "c")
        let p = Board.pose(t: 9, into: Board.ports(core)[3], u: "d")
        XCTAssertEqual([p.x, p.y, p.r], [1, 1, 2])
    }

    func testProfilesOwnModuleBeatsImportedEntryForSameHardware() {
        let store = Store(catalog: Catalog(), url: FileManager.default.temporaryDirectory.appendingPathComponent("dup0-\(UUID()).json"))
        store.hardware = ["": ("CORE", 25), "3": ("BTN", 1)]
        store.setBoard(store.board(store.activeProfile)); store.assign("BTN", ["preset": "own"])
        var p = store.activeProfile
        var a = p["assignments"] as! [String: Any]; a["BTN"] = ["preset": "imported"]; p["assignments"] = a   // an entry keyed by the hardware id itself, as imported profiles have
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dup-\(UUID()).json")
        try! JSONSerialization.data(withJSONObject: ["profiles": [p]]).write(to: url)
        let again = Store(catalog: Catalog(), url: url); again.hardware = store.hardware
        XCTAssertEqual((again.activeProfile["assignments"] as? [String: Any])?.count, 2)
        XCTAssertEqual((again.assignments(again.activeProfile)["BTN"] as? [String: String])?["preset"], "own")
    }
    func testModuleApartFromCoreKeepsAssignments() {
        let store = Store(catalog: Catalog(), url: FileManager.default.temporaryDirectory.appendingPathComponent("apart-\(UUID()).json"))
        store.hardware = ["": ("CORE", 25), "3": ("BTN", 1)]
        let i = store.adopt("3")!; store.assign("BTN", ["preset": "kept"])
        var b = store.board(store.activeProfile); let u = b.modules[i].u
        b.modules[i].x += 10; store.setBoard(b)                                // dragged away from the Core on the board: 설계 전용
        XCTAssertNil(store.board(store.activeProfile).paths()[i])
        func on(_ k: String) -> String? { (store.assignments(store.activeProfile)[k] as? [String: String])?["preset"] }
        XCTAssertEqual(on(u), "kept"); XCTAssertNil(on("BTN"))                 // still assigned, just not connected
        store.assign(u, ["preset": "changed"]); XCTAssertEqual(on(u), "changed") // and assignable while apart
        b.modules[i].x -= 10; store.setBoard(b)
        XCTAssertEqual(on("BTN"), "changed")                                   // put back: the hardware gets it again
    }
    func testBundleRoundTrip() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let s = Store(catalog: Catalog(), url: url)
        let a = s.addProfile(title: "A", app: "x"); s.addProfile(title: "B", app: "y")
        s.activate(a)
        XCTAssertEqual((s.bundle(app: "x", root: false)["profiles"] as? [Any])?.count, 1)
        XCTAssertNil(s.bundle(app: "x", root: false)["root"])
        var all = s.bundle(root: true)
        all["root"] = ["assignments": ["::button1": ["preset": "p"]]]
        let n = s.profiles.count
        XCTAssertTrue(s.restore(all)) // add: new ids, active stays, root untouched
        XCTAssertEqual(s.profiles.count, n * 2)
        XCTAssertEqual(Set(s.profiles.compactMap { $0["id"] as? String }).count, n * 2)
        XCTAssertEqual(s.activeProfile["id"] as? String, a)
        XCTAssertNotEqual(((s.root["assignments"] as? [String: Any])?["::button1"] as? [String: Any])?["preset"] as? String, "p")
        XCTAssertTrue(s.restore(all, replace: true, root: true))
        XCTAssertEqual(s.profiles.count, n)
        XCTAssertEqual(s.activeProfile["id"] as? String, a)
        XCTAssertEqual(((s.root["assignments"] as? [String: Any])?["::button1"] as? [String: Any])?["preset"] as? String, "p")
        XCTAssertFalse(s.restore(["profiles": [["title": "no assignments"]]]))
        s.undo(); XCTAssertEqual(s.profiles.count, n * 2)
    }
    func testRemovedModuleTakesItsNameAlong() {
        let store = Store(catalog: Catalog(), url: FileManager.default.temporaryDirectory.appendingPathComponent("name-\(UUID()).json"))
        store.hardware = ["": ("CORE", 25), "3": ("BTN", 1)]
        let i = store.adopt("3")!
        var b = store.board(store.activeProfile)
        let u = b.modules[i].u
        store.setModuleName(u, "스위치"); XCTAssertEqual(store.moduleName(u), "스위치")
        b.modules.remove(at: i); store.setBoard(b)
        XCTAssertNil(store.activeProfile["moduleNames"])
    }
    func testStackMembersTakeTurnsOnOneModule() {
        let store = Store(catalog: Catalog(), url: FileManager.default.temporaryDirectory.appendingPathComponent("stack-\(UUID()).json"))
        store.hardware = ["": ("CORE", 25), "2": ("ORB", 24), "3": ("BTN", 1)]
        store.assign("ORB", ["preset": "mid"]); store.assign("BTN", ["preset": "b"])
        let host = store.snapshot(store.activeProfile)["2"]!.u
        func on(_ k: String) -> String? { (store.assignments(store.activeProfile)[k] as? [String: String])?["preset"] }
        let second = store.addStackMember(host)                               // attached at once, empty
        XCTAssertNil(on("ORB")); XCTAssertEqual(on("BTN"), "b")
        store.assign("ORB", ["preset": "high"])                               // lands on the attached member, not the host
        XCTAssertEqual(on("ORB"), "high")
        store.switchStack(host, to: 0); XCTAssertEqual(on("ORB"), "mid")
        store.switchStack(host, to: 1); XCTAssertEqual(on("ORB"), "high")
        store.switchStack(host, to: 2); XCTAssertEqual(on("ORB"), "mid")      // wraps: next from the last is the first
        XCTAssertEqual(store.stack(ofMember: second)?.index, 1)
        store.renameStackMember(host, second, "밝은 영역")
        XCTAssertEqual(store.stack(host).names[second], "밝은 영역")
        store.hardware = [:]                                                  // unplugged: the attached member shows under the host's id
        store.switchStack(host, to: 1); XCTAssertEqual(on(host), "high"); XCTAssertNil(on(second))
        store.hardware = ["": ("CORE", 25), "2": ("ORB", 24), "3": ("BTN", 1)]
        store.removeStackMember(host, host)                                   // first one removed: the other takes the host's place
        XCTAssertEqual(store.stack(host).members, [host])                     // one left = a plain module, no stack stored
        XCTAssertNil(store.activeProfile["stacks"])
        XCTAssertEqual(on("ORB"), "high")
        XCTAssertEqual((store.activeProfile["assignments"] as? [String: Any])?.count, 2)
    }
    func testStackIntoAndTakeOutKeepWires() {
        let store = Store(catalog: Catalog(), url: FileManager.default.temporaryDirectory.appendingPathComponent("join-\(UUID()).json"))
        var b = store.board(store.activeProfile)
        b.modules += [Pose(t: 24, x: 2, y: 0, r: 0, u: "A"), Pose(t: 24, x: 4, y: 0, r: 0, u: "B")]
        store.setBoard(b)
        store.assign("A", ["preset": "a"]); store.assign("B", ["preset": "b"])
        func raw(_ k: String) -> String? { ((store.activeProfile["assignments"] as? [String: Any])?[k] as? [String: Any])?["preset"] as? String }
        func onBoard(_ u: String) -> Bool { store.board(store.activeProfile).modules.contains { $0.u == u } }
        store.stackInto("A", "B")                                             // B leaves the board, its wires stay under its own id
        XCTAssertEqual(store.stack("A").members, ["A", "B"]); XCTAssertFalse(onBoard("B"))
        XCTAssertEqual(raw("A"), "a"); XCTAssertEqual(raw("B"), "b")
        store.undo(); XCTAssertTrue(onBoard("B")); XCTAssertNil(store.activeProfile["stacks"])
        store.stackInto("A", "B")
        let out = store.takeOutOfStack("A", "A")!                             // the host goes out: a new id carries its wires, B takes the host's place
        XCTAssertTrue(onBoard(out)); XCTAssertNil(store.activeProfile["stacks"])
        XCTAssertEqual(raw(out), "a"); XCTAssertEqual(raw("A"), "b"); XCTAssertNil(raw("B"))
        store.stackInto("A", out)
        XCTAssertEqual(store.takeOutOfStack("A", out), out)                  // a non-host member keeps its id
        XCTAssertEqual(raw(out), "a"); XCTAssertTrue(onBoard(out))
        XCTAssertNil(store.takeOutOfStack("A", "A"))                          // one left: nothing to take out
    }
    func testRemovingFirstStackMemberKeepsRootWires() {
        let store = Store(catalog: Catalog(), url: FileManager.default.temporaryDirectory.appendingPathComponent("rootstack-\(UUID()).json"))
        var b = store.board(store.activeProfile)
        b.modules += [Pose(t: 24, x: 2, y: 0, r: 0, u: "A")]
        store.setBoard(b)
        let second = store.addStackMember("A")
        store.editingRoot = true; store.assign("A::dial1", ["preset": "r"]) /* unplugged: the attached member shows under the host id */; store.editingRoot = false
        func root(_ k: String) -> String? { ((store.root["assignments"] as? [String: Any])?[k] as? [String: Any])?["preset"] as? String }
        XCTAssertEqual(root(second + "::dial1"), "r")
        store.removeStackMember("A", "A")                                     // member 2 takes the host's id: its root wiring follows
        XCTAssertEqual(root("A::dial1"), "r"); XCTAssertNil(root(second + "::dial1"))
    }
    func testScreenRotationOldZeroMovesToUpright() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func load(_ prefs: [String: Any]) throws -> Any? {
            let u = dir.appendingPathComponent(UUID().uuidString + ".json")
            try JSONSerialization.data(withJSONObject: ["profiles": [], "preferences": prefs]).write(to: u)
            return Store(catalog: Catalog(), url: u).preferences["screenRotation"]
        }
        XCTAssertEqual(try load(["screenRotation": 0]) as? Int, 270)
        XCTAssertEqual(try load(["screenRotation": 90]) as? Int, 90)
        XCTAssertEqual(try load(["screenRotation": 0, "screenRotationFixed": true]) as? Int, 0) // chosen after the fix: kept
        XCTAssertEqual(try load([:]) as? Int, 270)
    }

    func testDesignModeSendsNothingOut() {
        XCTAssertNil(System.sink)
        let engine = Engine(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("mc-dm-\(UUID().uuidString).json"))
        engine.designMode = true
        XCTAssertNotNil(System.sink); XCTAssertTrue(System.open("com.apple.TextEdit")) // picked, not launched
        engine.designMode = false
        XCTAssertNil(System.sink)
    }
}
