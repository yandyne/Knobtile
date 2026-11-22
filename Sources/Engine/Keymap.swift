import Foundation

/// (51) Named shortcuts per plugin: each plugin's keys.json holds the defaults, the store's root["keymaps"] holds the user's
/// changes as diffs ([app: [id: {key, modifiers} | {label, key, modifiers, opposite?} for their own items]]).
/// A wire names an item ({"keys": id}), so changing an item's key changes every wire that uses it.
public enum Keymap {
    public struct Item {
        public let id: String, label: String, key: String, mods: [String], opposite: String?, app: String
        public let changed: Bool, own: Bool
        public var chord: String { mods.compactMap { modSymbols[$0] }.joined() + key.uppercased() }
    }
    public static let modSymbols = ["control": "⌃", "alt": "⌥", "shift": "⇧", "command": "⌘"]
    static var defaults: [String: [[String: Any]]] { Catalog.shared.keys }
    /// Set by Store whenever root changes, so the decoder reads the user's keys at fire time.
    nonisolated(unsafe) public static var user: [String: Any] = [:]

    /// Defaults of the app (in file order) with the user's changes, then the user's own items.
    public static func items(app: String) -> [Item] {
        let mine = user[app] as? [String: Any] ?? [:]
        var out = (defaults[app] ?? []).compactMap { d -> Item? in
            guard let id = d["id"] as? String else { return nil }
            let o = mine[id] as? [String: Any]
            return item(id, app: app, o ?? d, label: d["label"] as? String ?? id, opposite: d["opposite"] as? String, changed: o != nil, own: false)
        }
        let known = Set(out.map(\.id))
        for (id, v) in mine where !known.contains(id) {
            guard let o = v as? [String: Any] else { continue }
            out.append(item(id, app: app, o, label: o["label"] as? String ?? id, opposite: o["opposite"] as? String, changed: false, own: true))
        }
        return out
    }
    private static func item(_ id: String, app: String, _ d: [String: Any], label: String, opposite: String?, changed: Bool, own: Bool) -> Item {
        Item(id: id, label: label, key: d["key"] as? String ?? "", mods: d["modifiers"] as? [String] ?? [], opposite: opposite, app: app, changed: changed, own: own)
    }
    /// Apps with items: the shipped ones, then any the user added items for.
    public static var apps: [String] { Array(defaults.keys).sorted() + user.keys.filter { defaults[$0] == nil }.sorted() }
    /// Ids are unique across apps, so a wire names one without its app.
    public static func find(_ id: String) -> Item? {
        for app in apps { if let i = items(app: app).first(where: { $0.id == id }) { return i } }
        return nil
    }
}
