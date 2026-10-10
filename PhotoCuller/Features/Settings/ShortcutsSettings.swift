import SwiftUI
import AppKit

/// Settings ▸ Shortcuts: every single-key action can get another key.
struct ShortcutsSettings: View {
    @State private var store = ShortcutStore.shared
    @State private var capture = KeyCapture()
    @State private var notice: (id: String, text: String)?

    private var groups: [String] {
        var seen: [String] = []
        for b in KeyMap.defaults where !seen.contains(b.group) { seen.append(b.group) }
        return seen
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Text("Click a key and press the new one (Esc cancels). ⇧ always means “and next” for marks and “extend selection” for arrows; ⌥ combinations are allowed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Menu("Presets") {
                    Button("Default — P pick · X reject · U unflag") { store.resetAll(); notice = nil }
                    Button("Left hand — A pick · S unflag · D reject (stacks: W)") { store.applyLeftHandPreset(); notice = nil }
                }
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)
            Form {
                ForEach(groups, id: \.self) { g in
                    Section(g) {
                        ForEach(KeyMap.defaults.filter { $0.group == g }, id: \.id) { row($0) }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onDisappear { capture.stop() }
    }

    private func row(_ d: KeyBinding) -> some View {
        let _ = store.bindings   // re-render on change
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.title)
                if let n = notice, n.id == d.id {
                    Text(n.text).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if store.isCustomized(d.id) {
                Button { store.reset(d.id); notice = nil } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Back to \(KeyMap.label(d.key, option: d.option))")
            }
            Button {
                capture.start(for: d.id) { key, option in
                    let taken = store.assign(d.id, key: key, option: option)
                    notice = message(for: d, key: key, option: option, taken: taken).map { (d.id, $0) }
                }
            } label: {
                Text(capture.recordingID == d.id ? "Press a key…" : KeyMap.label(d.id))
                    .font(.body.monospaced())
                    .frame(minWidth: 86)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.bordered)
            .tint(capture.recordingID == d.id ? Theme.accentStart : nil)
            .contextMenu {
                Button("Remove Shortcut") { store.unassign(d.id); notice = nil }
                Button("Reset to \(KeyMap.label(d.key, option: d.option))") { store.reset(d.id); notice = nil }
            }
        }
    }

    private func message(for d: KeyBinding, key: KeyBinding.Key, option: Bool, taken: [String]) -> String? {
        var parts: [String] = []
        if !taken.isEmpty { parts.append("Taken from \(taken.joined(separator: ", ")), which now has no key.") }
        if case .character(let c) = key, d.shiftAdvances || d.shiftExtends, !option,
           let fixed = KeyMap.fixedMenuKeys.first(where: { String($0.key) == c && $0.modifiers == .shift }) {
            parts.append("⇧\(c.uppercased()) now means “\(d.title) and next”; the menu’s \(fixed.title) loses it.")
        }
        if case .character(let c) = key, option,
           let fixed = KeyMap.fixedMenuKeys.first(where: { String($0.key) == c && $0.modifiers == .option }) {
            parts.append("The menu’s \(fixed.title) loses ⌥\(c.uppercased()).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Records the next key press for a shortcut (one at a time).
@Observable
final class KeyCapture {
    private(set) var recordingID: String?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var done: ((KeyBinding.Key, Bool) -> Void)?

    func start(for id: String, done: @escaping (KeyBinding.Key, Bool) -> Void) {
        stop()
        recordingID = id
        self.done = done
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingID = nil
        done = nil
    }

    /// Returns nil to swallow the key while recording.
    private func handle(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection([.command, .control, .shift, .option])
        if event.keyCode == KeyCode.escape && mods.isEmpty { stop(); return nil }
        // ⌘ / ⌃ belong to the menus, ⇧ is added automatically ("and next" / "extend").
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.shift) { NSSound.beep(); return nil }
        let key: KeyBinding.Key
        if KeyMap.isSpecial(event.keyCode) {
            key = .code(event.keyCode)
        } else if let c = event.characters(byApplyingModifiers: [])?.lowercased(), c.count == 1, c != "?", c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            key = .character(c)
        } else {
            NSSound.beep()
            return nil
        }
        let finish = done
        stop()
        finish?(key, mods.contains(.option))
        return nil
    }
}
