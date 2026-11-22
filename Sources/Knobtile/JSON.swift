import Foundation

/// Loose JSON value. The service schema is dynamic, so we keep it dynamic.
enum JSON: Equatable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSON]), object([String: JSON])

    init(any: Any) {
        switch any {
        // NSNumber 0/1 also bridge to Bool, so check the CF type to tell them apart.
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSON.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(JSON.init(any:)))
        default: self = .null
        }
    }

    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) : n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    subscript(key: String) -> JSON { if case .object(let o) = self { return o[key] ?? .null }; return .null }
    subscript(index: Int) -> JSON { if case .array(let a) = self, a.indices.contains(index) { return a[index] }; return .null }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var double: Double? { if case .number(let n) = self { return n }; return nil }
    var int: Int? { if case .number(let n) = self { return Int(n) }; return nil }
    var array: [JSON] { if case .array(let a) = self { return a }; return [] }
    var object: [String: JSON] { if case .object(let o) = self { return o }; return [:] }
    var isNull: Bool { self == .null }

    static func parse(_ line: String) -> JSON? {
        guard let d = line.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: d) else { return nil }
        return JSON(any: any)
    }
    func serialized() -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: any) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}
