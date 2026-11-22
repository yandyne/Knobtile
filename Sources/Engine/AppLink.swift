import Foundation
import Network

/// Connections to plugins (Docs/plugin-spec-v1.md). Two kinds, one line format:
/// "tcp": the app's side listens on 127.0.0.1 and we connect (an optional second port only carries lines back to us);
/// "run": a helper program we start, lines over its stdin and stdout.
public final class AppLink {
    let catalog: Catalog
    private var conns: [String: NWConnection] = [:]
    private var helpers: [String: (proc: Process, stdin: FileHandle)] = [:]
    // The main queue: send() and tryConnect() run there, and the socket callbacks change the same dictionaries.
    // On a queue of their own they raced with a dial turn and crashed the app (2026-11-15 14:04, EXC_BAD_ACCESS on "applink").
    private let queue = DispatchQueue.main

    public var onConnected: ((String, Bool) -> Void)?   // plugin id, connected
    public var onValue: ((String, String, Double, [Double]?) -> Void)? // plugin id, name, the value the app reports, its own range when that replaces ours (a JPEG's temperature)
    public var onFunction: ((String, String, String) -> Void)? // plugin id, line, label: a function that exists only at run time ("@function", e.g. a develop preset)
    public var onScreen: ((String, String) -> Void)?    // plugin id, screen key the app is on ("@screen")
    private func up(_ id: String) -> Bool { helpers[id] != nil || conns.contains { $0.key.hasPrefix(id + "/") && $0.value.state == .ready } }
    private func report(_ id: String) { // a plugin can have two sockets: linked while any is up
        let ok = up(id)
        if linked[id] != ok { linked[id] = ok; onConnected?(id, ok) } // only a change: a port nobody listens on fails every 5 s and re-asked every value each time
    }
    private var linked: [String: Bool] = [:]
    /// "@hello" sent and nothing back for 3 s = the socket is open but nobody reads it (seen 2026-11-15: Lightroom ran the plugin
    /// twice and we stayed attached to the run that had already ended), or the helper hangs: start over.
    /// Any line counts as the answer, so a plugin older than the greeting still works.
    private var greeted: [String: Date] = [:]
    private func hello(_ id: String) {
        write(id, "@hello\t\(Catalog.specVersion)")
        let t = Date(); greeted[id] = t
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, greeted[id] == t else { return }
            greeted[id] = nil
            NSLog("applink: %@ gave no answer for 3 s, reconnecting", id)
            for (k, c) in conns where k.hasPrefix(id + "/") { conns[k] = nil; c.cancel() }
            if let h = helpers.removeValue(forKey: id) { try? h.stdin.close(); h.proc.terminate() }
            report(id); retry(id)
        }
    }
    public init(catalog: Catalog) { self.catalog = catalog }

    /// Open the plugin's connection if it has one (called when its profile becomes active, its app comes to front, or a line is to be sent).
    private var wanted = ""   // plugin id of the active profile; failed connections retry while it stays wanted
    public func tryConnect(app id: String) {
        wanted = id
        if System.dry != nil { return } // rehearsal: never take the plugin's one socket from the real app
        guard let app = catalog.app(id) else { return }
        let tcp = app.connections.filter { $0["type"] as? String == "tcp" }
        for c in app.connections where c["type"] as? String == "run" { start(id, c) }
        for c in tcp {
            guard let port = (c["port"] as? NSNumber)?.uint16Value, let p = NWEndpoint.Port(rawValue: port), let name = c["name"] as? String else { continue }
            let key = "\(id)/\(name)"
            if let e = conns[key] { // a just-started connection is still .setup: opening a second one here left the plugin reading the first while we wrote to the second
                if case .failed = e.state {} else if case .cancelled = e.state {} else { continue }
            }
            let conn = NWConnection(host: "127.0.0.1", port: p, using: .tcp)
            conn.stateUpdateHandler = { [weak self] st in
                guard let self, self.conns[key] === conn else { conn.cancel(); return } // a replaced connection must not clear or report for its successor
                if case .failed = st { self.conns[key] = nil; self.report(id); self.retry(id) }
                if case .cancelled = st { self.conns[key] = nil }
                if case .waiting = st { self.conns[key] = nil; conn.cancel(); self.report(id); self.retry(id) } // nothing listening yet (plugin not started)
                if case .ready = st {
                    NSLog("applink: %@ connected on %d", key, port); self.report(id); self.drain(conn, id, key)
                    // greet once every socket is up: the answer comes back on the values socket when there is one
                    if tcp.allSatisfy({ self.conns["\(id)/\($0["name"] as? String ?? "")"]?.state == .ready }) { self.hello(id) }
                }
            }
            conns[key] = conn
            conn.start(queue: queue)
        }
    }

    private func retry(_ id: String) { // the app's plugin may start later than we do; a helper that died starts again
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in if self?.wanted == id { self?.tryConnect(app: id) } }
    }

    private func drain(_ c: NWConnection, _ id: String, _ key: String, rest: String = "") {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] d, _, done, _ in
            var lines = (rest + (d.flatMap { String(data: $0, encoding: .utf8) } ?? "")).components(separatedBy: "\n")
            let tail = lines.removeLast() // a line cut in half waits for its other half
            for l in lines where !l.isEmpty { self?.received(id, l) }
            if done { c.cancel(); if self?.conns[key] === c { self?.conns[key] = nil; self?.report(id); self?.retry(id) } } else { self?.drain(c, id, key, rest: tail) }
        }
    }

    /// A helper program: `command` runs in the plugin's folder (first item absolute, or relative to that folder), until we close its stdin.
    private func start(_ id: String, _ c: [String: Any]) {
        guard helpers[id] == nil, let cmd = c["command"] as? [String], let first = cmd.first, let dir = c["dir"] as? String else { return }
        signal(SIGPIPE, SIG_IGN) // a dead helper must not kill us; write(contentsOf:) reports the error instead
        let p = Process(), i = Pipe(), o = Pipe(), e = Pipe(), folder = URL(fileURLWithPath: dir)
        p.currentDirectoryURL = folder
        p.executableURL = URL(fileURLWithPath: first, relativeTo: folder)
        p.arguments = Array(cmd.dropFirst())
        p.standardInput = i; p.standardOutput = o; p.standardError = e
        var rest = ""
        o.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                var lines = (rest + String(decoding: d, as: UTF8.self)).components(separatedBy: "\n")
                rest = lines.removeLast()
                for l in lines where !l.isEmpty { self?.received(id, l) }
            }
        }
        e.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            NSLog("plugin %@: %@", id, String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        p.terminationHandler = { [weak self] p in DispatchQueue.main.async {
            guard let self, self.helpers[id]?.proc === p else { return }
            self.helpers[id] = nil; self.greeted[id] = nil; self.report(id); self.retry(id)
        } }
        do { try p.run() } catch { NSLog("plugin %@: cannot start %@: %@", id, first, "\(error)"); return }
        helpers[id] = (p, i.fileHandleForWriting)
        report(id); hello(id)
    }

    private func received(_ id: String, _ l: String) {
        greeted[id] = nil
        let f = l.components(separatedBy: "\t")
        switch f[0] {
        case "@hello": break
        case "@screen": if f.count > 1 { onScreen?(id, f[1]) }
        case "@function": if f.count > 2 { onFunction?(id, f[1], f[2]) }
        case "@key": // only into the plugin's own app: a plugin must never type into whatever else is in front
            if f.count > 1, let front = System.frontBundle?.lowercased(), catalog.app(id)?.processIdentifiers.contains(front) == true {
                System.keyTap(f[1], f.count > 2 ? f[2].components(separatedBy: ",").filter { !$0.isEmpty } : [])
            }
        case "!": NSLog("plugin %@: %@", id, f.dropFirst().joined(separator: " "))
        default: // "name \t value [\t min \t max]"; lines we do not know (a newer spec, a helper's banner) are skipped
            if !f[0].hasPrefix("@"), f.count == 2 || f.count == 4, let v = Double(f[1]) { let r = f.dropFirst(2).compactMap(Double.init); onValue?(id, f[0], v, r.count == 2 ? r : nil) }
        }
    }

    private func write(_ id: String, _ line: String) {
        let d = Data((line + "\n").utf8)
        // shortcut: a helper that stops reading while it stays alive blocks this write once its pipe is full (4–64 KB of lines); write off the main queue if a plugin ever does that
        if let h = helpers[id] { do { try h.stdin.write(contentsOf: d) } catch { NSLog("plugin %@: write failed: %@", id, "\(error)") }; return }
        guard let name = catalog.app(id)?.connections.first(where: { $0["receive"] as? Bool != true })?["name"] as? String, let conn = conns["\(id)/\(name)"] else { return }
        conn.send(content: d, completion: .contentProcessed { e in if let e { NSLog("applink send: %@", "\(e)") } })
    }

    func send(app id: String, input: String, operation: String, params: [Any], range: [Double]?) {
        guard let app = catalog.app(id) else { return }
        guard !app.connections.isEmpty else { NSLog("no connection for %@", id); return }
        if let dry = System.sink { dry("send \(app.name): \(input) \(operation) \(params.map { "\($0)" }.joined(separator: ","))"); return }
        if !up(id) { tryConnect(app: id) }
        let line = Self.line(input: input, operation: operation, params: params, range: range ?? app.inputs[input]?.range)
        write(id, line)
    }

    /// A control line ("@screen \t key"). False when the plugin is not connected (nothing is queued).
    @discardableResult func control(app id: String, _ line: String, quiet: Bool = false) -> Bool {
        guard let app = catalog.app(id), !app.connections.isEmpty else { return false }
        if let dry = System.sink { if !quiet { dry("send \(app.name): " + line.replacingOccurrences(of: "\t", with: " ")) }; return !quiet }
        guard up(id) else { return false }
        write(id, line)
        return true
    }

    /// name, op, value, min, max separated by tabs; a function without a value is its name alone. The value is the real one, never the 0–255 hardware value.
    static func line(input: String, operation: String, params: [Any], range: [Double]?) -> String {
        if operation.isEmpty && params.isEmpty { return input }
        return ([input, operation, params.first.map { "\($0)" } ?? ""] + (range ?? []).map { "\($0)" }).joined(separator: "\t")
    }
}
