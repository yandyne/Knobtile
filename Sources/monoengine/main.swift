import Foundation
import AppKit
import Engine

// monoengine: headless native engine (no Monogram service). Stop the service first; it owns the serial port.
setlinebuf(stdout)
let app = NSApplication.shared // needed for NSWorkspace notifications and event posting
let engine = Engine()
engine.onLayout = { print("layout:", $0.map { "\($0)" } ?? "none") }
engine.device.onRaw = { m in if m["in_noop"] == nil { print("rx:", m) } }
engine.onPreview = { print("preview:", $0) }
engine.onInput = { ins in for i in ins where !i.noop { print("input id=\(i.localId)", i.values) } }
print("profiles:", engine.store.profiles.map { $0["title"] as? String ?? "" }, "active:", engine.store.activeProfile["title"] ?? "")
print("apps:", engine.catalog.apps.count)
engine.start()
app.run()
