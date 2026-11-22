import Foundation

/// A UI string in the language of the app: the Korean text is the key, en.lproj/Localizable.strings holds the English.
/// Every interpolation becomes %@ in the key ("\(n)개 더" is looked up as "%@개 더"), so a translation can reorder with %1$@ %2$@.
public struct Loc: ExpressibleByStringInterpolation {
    var key: String, args: [String] = []
    public init(stringLiteral v: String) { key = v }
    public init(stringInterpolation s: StringInterpolation) { key = s.key; args = s.args }
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = "", args: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ s: String) { key += s.replacingOccurrences(of: "%", with: "%%") }
        public mutating func appendInterpolation<T>(_ v: T) { key += "%@"; args.append("\(v)") }
    }
}
/// The language in use: the "language" preference ("ko" | "en"), or with none the first of the user's macOS languages the app has.
/// Read on every call so that a change in settings shows as soon as the views draw again.
public enum Language {
    private static var cached: (pref: String, code: String, bundle: Bundle)?
    private static var current: (pref: String, code: String, bundle: Bundle) {
        let pref = UserDefaults.standard.string(forKey: "language") ?? ""
        if let c = cached, c.pref == pref { return c }
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? []
        let code = pref.isEmpty ? Bundle.preferredLocalizations(from: ["ko", "en"], forPreferences: system).first ?? "en" : pref
        let c = (pref, code, Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main)
        cached = c; return c
    }
    public static var code: String { current.code }
    static var bundle: Bundle { current.bundle }
}
public func L(_ l: Loc) -> String {
    let s = Language.bundle.localizedString(forKey: l.key, value: l.key, table: nil)
    return l.args.isEmpty ? s : String(format: s, arguments: l.args)
}
