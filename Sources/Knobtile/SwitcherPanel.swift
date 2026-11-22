import SwiftUI
import Engine
import Carbon.HIToolbox

/// 화면 패널 (OSD): what the engine's open panel shows. A list to pick from (icons in a row, or rows when it is long or carries notes) or 맵 보기.
/// Non-activating and mouse-transparent, so the app in front keeps focus; the control that opened it picks on release (Engine.openPanel).
final class SwitcherPanel {
    static let shared = SwitcherPanel()
    private var panel: NSPanel?

    static func make(_ id: String, _ view: some View) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.identifier = .init(id)
        p.contentView = NSHostingView(rootView: view)
        return p
    }
    func show(_ service: ServiceClient) {
        if panel == nil { panel = Self.make("switcher", SwitcherView().environmentObject(service).environmentObject(service.live)) }
        DispatchQueue.main.async { [self] in // after SwiftUI has laid out the new content: the size is taken from it
            guard service.panel != nil, let p = panel, let v = p.contentView, let s = NSScreen.main?.visibleFrame else { return }
            if service.panel?.kind == "map" { p.setContentSize(NSSize(width: s.width * 0.7, height: s.height * 0.7)) } // the board scales itself into this, both axes alike
            else { v.layoutSubtreeIfNeeded(); p.setContentSize(v.fittingSize) }
            p.setFrameOrigin(NSPoint(x: s.midX - p.frame.width / 2, y: s.midY - p.frame.height / 2))
            p.orderFrontRegardless()
        }
    }
    func hide() { panel?.orderOut(nil) }
}

/// 값 알림: the moved control's function and value at the bottom of the screen, gone 1.2 s after the last move.
final class ToastPanel {
    static let shared = ToastPanel()
    private var panel: NSPanel?, hideAt = Date()
    func show(_ service: ServiceClient) {
        if panel == nil { panel = SwitcherPanel.make("toast", ToastView().environmentObject(service.live)) }
        guard let p = panel, let s = NSScreen.main?.visibleFrame else { return }
        if !p.isVisible {
            p.setContentSize(NSSize(width: 400, height: 48))
            p.setFrameOrigin(NSPoint(x: s.midX - 200, y: s.minY + 90))
            p.orderFrontRegardless()
        }
        hideAt = Date() + 1.2
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [self] in if Date() >= hideAt { p.orderOut(nil); service.live.toast = nil } }
    }
}
struct ToastView: View {
    @EnvironmentObject var live: Live
    var body: some View {
        if let t = live.toast {
            HStack(spacing: 12) {
                Text(t.label).fontWeight(.semibold).lineLimit(1)
                if let v = live.value[t.uuid] { // only an app that reports the value gets the bar and the number
                    ProgressView(value: min(max((live.pose[t.uuid]?.angle ?? 0) / 270 + 0.5, 0), 1)).frame(width: 120).tint(.white)
                    Text(String(format: "%g", (v * 100).rounded() / 100)).monospacedDigit()
                }
            }
            .foregroundStyle(.white).padding(.horizontal, 16).frame(width: 400, height: 48)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.8)))
        }
    }
}

struct SwitcherView: View {
    @EnvironmentObject var service: ServiceClient
    var body: some View {
        if let s = service.panel {
            VStack(spacing: 10) {
                if !s.title.isEmpty { Text(s.title).font(.headline).foregroundStyle(.white) }
                if s.kind == "map" {
                    // the same picture as the app's board: positions, turns and proportions as plugged, scaled as one
                    LayoutView(selected: .constant(nil), osd: true).environment(\.colorScheme, .dark)
                    hint(L("놓으면 닫힘 · 만진 컨트롤이 밝게 표시됩니다"))
                } else {
                    if s.items.count <= 8, s.items.allSatisfy({ $0.note.isEmpty && $0.label.count <= 14 }) { strip(s) } else { rows(s) }
                    hint(L("놓으면 \(s.items[s.index].label) · 돌리기 / 다른 버튼 / ← → 이동 · esc 취소"))
                }
            }
            .padding(18).background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.8)))
        }
    }
    private func hint(_ t: String) -> some View { Text(t).font(.caption2).foregroundStyle(.white.opacity(0.6)) }
    private func strip(_ s: Engine.Panel) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(s.items.enumerated()), id: \.offset) { i, item in
                let on = i == s.index
                VStack(spacing: 6) {
                    Group {
                        if let ic = item.app.flatMap(service.appIcon) { Image(nsImage: ic).resizable() }
                        else if item.app != nil { Image(systemName: "square.grid.2x2").resizable().padding(10) }
                        else { Text("\(i + 1)").font(.title2.bold()).frame(maxWidth: .infinity, maxHeight: .infinity).background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.09))) }
                    }.frame(width: 56, height: 56)
                    Text(item.label).font(.caption).lineLimit(1)
                }
                .frame(width: 96).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(on ? 0.16 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white, lineWidth: on ? 2 : 0))
                .foregroundStyle(on ? .white : .white.opacity(0.6))
            }
        }
    }
    /// Long lists: at most 12 rows around the chosen one. The note column is the key chord of a 키 입력 item, so the list doubles as a cheat sheet.
    private func rows(_ s: Engine.Panel) -> some View {
        let from = min(max(s.index - 6, 0), max(s.items.count - 12, 0))
        return VStack(spacing: 2) {
            ForEach(Array(s.items.enumerated()).dropFirst(from).prefix(12), id: \.offset) { i, item in
                HStack(spacing: 16) { Text(item.label).lineLimit(1); Spacer(); Text(item.note).font(.caption.monospaced()) }
                    .padding(.vertical, 5).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(i == s.index ? 0.16 : 0)))
                    .foregroundStyle(i == s.index ? .white : .white.opacity(0.6))
            }
        }.frame(width: 320)
    }
}

/// 상시 맵: the board with what every control does now, always on screen in a corner (환경설정, ⌃⌥M, or a control's "상시 맵 켜기/끄기").
/// Half transparent at rest; sharp for 3 s when a layer, page or 묶음 changes or a control is touched. Mouse-transparent like the other panels.
@MainActor final class MapPanel {
    static let shared = MapPanel()
    private var panel: NSPanel?, seen: [String: Int] = [:], seenProfile = "", dimAt = Date()
    /// After every store change: show / hide / move it, and outline the stacks whose layer changed.
    func update(_ service: ServiceClient) {
        guard service.preferences["mapPinned"].bool == true else { panel?.orderOut(nil); return }
        if panel == nil { panel = SwitcherPanel.make("map", MapView().environmentObject(service).environmentObject(service.live)) }
        guard let p = panel, let s = NSScreen.main?.visibleFrame else { return }
        let size = NSSize(width: 400, height: 330), c = service.preferences["mapCorner"].int ?? 3 // corners clockwise from the top left
        p.setContentSize(size)
        p.setFrameOrigin(NSPoint(x: c == 1 || c == 2 ? s.maxX - size.width - 16 : s.minX + 16, y: c < 2 ? s.maxY - size.height - 16 : s.minY + 16))
        let now = Dictionary(service.stackList.map { ($0.host, $0.stack.index) }, uniquingKeysWith: { a, _ in a }), id = service.activeProfile?["id"].string ?? ""
        let moved = id == seenProfile ? Set(now.filter { seen[$0.key] != nil && seen[$0.key] != $0.value }.keys) : []
        let fresh = !p.isVisible || id != seenProfile || !moved.isEmpty
        seen = now; seenProfile = id
        if !p.isVisible { p.alphaValue = 0.55; p.orderFrontRegardless() }
        if !moved.isEmpty {
            service.mapFlash = moved
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if service.mapFlash == moved { service.mapFlash = [] } }
        }
        if fresh { wake() }
    }
    func wake() {
        guard let p = panel, p.isVisible else { return }
        p.animator().alphaValue = 1
        dimAt = Date() + 3
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.05) { [self] in if Date() >= dimAt { p.animator().alphaValue = 0.55 } }
    }
    nonisolated(unsafe) private static var fire: (() -> Void)? // set once, called on the main thread by the hot key handler
    /// ⌃⌥M anywhere. shortcut: the chord is fixed, add a recorder in 환경설정 when it collides with another app's.
    static func hotKey(_ f: @escaping () -> Void) {
        guard fire == nil else { return }
        fire = f
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), ref: EventHotKeyRef?
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in MapPanel.fire?(); return noErr }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4B4E4254, id: 1), GetApplicationEventTarget(), 0, &ref)
    }
}
struct MapView: View {
    @EnvironmentObject var service: ServiceClient
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text([service.appName(service.activeProfile?["app"].string ?? ""), service.activeProfile?["title"].string ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")).fontWeight(.semibold).lineLimit(1)
                Spacer()
                ForEach(service.stackList, id: \.host) { e in Text("\(e.name(e.stack.index)) \(e.stack.index + 1)/\(e.stack.members.count)").foregroundStyle(service.mapFlash.contains(e.host) ? .yellow : .white) } // the layer in use: the question the map is there to answer
            }.font(.system(size: 11)).foregroundStyle(.white).padding(.horizontal, 6)
            LayoutView(selected: .constant(nil), osd: true, pinned: true).environment(\.colorScheme, .dark)
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.84)))
    }
}
