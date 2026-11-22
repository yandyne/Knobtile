import Foundation
import CoreV2

// coremon: talk to the Core directly (stop the Monogram service first, it owns the port).
// Prints version, layout and every input event. `coremon raw` also dumps every frame.
setlinebuf(stdout) // output is piped to files during testing
let raw = CommandLine.arguments.contains("raw")
let dev = CoreDevice()
// Hand-rolled so layout nodes print as u, i, t, c (JSONSerialization scrambles key order).
func json(_ v: Any) -> String {
    let order = ["u", "i", "t", "c"]
    switch v {
    case let d as [String: Any]:
        let keys = d.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        return "{" + keys.map { "\"\($0)\":" + json(d[$0]!) }.joined(separator: ",") + "}"
    case let a as [Any]: return "[" + a.map(json).joined(separator: ",") + "]"
    case let s as String: return "\"\(s)\""
    default: return "\(v)"
    }
}
dev.onState = { print("state:", $0) }
dev.onVersion = { print("version:", json($0)) }
dev.onLayout = {
    print("layout:", json($0))
    for id in dev.localIds { dev.getState(localId: id) }
    if let i = CommandLine.arguments.firstIndex(of: "color"), CommandLine.arguments.count > i + 4 {
        let a = CommandLine.arguments[(i + 1)...].compactMap(Int.init) // id r g b
        for s in 0..<3 { dev.setColor(localId: a[0], r: a[1], g: a[2], b: a[3], submodule: s) }
        dev.commitColor(localId: a[0])
    }
}
dev.onFirmwareError = { print("firmware error:", $0) }
dev.onInputs = { for i in $0 { print(i.noop ? "state" : "input", "id=\(i.localId)", i.values) } }
if raw { dev.onRaw = { print("raw:", json($0)) } }
dev.start()
RunLoop.main.run()
