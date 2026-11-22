import Foundation

/// Minimal MessagePack for the Core V2 wire format. Values are plain Foundation types:
/// NSNull, Bool, Int, Double, String, Data, [Any], [String: Any].
public enum MsgPack {
    public enum Error: Swift.Error { case truncated, unsupported(UInt8), badValue }

    public static func encode(_ v: Any) -> Data {
        var d = Data()
        write(v, into: &d)
        return d
    }

    private static func write(_ v: Any, into d: inout Data) {
        switch v {
        case is NSNull: d.append(0xc0)
        case let b as Bool: d.append(b ? 0xc3 : 0xc2)
        case let n as Int: writeInt(n, into: &d)
        case let x as Double: d.append(0xcb); d.append(be(x.bitPattern))
        case let s as String:
            let u = Data(s.utf8)
            if u.count < 32 { d.append(0xa0 | UInt8(u.count)) }
            else if u.count < 256 { d.append(0xd9); d.append(UInt8(u.count)) }
            else { d.append(0xda); d.append(be(UInt16(u.count))) }
            d.append(u)
        case let b as Data:
            if b.count < 256 { d.append(0xc4); d.append(UInt8(b.count)) }
            else { d.append(0xc5); d.append(be(UInt16(b.count))) }
            d.append(b)
        case let a as [Any]:
            if a.count < 16 { d.append(0x90 | UInt8(a.count)) } else { d.append(0xdc); d.append(be(UInt16(a.count))) }
            for e in a { write(e, into: &d) }
        case let m as [String: Any]:
            if m.count < 16 { d.append(0x80 | UInt8(m.count)) } else { d.append(0xde); d.append(be(UInt16(m.count))) }
            for (k, e) in m { write(k, into: &d); write(e, into: &d) }
        default: d.append(0xc0) // shortcut: unsupported types encode as nil, add cases when needed
        }
    }

    private static func writeInt(_ n: Int, into d: inout Data) {
        switch n {
        case 0...127: d.append(UInt8(n))
        case -32..<0: d.append(UInt8(bitPattern: Int8(n)))
        case 128...0xff: d.append(0xcc); d.append(UInt8(n))
        case 0x100...0xffff: d.append(0xcd); d.append(be(UInt16(n)))
        case 0x10000...0xffff_ffff: d.append(0xce); d.append(be(UInt32(n)))
        case -128..<(-32): d.append(0xd0); d.append(UInt8(bitPattern: Int8(n)))
        case -32768..<(-128): d.append(0xd1); d.append(be(UInt16(bitPattern: Int16(n))))
        case -2_147_483_648..<(-32768): d.append(0xd2); d.append(be(UInt32(bitPattern: Int32(n))))
        default: d.append(0xd3); d.append(be(UInt64(bitPattern: Int64(n))))
        }
    }

    private static func be<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    public static func decode(_ data: Data) throws -> Any {
        var r = Reader(d: data)
        return try r.read()
    }

    private struct Reader {
        let d: Data
        var i = 0
        init(d: Data) { self.d = Data(d) } // re-base so indices start at 0

        mutating func bytes(_ n: Int) throws -> Data {
            guard i + n <= d.count else { throw Error.truncated }
            defer { i += n }
            return d[i..<i + n]
        }
        mutating func u<T: FixedWidthInteger>(_: T.Type) throws -> T {
            try bytes(MemoryLayout<T>.size).reduce(0) { ($0 << 8) | T($1) }
        }
        mutating func read() throws -> Any {
            let b = try u(UInt8.self)
            switch b {
            case 0x00...0x7f: return Int(b)
            case 0x80...0x8f: return try map(Int(b & 0x0f))
            case 0x90...0x9f: return try array(Int(b & 0x0f))
            case 0xa0...0xbf: return try str(Int(b & 0x1f))
            case 0xc0: return NSNull()
            case 0xc2: return false
            case 0xc3: return true
            case 0xc4: return try bytes(Int(try u(UInt8.self)))
            case 0xc5: return try bytes(Int(try u(UInt16.self)))
            case 0xc6: return try bytes(Int(try u(UInt32.self)))
            case 0xca: return Double(Float(bitPattern: try u(UInt32.self)))
            case 0xcb: return Double(bitPattern: try u(UInt64.self))
            case 0xcc: return Int(try u(UInt8.self))
            case 0xcd: return Int(try u(UInt16.self))
            case 0xce: return Int(try u(UInt32.self))
            case 0xcf: return Int(try u(UInt64.self))
            case 0xd0: return Int(Int8(bitPattern: try u(UInt8.self)))
            case 0xd1: return Int(Int16(bitPattern: try u(UInt16.self)))
            case 0xd2: return Int(Int32(bitPattern: try u(UInt32.self)))
            case 0xd3: return Int(Int64(bitPattern: try u(UInt64.self)))
            case 0xd9: return try str(Int(try u(UInt8.self)))
            case 0xda: return try str(Int(try u(UInt16.self)))
            case 0xdb: return try str(Int(try u(UInt32.self)))
            case 0xdc: return try array(Int(try u(UInt16.self)))
            case 0xdd: return try array(Int(try u(UInt32.self)))
            case 0xde: return try map(Int(try u(UInt16.self)))
            case 0xdf: return try map(Int(try u(UInt32.self)))
            case 0xe0...0xff: return Int(Int8(bitPattern: b))
            default: throw Error.unsupported(b) // ext types are not used by the Core
            }
        }
        mutating func str(_ n: Int) throws -> String {
            guard let s = String(data: try bytes(n), encoding: .utf8) else { throw Error.badValue }
            return s
        }
        mutating func array(_ n: Int) throws -> [Any] { try (0..<n).map { _ in try read() } }
        mutating func map(_ n: Int) throws -> [String: Any] {
            var m: [String: Any] = [:]
            for _ in 0..<n {
                guard let k = try read() as? String else { throw Error.badValue }
                m[k] = try read()
            }
            return m
        }
    }
}
