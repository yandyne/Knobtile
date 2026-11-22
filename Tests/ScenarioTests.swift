import XCTest
@testable import Engine

/// Rehearsal of a whole session on the console alone, on a copy of a real state file (KNOBTILE_STATE, else skipped).
/// Nothing reaches the Mac: System.dry records what each press or turn would have done. The report goes to KNOBTILE_REPORT.
/// Hardware is rebuilt from the active profile's board, so every control the profiles name exists.
final class ScenarioTests: PluginCase {
    private var e: Engine!
    private var acts: [String] = []
    private var report: [String] = []
    private var problems: [String] = []
    private var hw: [String: String] = [:] // profile-side module uuid → hardware uuid (changes with the profile)

    private func wait(_ s: Double) { RunLoop.main.run(until: Date() + s) }
    private var title: String { (e.store.activeProfile["title"] as? String ?? "?") }
    private func rt(_ u: String) -> ModuleRuntime? { // "v:B0770001::button1" or "::button1" (Core)
        let parts = u.components(separatedBy: "::"), snap = e.store.snapshot(e.store.activeProfile)
        guard let path = snap.first(where: { $0.value.u == parts[0] || (parts[0].isEmpty && $0.key.isEmpty) })?.key, let h = hw[path] else { return nil }
        return e.runtimes[parts.count > 1 ? h + "::" + parts[1] : h]
    }
    private func step(_ what: String, expect: String? = nil, profile: String? = nil, _ body: () -> Void) {
        acts = []; body(); wait(0.15)
        let got = acts.joined(separator: " ; ")
        var line = "\(what)  →  \(got.isEmpty ? "(아무 일 없음)" : got)   [프로필: \(title)]"
        if let expect, !got.contains(expect) { line += "   ✗ 기대: \(expect)"; problems.append(line) }
        if let profile, profile != title { line += "   ✗ 기대 프로필: \(profile)"; problems.append(line) }
        report.append(line)
    }
    private func feed(_ u: String, _ raw: (ModuleRuntime) -> [Int]) {
        guard let r = rt(u) else { problems.append("컨트롤 없음: \(u) (프로필 \(title))"); return }
        e.handle(r.sub, raw(r), noop: false)
    }
    private func down(_ u: String) { feed(u) { $0.sub.kind == .button ? [1] : [1, 0, 0] } }
    private func up(_ u: String) { feed(u) { $0.sub.kind == .button ? [0] : [0, 0, 0] } }
    private func press(_ u: String) { down(u); wait(0.05); up(u); wait(0.45) }            // past the double-click wait (250 ms)
    private func double(_ u: String) { down(u); up(u); wait(0.08); down(u); up(u); wait(0.1) }
    private func hold(_ u: String, _ s: Double = 1.0) { down(u); wait(s); up(u); wait(0.1) }
    /// ticks: raw encoder ticks, 8 at a time (a control with sensitivity 4 acts once per 32)
    private func turn(_ u: String, _ ticks: Int, held: Bool = false) {
        for _ in 0..<abs(ticks) / 8 { feed(u) { $0.sub.kind == .orbiter ? [8 * ticks.signum(), 0, 0] : [held ? 1 : 0, 8 * ticks.signum(), 0] }; wait(0.02) }
    }
    /// Steps the open list to the item whose label contains `label` (as turning the dial would); says so when there is none.
    private func pick(_ label: String, by other: String) {
        guard let p0 = e.panel else { problems.append("목록이 열리지 않아 '\(label)'을 고를 수 없음 (프로필 \(title))"); return }
        var n = 0
        for _ in 0..<p0.items.count { if let p = e.panel, p.items[p.index].label.contains(label) { break }; down(other); up(other); n += 1 }
        if let p = e.panel, !p.items[p.index].label.contains(label) { problems.append("목록에 '\(label)' 없음: \(p0.items.map(\.label).joined(separator: ", "))") }
        else { report.append("    다른 버튼 \(n)번 눌러 '\(label)' 선택") }
    }
    private func front(_ bundle: String) { System.dryFront = bundle; e.frontmost(bundle: bundle); wait(0.1) }

    private func tree(_ snap: [String: (u: String, t: Int)], _ path: String, _ n: inout Int) -> [String: Any] {
        let id = n; n += 1
        let u = path.isEmpty ? "CORE" : "HW\(id)"; hw[path] = u
        let kids = snap.keys.filter { $0.hasPrefix(path.isEmpty ? "" : path + "/") && $0 != path && !$0.dropFirst(path.isEmpty ? 0 : path.count + 1).contains("/") && !$0.isEmpty }
        var c: [Any] = Array(repeating: NSNull(), count: 8)
        for k in kids { if let port = Int(k.split(separator: "/").last!) { c[port] = tree(snap, k, &n) } }
        return ["u": u, "i": id, "t": snap[path]!.t, "c": c]
    }

    private func run(auto: Bool, bring: Bool) throws {
        guard let src = ProcessInfo.processInfo.environment["KNOBTILE_STATE"] else { throw XCTSkip("set KNOBTILE_STATE to a copy of state.json") }
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: src))) as? [String: Any])
        var prefs = state["preferences"] as? [String: Any] ?? [:]
        prefs["autoProfileSwitchingEnabled"] = auto; prefs["activateAppOnProfile"] = bring; prefs["mapPinned"] = false
        state["preferences"] = prefs
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scenario-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        acts = []; report = ["", "===== 자동 전환 \(auto ? "켬" : "끔") · 프로필 옮기면 앱 앞으로 \(bring ? "켬" : "끔") ====="]; hw = [:]
        System.dry = { [weak self] a in self?.acts.append(a) }; System.dryFront = "com.apple.finder"
        defer { System.dry = nil; System.dryFront = nil }
        e = Engine(storeURL: url)
        var n = 0
        e.device.onLayout?(tree(e.store.snapshot(e.store.activeProfile), "", &n)); wait(0.2)
        XCTAssertGreaterThan(e.runtimes.count, 10, "hardware did not bind")
        let lr = "com.adobe.LightroomClassicCC7", ps = "com.adobe.Photoshop", rs = "com.blackmagic-design.DaVinciResolve", c1 = "com.captureone.captureone16"
        let B = "v:B0770001::button", D1 = "v:D1A10001::dial", D2 = "v:D1A10002::dial", O = "v:0B170001"

        // 1. nothing running, Finder in front
        step("시작: Finder가 앞", profile: auto ? "기본" : nil) { front("com.apple.finder") }
        if !auto { step("Core 길게 → 프로필 고르기에서 기본 선택 (자동 전환 꺼짐)") { e.dispatch("ACTIVATE_BUNDLE:") } }
        step("기본: 버튼1 누름", expect: "media audio_play") { press(B + "1") }
        step("기본: 버튼1 두 번", expect: "media audio_next") { double(B + "1") }
        step("기본: 다이얼1 오른쪽 3틱 (음량)", expect: "volume") { turn(D1 + "1", 64) }
        step("기본: Orbiter 돌림 (스크롤)", expect: "scroll") { turn(O, 64) }
        // 2. launch Lightroom from the list
        step("기본: 버튼3 길게 → 앱 실행 목록") { down(B + "3"); wait(0.9) }
        report.append("    목록: \(e.panel?.items.map(\.label).joined(separator: ", ") ?? "✗ 열리지 않음") · 선택 \(e.panel.map { $0.items[$0.index].label } ?? "-")")
        if e.panel == nil { problems.append("기본: 버튼3 길게 눌러도 앱 실행 목록이 열리지 않음") }
        step("    목록 열린 채 Orbiter 오른쪽 8틱") { turn(O, 8) }
        report.append("    선택: \(e.panel.map { $0.items[$0.index].label } ?? "-")")
        if !acts.isEmpty || e.panel?.index != 1 { problems.append("목록이 열린 채 Orbiter를 돌리면 목록이 한 칸 가야 함: \(acts), 선택 \(e.panel?.index ?? -1)") }
        step("    목록 열린 채 다이얼1 왼쪽 8틱") { turn(D1 + "1", -8) }
        if !acts.isEmpty || e.panel?.index != 0 { problems.append("목록이 열린 채 다이얼을 돌리면 목록이 한 칸 가야 함: \(acts), 선택 \(e.panel?.index ?? -1)") }
        step("    목록 열린 채 버튼2 누름 (앞으로)") { down(B + "2"); up(B + "2") }
        report.append("    선택: \(e.panel.map { $0.items[$0.index].label } ?? "-")")
        if e.panel?.index != 1 { problems.append("목록이 열린 채 버튼2는 앞으로 한 칸: 선택 \(e.panel?.index ?? -1)") }
        pick("Lightroom Classic", by: B + "1")
        step("    버튼3 뗌 → Lightroom 실행", expect: "open " + lr) { up(B + "3") }
        step("Lightroom이 앞으로 옴", profile: auto ? nil : "기본") { front(lr) }
        if !["라이브러리", "현상"].contains(title) {
            report.append("    ✗ Lightroom이 떴는데 프로필은 \(title)"); if auto { problems.append("자동 전환 켬: Lightroom이 앞에 와도 프로필이 \(title)") }
            step("    Core 버튼2 두 번 (다음 프로필 묶음)") { double("::button2") }
            var guardN = 0; while !["라이브러리", "현상"].contains(title), guardN < 8 { double("::button2"); guardN += 1 }
            report.append("    Core 두 번 누름 \(guardN + 1)회 뒤 프로필: \(title)")
        }
        // 3. library
        step("Lightroom 창 제목이 라이브러리", profile: "라이브러리") { e.screenDetected(app: "com.adobe.lightroom", "library") }
        step("라이브러리: Orbiter 2틱 (사진 넘기기)", expect: "selectphoto") { turn(O, 64) }
        step("라이브러리: 버튼1 (채택)", expect: "flag = pick") { press(B + "1") }
        step("라이브러리: 다이얼1 돌림 (별점)", expect: "togglerating") { turn(D1 + "1", 64) }
        step("라이브러리: 다이얼(2-2) 누름 (채택하고 다음)", expect: "flag = pick_next") { press(D2 + "2") }
        step("라이브러리: 다이얼(2-2) 두 번 (제외하고 다음)", expect: "flag = reject_next") { double(D2 + "2") }
        step("라이브러리: 다이얼(2-3) 누름 (현상 모듈로)", expect: "key d") { press(D2 + "3") }
        step("Lightroom 창 제목이 현상", profile: "현상") { e.screenDetected(app: "com.adobe.lightroom", "develop") }
        // 4. develop
        for name in ["톤", "질감", "색"] {
            let st = e.store.stack("v:D1A10001")
            report.append("    현상 층: \(st.index + 1)/\(st.members.count)")
            step("현상(\(name)?): 다이얼(1-1) 2틱", expect: "send Lightroom") { turn(D1 + "1", 64) }
            step("현상: 다이얼(1-1) 두 번 (초기화)", expect: "= 0.0") { double(D1 + "1") }
            step("현상: 버튼1 (다음 층)") { press(B + "1") }
        }
        step("현상: 색온도 2틱", expect: "Temperature") { turn(D2 + "1", 64) }
        step("현상: 노출 2틱", expect: "Exposure") { turn(D2 + "3", 64) }
        step("현상: 버튼2 누름 (전/후)", expect: "key \\") { press(B + "2") }
        step("현상: 버튼2 두 번 (자동 WB)", expect: "WhiteBalance = Auto") { double(B + "2") }
        step("현상: 버튼2 길게 (설정 복사)", expect: "settings = copy") { hold(B + "2") }
        step("현상: 버튼3 길게 (설정 붙여넣기)", expect: "settings = paste") { hold(B + "3") }
        step("현상: Orbiter 돌림 (사진 넘기기)", expect: "selectphoto") { turn(O, 64) }
        // 5. pages on the Core buttons
        step("현상: Core 버튼1 누름 (이전 페이지 · Lightroom에 보내는 ⌥⌘1은 기기가 열려 있을 때만 나가 여기서는 안 보임)", profile: "라이브러리") { press("::button1") }
        step("라이브러리: Core 버튼2 누름 (다음 페이지)", profile: "현상") { press("::button2") }
        // 6. to another app with the console only
        step("현상: Core 버튼2 길게 → 프로필 고르기") { down("::button2"); wait(1.0) }
        report.append("    목록: \(e.panel?.items.map(\.label).joined(separator: ", ") ?? "✗ 열리지 않음")")
        if e.panel == nil { problems.append("Core 버튼2를 길게 눌러도 프로필 고르기가 열리지 않음") }
        step("    Core 버튼1 누름 (목록 이동)") { down("::button1"); up("::button1") }
        report.append("    선택: \(e.panel.map { $0.items[$0.index].label } ?? "-")")
        pick("모든 앱", by: "::button1")
        report.append("    기본으로 맞춤: \(e.panel.map { $0.items[$0.index].label } ?? "-")")
        step("    Core 버튼2 뗌", profile: "기본") { up("::button2") }
        step("기본: 버튼3 길게 → Photoshop 고르고 뗌", expect: "open " + ps) {
            down(B + "3"); wait(0.9); pick("Photoshop", by: B + "1"); up(B + "3") }
        step("Photoshop이 앞으로 옴", profile: auto ? "Photoshop" : nil) { front(ps) }
        if title != "Photoshop" { var g = 0; while title != "Photoshop", g < 8 { double("::button2"); g += 1 }; report.append("    Core 두 번 누름 \(g)회 뒤: \(title)") }
        step("Photoshop: 버튼1 (브러시)", expect: "key b") { press(B + "1") }
        step("Photoshop: 다이얼(1-1) 오른쪽 (브러시 크기)", expect: "key ]") { turn(D1 + "1", 64) }
        step("Photoshop: Orbiter 돌림 (확대)", expect: "scroll") { turn(O, 64) }
        step("Photoshop: 버튼3 길게 → 도구 목록, 뗌") { down(B + "3"); wait(0.9); up(B + "3") }
        // 7. back and forth
        step("Lightroom으로 돌아감", profile: auto ? "현상" : nil) { front(lr) }
        step("Photoshop으로", profile: auto ? "Photoshop" : nil) { front(ps) }
        step("바탕화면(Finder) 누름", profile: auto ? "기본" : nil) { front("com.apple.finder") }
        step("Resolve가 앞", profile: auto ? nil : nil) { front(rs) }
        report.append("    Resolve 프로필: \(title)")
        if ["편집", "컬러"].contains(title) {
            step("Resolve 편집 페이지 감지", profile: "편집") { e.screenDetected(app: rs, "edit") }
            step("편집: 다이얼(2-2) 누름 (컬러 페이지로)", expect: "pageColor") { press(D2 + "2") }
            step("Resolve 컬러 페이지 감지", profile: "컬러") { e.screenDetected(app: rs, "color") }
            step("컬러: 다이얼(1-1) 2틱 (게인)", expect: "slopeMaster") { turn(D1 + "1", 64) }
        }
        step("Capture One이 앞", profile: auto ? "Capture One" : nil) { front(c1) }
        if title == "Capture One" { step("Capture One: 다이얼(2-3) 2틱 (노출)", expect: "exposure") { turn(D2 + "3", 64) } }
        // 8. profile picked on the console while its app is behind
        step("Finder가 앞인 채 Core 두 번 (다음 묶음)") { front("com.apple.finder"); double("::button2") }
        report.append("    → 프로필 \(title), 앱: \(e.store.activeProfile["app"] as? String ?? "")")
    }

    func testWholeSessionOnTheConsole() throws {
        var all: [String] = [], bad: [String] = []
        for (auto, bring) in [(true, true), (false, false)] {
            try run(auto: auto, bring: bring)
            all += report; bad += problems.map { "[자동 \(auto ? "켬" : "끔")] " + $0 }; problems = []
        }
        all += ["", "===== 어긋난 곳 \(bad.count)개 ====="] + bad
        if let out = ProcessInfo.processInfo.environment["KNOBTILE_REPORT"] { try all.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8) }
        print(all.joined(separator: "\n"))
    }
}
