import SwiftUI
import Engine
import Combine

/// Remote control for development (window screenshots, picking a control or a profile without a mouse), sent as the
/// distributed notification "Knobtile.snapshot". Debug builds only: in a released app any local process could drive it.
var snapshotNotes: AnyPublisher<Notification, Never> {
    #if DEBUG
    DistributedNotificationCenter.default().publisher(for: .init("Knobtile.snapshot")).eraseToAnyPublisher()
    #else
    Empty().eraseToAnyPublisher()
    #endif
}

@main
struct KnobtileApp: App {
    init() {
        NSWindow.allowsAutomaticWindowTabbing = false // every tab would be the same window again: one device, one set of profiles
    }
    @StateObject private var service = ServiceClient()
    @Environment(\.openWindow) private var openWindow

    @AppStorage("alwaysOnTop") private var onTop = false
    @AppStorage("language") private var language = "" // read here so the menus are built again when it changes
    private func float() {
        for w in NSApp.windows where w.identifier?.rawValue.hasPrefix("main") == true { w.level = onTop ? .floating : .normal }
    }

    var body: some Scene {
        let _ = language
        WindowGroup("Knobtile", id: "main") {
            ContentView()
                .environmentObject(service)
                .environmentObject(service.live)
                .onAppear { service.connect(); DisplayLink.shared.start(service); MapPanel.hotKey { service.dispatch("TOGGLE_MAP", [:]) } }
                .onAppear { if UserDefaults.standard.bool(forKey: "hideDock") { NSApp.setActivationPolicy(.accessory) } }
                .onAppear { DispatchQueue.main.async { float() } } // async: the window is not in NSApp.windows yet
                .onChange(of: onTop) { float() }
                .onChange(of: service.previewRequests) { // Core button held: show the app; openWindow on a WindowGroup would add a second window each time
                    let w = NSApp.windows.first { $0.contentView != nil && $0.identifier?.rawValue.hasPrefix("main") == true }
                    if let w, w.isVisible, NSApp.isActive { return } // already up: holding both buttons (or repeats) must not keep yanking focus
                    if let w { w.makeKeyAndOrderFront(nil) } else { openWindow(id: "main") }
                    NSApp.activate(ignoringOtherApps: true)
                }
                // debug: `Knobtile.snapshot` distributed notification with {"path"} writes the main window as PNG (no screen-recording permission needed)
                .onReceive(snapshotNotes) { n in
                    if let d = n.userInfo?["dispatch"] as? String { service.dispatch(d, [:]) } // debug: drive the engine (e.g. PROFILE_SWITCHER) without a Core
                    if let r = n.userInfo?["root"] as? String { service.editingRoot = r == "1" } // debug: 루트 프로필 편집 on/off
                    guard let path = n.userInfo?["path"] as? String else { return }
                    NSLog("snapshot: windows %@", NSApp.windows.map { "\($0.identifier?.rawValue ?? "-") vis=\($0.isVisible) cv=\($0.contentView != nil) \($0.frame)" }.joined(separator: " | "))
                    guard let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && (n.userInfo?["panel"] == nil) == ($0.identifier?.rawValue != "switcher") }) else { return }
                    if let wd = n.userInfo?["width"] as? Double, let ht = n.userInfo?["height"] as? Double { w.setContentSize(NSSize(width: wd, height: ht)); w.layoutIfNeeded() }
                    guard let v = w.contentView?.superview ?? w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return } // superview = frame view: title bar + toolbar + window background
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    // also dump the hardware layout tree next to it (debug: lets us read port/type ids without stopping the app)
                    if JSONSerialization.isValidJSONObject(service.layout.any) { try? JSONSerialization.data(withJSONObject: service.layout.any, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path + ".layout.json")) } // null without a Core
                }
        }
        .defaultSize(width: 1000, height: 640)
        .commands { CommandMenu(L("프로필")) { Toggle(L("루트 프로필 편집"), isOn: $service.editingRoot).keyboardShortcut("r", modifiers: [.command, .option])
            Button(L("상시 맵 켜기/끄기 (⌃⌥M)")) { service.dispatch("TOGGLE_MAP", [:]) } } }
        MenuBarExtra("Knobtile", systemImage: "dial.medium") {
            // by 묶음 like the sidebar: 앱 없음 first, then apps in list order; inside one, the screen-less default first
            let apps = service.profiles.map { $0["app"].string ?? "" }.reduce(into: [String]()) { if !$0.contains($1) { $1.isEmpty ? $0.insert($1, at: 0) : $0.append($1) } }
            ForEach(apps, id: \.self) { a in
                let mine = service.profiles.filter { ($0["app"].string ?? "") == a }, head = mine.first { ($0["screen"].string ?? "").isEmpty }?["id"].string
                Section(a.isEmpty ? L("앱 없음") : service.appName(a)) {
                    ForEach(mine.filter { $0["id"].string == head } + mine.filter { $0["id"].string != head }, id: \.["id"].string) { p in
                        Button((p["id"] == service.activeProfile?["id"] ? "✓ " : "    ") + (p["title"].string ?? "")) {
                            service.dispatch("ACTIVATE_PROFILE", ["profileId": p["id"].string ?? ""])
                        }
                    }
                }
            }
            Divider()
            Button(L("상시 맵 켜기/끄기 (⌃⌥M)")) { service.dispatch("TOGGLE_MAP", [:]) }
            Button(L("Knobtile 열기")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Button(L("종료")) { NSApp.terminate(nil) }
        }
    }
}
