import Foundation
import Observation

/// The user's changes to the single-key shortcuts, on top of `KeyMap.defaults`. Saved in UserDefaults.
/// Observable, so menus and the shortcut sheet update as soon as a key changes.
@Observable
final class ShortcutStore {
    static let shared = ShortcutStore()
    private static let defaultsKey = "shortcuts.overrides"

    struct Assignment: Codable, Equatable {
        var key: KeyBinding.Key?   // nil = unassigned
        var option: Bool
    }

    private(set) var overrides: [String: Assignment] = [:]
    private(set) var bindings: [KeyBinding] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: Assignment].self, from: data) {
            overrides = saved
        }
        rebuild()
    }

    private func rebuild() {
        bindings = KeyMap.defaults.compactMap { d in
            guard let o = overrides[d.id] else { return d }
            guard let key = o.key else { return nil }
            var b = d
            b.key = key
            b.option = o.option
            return b
        }
    }

    private func save() {
        rebuild()
        if let data = try? JSONEncoder().encode(overrides) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    func isCustomized(_ id: String) -> Bool { overrides[id] != nil }

    /// Assigns a key. Any other action on the same key loses it; their titles are returned (for a notice).
    @discardableResult
    func assign(_ id: String, key: KeyBinding.Key, option: Bool) -> [String] {
        let taken = bindings.filter { $0.id != id && $0.key == key && $0.option == option }
        for b in taken { overrides[b.id] = Assignment(key: nil, option: false) }
        if let d = KeyMap.defaults.first(where: { $0.id == id }), d.key == key, d.option == option {
            overrides[id] = nil
        } else {
            overrides[id] = Assignment(key: key, option: option)
        }
        save()
        return taken.map(\.title)
    }

    func unassign(_ id: String) {
        overrides[id] = Assignment(key: nil, option: false)
        save()
    }

    /// Back to the built-in key (whoever holds it now gives it up).
    func reset(_ id: String) {
        guard let d = KeyMap.defaults.first(where: { $0.id == id }) else { return }
        assign(id, key: d.key, option: d.option)
        overrides[id] = nil
        save()
    }

    #if DEBUG
    /// Tests: put back exactly what the user had.
    func debugRestore(_ saved: [String: Assignment]) {
        overrides = saved
        save()
    }
    #endif

    func resetAll() {
        overrides = [:]
        save()
    }

    /// Pick / Unflag / Reject on A / S / D (home row, left hand); Expand stack moves from S to W.
    func applyLeftHandPreset() {
        resetAll()
        assign("stack.toggle", key: .character("w"), option: false)
        assign("mark.pick", key: .character("a"), option: false)
        assign("mark.unflag", key: .character("s"), option: false)
        assign("mark.reject", key: .character("d"), option: false)
    }
}
