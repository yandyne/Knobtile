import Foundation

/// A module on the design board: type, box origin in grid cells, quarter turns clockwise, layout uuid.
/// Nothing else is stored — which module plugs into which port follows from the geometry (`Board.paths()`).
public struct Pose: Equatable, Codable {
    public var t: Int, x: Int, y: Int, r: Int, u: String
    public init(t: Int, x: Int, y: Int, r: Int, u: String) { self.t = t; self.x = x; self.y = y; self.r = r; self.u = u }
    public var isCore: Bool { t & 0x1f == 25 || t & 0x1f == 0 }
    public var isSquare: Bool { t & 0x1f == 24 } // Orbiter 2x2
    /// Unrotated size in cells.
    var size0: (w: Int, h: Int) { isCore ? (2, 1) : isSquare ? (2, 2) : (1, 2) }
    public var w: Int { r % 2 == 0 ? size0.w : size0.h }
    public var h: Int { r % 2 == 0 ? size0.h : size0.w }
    public var cells: [Board.Cell] { (x..<x + w).flatMap { cx in (y..<y + h).map { Board.Cell(cx, $0) } } }
}

public struct Board: Equatable {
    public enum Side: Int, Codable { case top = 0, right, bottom, left
        public var opposite: Side { Side(rawValue: (rawValue + 2) % 4)! }
    }
    public struct Cell: Hashable { public var x: Int, y: Int; public init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
        func step(_ s: Side) -> Cell { switch s { case .top: Cell(x, y - 1); case .right: Cell(x + 1, y); case .bottom: Cell(x, y + 1); case .left: Cell(x - 1, y) } }
    }
    public struct Port { public let cell: Cell, side: Side } // the cell just outside the module where a child's pins unit sits, facing `side`

    /// modules[0] is the Core.
    public var modules: [Pose]
    public init(modules: [Pose]) { self.modules = modules }
    public static func empty(coreU: String = "v:core", coreT: Int = 25) -> Board { Board(modules: [Pose(t: coreT, x: 0, y: 0, r: 0, u: coreU)]) }

    // MARK: geometry (ports verified on hardware; numbered clockwise from the connector)
    static let corePorts: [(Side, Int)] = [(.top, 0), (.top, 1), (.right, 0), (.bottom, 1), (.bottom, 0)]
    static let modulePorts: [(Side, Int)] = [(.left, 1), (.left, 0), (.top, 0), (.right, 0), (.right, 1)]
    static let squarePorts: [(Side, Int)] = [(.left, 1), (.left, 0), (.top, 0), (.top, 1), (.right, 0), (.right, 1), (.bottom, 1)]
    public static func portCount(_ t: Int) -> Int { t & 0x1f == 24 ? 7 : 5 }

    /// Rotate a (side, offset) of an unrotated w0 x h0 module by `rot` quarter turns clockwise.
    public static func rotated(_ p: (Side, Int), w0: Int, h0: Int, rot: Int) -> (Side, Int) {
        var (side, k) = p; var (w, h) = (w0, h0)
        for _ in 0..<(rot % 4) {
            switch side { case .bottom: side = .left; case .left: side = .top; k = h - 1 - k; case .top: side = .right; case .right: side = .bottom; k = h - 1 - k }
            (w, h) = (h, w)
        }
        return (side, k)
    }
    /// Which cell of the box edge `k` units along `side` is, in screen orientation.
    static func edgeCell(_ p: Pose, _ side: Side, _ k: Int) -> Cell {
        switch side { case .top: Cell(p.x + k, p.y); case .bottom: Cell(p.x + k, p.y + p.h - 1); case .left: Cell(p.x, p.y + k); case .right: Cell(p.x + p.w - 1, p.y + k) }
    }
    /// Female ports in screen orientation, with the outside cell a child's pins unit occupies.
    public static func ports(_ p: Pose) -> [Port] {
        let own = p.isCore ? corePorts : p.isSquare ? squarePorts : modulePorts
        return own.map { let (s, k) = rotated($0, w0: p.size0.w, h0: p.size0.h, rot: p.r); return Port(cell: edgeCell(p, s, k).step(s), side: s) }
    }
    /// Female ports as (side, offset) in screen orientation, for drawing.
    public static func portSides(_ p: Pose) -> [(Side, Int)] {
        (p.isCore ? corePorts : p.isSquare ? squarePorts : modulePorts).map { rotated($0, w0: p.size0.w, h0: p.size0.h, rot: p.r) }
    }
    /// (side, offset) of the pins unit in screen orientation; nil for the Core (USB instead).
    public static func pinSide(_ p: Pose) -> (Side, Int)? { p.isCore ? nil : rotated((.bottom, 0), w0: p.size0.w, h0: p.size0.h, rot: p.r) }
    /// The cell of the pins unit and the side the pins stick out of.
    public static func pins(_ p: Pose) -> (cell: Cell, side: Side)? { pinSide(p).map { (edgeCell(p, $0.0, $0.1), $0.0) } }
    /// Rotation of a child plugged into a port that faces `side` (its pins are at the bottom when r == 0, i.e. the port faces up).
    public static func rotation(facing side: Side) -> Int { [Side.top: 0, .right: 1, .bottom: 2, .left: 3][side]! }
    /// The pose a module of type `t` takes when plugged into `port`.
    public static func pose(t: Int, into port: Port, u: String) -> Pose {
        var p = Pose(t: t, x: 0, y: 0, r: rotation(facing: port.side), u: u)
        let pin = pins(p)!.cell // where the pins unit is for a box at (0,0)
        p.x = port.cell.x - pin.x; p.y = port.cell.y - pin.y
        return p
    }

    // MARK: contact rules
    public enum Edge { case plain, pins, female, usb }
    /// What a module presents on unit `k` of `side` (screen orientation).
    public static func edge(_ p: Pose, _ side: Side, _ k: Int) -> Edge {
        if let pin = pinSide(p), pin.0 == side, pin.1 == k { return .pins }
        if portSides(p).contains(where: { $0.0 == side && $0.1 == k }) { return .female }
        if p.isCore, rotated((.left, 0), w0: 2, h0: 1, rot: p.r).0 == side { return .usb }
        return .plain
    }
    /// A module may sit here: no overlap, and no pins-to-pins or USB-side contact (female-to-female and pins-to-plain just butt).
    public func placeable(_ g: Pose, moving: Int? = nil) -> Bool {
        guard !overlaps(g, except: moving) else { return false }
        for c in g.cells { for s in [Side.top, .right, .bottom, .left] {
            let d = c.step(s)
            for (oi, o) in modules.enumerated() where oi != moving && o.cells.contains(d) {
                let mine = Self.edge(g, s, s == .top || s == .bottom ? c.x - g.x : c.y - g.y)
                let theirs = Self.edge(o, s.opposite, s == .top || s == .bottom ? d.x - o.x : d.y - o.y)
                if mine == .usb || theirs == .usb || (mine == .pins && theirs == .pins) { return false }
            }
        } }
        return true
    }

    // MARK: derived structure
    public func overlaps(_ p: Pose, except: Int? = nil) -> Bool {
        let c = Set(p.cells)
        return modules.indices.contains { $0 != except && modules[$0].cells.contains(where: c.contains) }
    }
    /// child index → (parent index, port index): the child's pins unit sits in the parent's port cell, pins facing the port.
    public func connections() -> [Int: (parent: Int, port: Int)] {
        var out: [Int: (Int, Int)] = [:]
        for (ci, c) in modules.enumerated() {
            guard let pin = Self.pins(c) else { continue }
            outer: for (pi, p) in modules.enumerated() where pi != ci {
                for (k, port) in Self.ports(p).enumerated() where port.cell == pin.cell && port.side == pin.side.opposite { out[ci] = (pi, k); break outer }
            }
        }
        return out
    }
    /// Port path from the Core ("" = Core, "2", "3/0") per connected module; loose modules have none.
    public func paths() -> [Int: String] {
        guard !modules.isEmpty else { return [:] }
        let conn = connections()
        var out = [0: ""], queue = [0]
        while let pi = queue.popLast() {
            for (ci, c) in conn where c.parent == pi && out[ci] == nil { out[ci] = out[pi]!.isEmpty ? "\(c.port)" : out[pi]! + "/\(c.port)"; queue.append(ci) }
        }
        return out
    }
    /// The Store's position map: path → (u, t).
    public func derived() -> [String: (u: String, t: Int)] {
        var out: [String: (u: String, t: Int)] = [:]
        for (i, path) in paths() { out[path] = (modules[i].u, modules[i].t) }
        return out
    }
    public func index(at path: String) -> Int? { paths().first { $0.value == path }?.key }
    /// Where a module of type `t` plugged in at `path` would sit (its parent must be on the board).
    public func pose(at path: String, t: Int, u: String) -> Pose? {
        let parentPath = path.contains("/") ? String(path[..<path.lastIndex(of: "/")!]) : ""
        guard let k = Int(path.split(separator: "/").last ?? ""), let pi = index(at: parentPath) else { return nil }
        let ports = Self.ports(modules[pi])
        return k < ports.count ? Self.pose(t: t, into: ports[k], u: u) : nil
    }
    /// Free ports a module in `ghost`'s orientation could plug into without overlapping (parent index, port index); the guide lights these.
    public func candidates(for ghost: Pose, moving: Int? = nil) -> [(parent: Int, port: Int)] {
        guard Self.pins(ghost) != nil else { return [] }
        let taken = Set(connections().filter { $0.key != moving }.values.map { "\($0.parent)/\($0.port)" })
        var out: [(Int, Int)] = []
        for (pi, p) in modules.enumerated() where pi != moving {
            for (k, port) in Self.ports(p).enumerated() where !taken.contains("\(pi)/\(k)") {
                let at = Self.pose(t: ghost.t, into: port, u: ghost.u)
                if at.r == ghost.r && placeable(at, moving: moving) { out.append((pi, k)) }
            }
        }
        return out
    }
    /// The other way round: poses where one of `ghost`'s female ports receives another module's pins (ghost port index, parent-of-nothing: the other module becomes ghost's child).
    public func reverseCandidates(for ghost: Pose, moving: Int? = nil) -> [(pose: Pose, port: Int)] {
        let plugged = Set(connections().filter { $0.key != moving && $0.value.parent != moving }.keys) // modules plugged in elsewhere stay there; the mover's own children come loose
        var out: [(Pose, Int)] = []
        for (oi, o) in modules.enumerated() where oi != moving && !plugged.contains(oi) {
            guard let pin = Self.pins(o) else { continue }
            for (k, port) in Self.ports(ghost).enumerated() where port.side == pin.side.opposite {
                var at = ghost; at.x += pin.cell.x - port.cell.x; at.y += pin.cell.y - port.cell.y
                if placeable(at, moving: moving) { out.append((at, k)) }
            }
        }
        return out
    }
    /// The connection `ghost` makes at exactly this cell (none → the pose unchanged): its pins into a free port, or one of its ports onto loose pins. `ownPort` = the ghost port used.
    /// No pull-in radius: with ports on every side a 1-cell radius dragged modules back into some joint, so they never came off.
    public func snap(_ ghost: Pose, moving: Int? = nil) -> (pose: Pose, port: (parent: Int, port: Int)?, ownPort: Int?) {
        var best: (Pose, (Int, Int)?, Int?, Int)? = nil
        func consider(_ at: Pose, _ port: (Int, Int)?, _ own: Int?) {
            let d = max(abs(at.x - ghost.x), abs(at.y - ghost.y))
            if d == 0, best == nil || d < best!.3 { best = (at, port, own, d) }
        }
        for c in candidates(for: ghost, moving: moving) { consider(Self.pose(t: ghost.t, into: Self.ports(modules[c.parent])[c.port], u: ghost.u), (c.parent, c.port), nil) }
        for c in reverseCandidates(for: ghost, moving: moving) { consider(c.pose, nil, c.port) }
        if let (p, c, own, _) = best { return (p, c.map { ($0.0, $0.1) }, own) }
        return (ghost, nil, nil)
    }

    // MARK: storage
    /// The Core never turns by itself (user decision 2026-11-14: turn the whole board instead), so its r is stored and read as 0.
    public var json: [String: Any] { ["v": 2, "modules": modules.map { ["t": $0.t, "x": $0.x, "y": $0.y, "r": $0.isCore ? 0 : $0.r, "u": $0.u] }] }
    /// Reads the v2 form, or the older path-keyed form (path → {u,t,r?}, "free:<id>" → {u,t,x,y,r} with x,y the pins cell).
    public init?(layout: Any?) {
        guard let d = layout as? [String: Any] else { return nil }
        if let ms = d["modules"] as? [[String: Any]] {
            modules = ms.compactMap { m in (m["u"] as? String).map { Pose(t: Int(num(m["t"]) ?? 0), x: Int(num(m["x"]) ?? 0), y: Int(num(m["y"]) ?? 0), r: Int(num(m["r"]) ?? 0), u: $0) } }
            guard !modules.isEmpty else { return nil }
            for i in modules.indices where modules[i].isCore { modules[i].r = 0 } // shortcut: modules a turned Core carried are left where they were drawn; re-place them if a profile had any
            return
        }
        guard let old = d as? [String: [String: Any]], let core = old[""], let cu = core["u"] as? String else { return nil }
        var b = Board(modules: [Pose(t: Int(num(core["t"]) ?? 25), x: 0, y: 0, r: Int(num(core["r"]) ?? 0), u: cu)])
        for path in old.keys.filter({ !$0.isEmpty && !$0.hasPrefix("free:") }).sorted(by: { $0.count < $1.count || ($0.count == $1.count && $0 < $1) }) {
            guard let u = old[path]?["u"] as? String, let p = b.pose(at: path, t: Int(num(old[path]?["t"]) ?? 0), u: u) else { continue }
            b.modules.append(p)
        }
        for (k, m) in old where k.hasPrefix("free:") {
            guard let u = m["u"] as? String else { continue }
            var p = Pose(t: Int(num(m["t"]) ?? 0), x: 0, y: 0, r: Int(num(m["r"]) ?? 0), u: u)
            let pin = Self.pins(p)?.cell ?? Cell(0, 0)
            p.x = Int(num(m["x"]) ?? 0) - pin.x; p.y = Int(num(m["y"]) ?? 0) - pin.y
            b.modules.append(p)
        }
        self = b
    }
}
