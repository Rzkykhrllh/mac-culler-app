import AppKit
import SwiftUI
import CullerKit

/// Single-key actions (spec §9), defined in one table; the user can change the keys (Settings ▸ Shortcuts).
enum KeyAction: Equatable {
    case mark(MarkCommand)
    case next, previous, up, down
    case nextUnflagged, previousUnflagged
    case toggleStack
    case showGrid, showLoupe, showCompare
    case switchSlot
    case enter
    case toggleZoom
    case toggleInfo
    case toggleHistogram
    case editNote
    case rename
    case escape
    case toggleSyncZoom
    case togglePinBest
    case toggleStripShowsAll
    case togglePeaking
    case toggleClipping
    case zoomToSubject
    case sharpest
    case trash
}

struct KeyBinding {
    enum Key: Equatable, Codable {
        case character(String)   // layout-independent base character (no modifiers applied)
        case code(UInt16)        // virtual key code for non-character keys
    }

    /// Stable id: custom shortcuts are stored under it.
    var id: String
    var key: Key
    /// Shift variant applies the action and then advances once (marking keys only).
    var shiftAdvances = false
    /// Shift variant extends the selection (arrow keys in the grid).
    var shiftExtends = false
    var option = false
    var action: KeyAction
    var title: String
    /// Settings ▸ Shortcuts section.
    var group: String
}

enum KeyCode {
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    static let tab: UInt16 = 48
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    static let f2: UInt16 = 120
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
}

enum KeyMap {
    /// The built-in keys. `bindings` applies the user's changes (Settings ▸ Shortcuts) on top.
    static let defaults: [KeyBinding] = {
        let mark = "Marking", rate = "Rating & labels", nav = "Moving around", view = "View", focus = "Focus", stack = "Stacks & compare", file = "Files"
        var b: [KeyBinding] = [
            .init(id: "mark.pick", key: .character("p"), shiftAdvances: true, action: .mark(.flag(.pick)), title: "Pick", group: mark),
            .init(id: "mark.reject", key: .character("x"), shiftAdvances: true, action: .mark(.flag(.reject)), title: "Reject", group: mark),
            .init(id: "mark.unflag", key: .character("u"), shiftAdvances: true, action: .mark(.flag(.none)), title: "Unflag", group: mark),
            .init(id: "mark.note", key: .character("m"), action: .editNote, title: "Edit note", group: mark),
        ]
        for r in 0...5 {
            b.append(.init(id: "rating.\(r)", key: .character("\(r)"), shiftAdvances: true, action: .mark(.rating(r)),
                           title: r == 0 ? "Clear rating" : "\(r) star\(r == 1 ? "" : "s")", group: rate))
        }
        let labels: [(String, ColorLabel)] = [("6", .red), ("7", .yellow), ("8", .green), ("9", .blue)]
        for (k, l) in labels {
            b.append(.init(id: "label.\(l.rawValue)", key: .character(k), shiftAdvances: true, action: .mark(.toggleLabel(l)),
                           title: "\(l.displayName) label", group: rate))
        }
        b += [
            .init(id: "label.purple", key: .character("9"), option: true, action: .mark(.toggleLabel(.purple)), title: "Purple label", group: rate),
            .init(id: "label.clear", key: .character("0"), option: true, action: .mark(.setLabel(.none)), title: "Clear label", group: rate),
            .init(id: "nav.next", key: .code(KeyCode.rightArrow), shiftExtends: true, action: .next, title: "Next photo (⇧ extends selection)", group: nav),
            .init(id: "nav.previous", key: .code(KeyCode.leftArrow), shiftExtends: true, action: .previous, title: "Previous photo (⇧ extends selection)", group: nav),
            .init(id: "nav.up", key: .code(KeyCode.upArrow), shiftExtends: true, action: .up, title: "Up (grid)", group: nav),
            .init(id: "nav.down", key: .code(KeyCode.downArrow), shiftExtends: true, action: .down, title: "Down (grid)", group: nav),
            .init(id: "nav.nextUnflagged", key: .code(KeyCode.rightArrow), option: true, action: .nextUnflagged, title: "Next unflagged", group: nav),
            .init(id: "nav.previousUnflagged", key: .code(KeyCode.leftArrow), option: true, action: .previousUnflagged, title: "Previous unflagged", group: nav),
            .init(id: "nav.enter", key: .code(KeyCode.returnKey), action: .enter, title: "Open in loupe / promote candidate", group: nav),
            .init(id: "nav.enterKeypad", key: .code(KeyCode.keypadEnter), action: .enter, title: "Open in loupe (keypad Enter)", group: nav),
            .init(id: "nav.escape", key: .code(KeyCode.escape), action: .escape, title: "Back", group: nav),
            .init(id: "view.grid", key: .character("g"), action: .showGrid, title: "Grid", group: view),
            .init(id: "view.loupe", key: .character("e"), action: .showLoupe, title: "Loupe", group: view),
            .init(id: "view.compare", key: .character("c"), action: .showCompare, title: "Compare", group: view),
            .init(id: "view.zoom", key: .character("z"), action: .toggleZoom, title: "Toggle 100% zoom", group: view),
            .init(id: "view.zoomSpace", key: .code(KeyCode.space), action: .toggleZoom, title: "Toggle 100% zoom (Space)", group: view),
            .init(id: "view.info", key: .character("i"), action: .toggleInfo, title: "Info panel", group: view),
            .init(id: "view.histogram", key: .character("h"), action: .toggleHistogram, title: "Histogram", group: view),
            .init(id: "focus.peaking", key: .character("f"), action: .togglePeaking, title: "Focus peaking", group: focus),
            .init(id: "focus.clipping", key: .character("j"), action: .toggleClipping, title: "Highlight / shadow clipping", group: focus),
            .init(id: "focus.subject", key: .character("y"), action: .zoomToSubject, title: "Zoom to eyes / face / animal (again: next)", group: focus),
            .init(id: "focus.sharpest", key: .character("b"), action: .sharpest, title: "Go to sharpest in stack", group: focus),
            .init(id: "stack.toggle", key: .character("s"), action: .toggleStack, title: "Expand / collapse selected stacks", group: stack),
            .init(id: "compare.switchSlot", key: .code(KeyCode.tab), action: .switchSlot, title: "Switch compare slot", group: stack),
            .init(id: "compare.syncZoom", key: .character("z"), option: true, action: .toggleSyncZoom, title: "Compare: sync zoom & pan", group: stack),
            .init(id: "compare.pinBest", key: .character("p"), option: true, action: .togglePinBest, title: "Compare: pin current best", group: stack),
            .init(id: "compare.stripAll", key: .character("a"), option: true, action: .toggleStripShowsAll, title: "Compare: filmstrip shows all / candidates", group: stack),
            .init(id: "file.rename", key: .code(KeyCode.f2), action: .rename, title: "Rename…", group: file),
            .init(id: "file.trash", key: .code(KeyCode.delete), action: .trash, title: "Move to Trash (undo with ⌘Z)", group: file),
            .init(id: "file.trashForward", key: .code(KeyCode.forwardDelete), action: .trash, title: "Move to Trash (⌦)", group: file),
        ]
        return b
    }()

    /// The active keys (defaults + the user's changes; unassigned actions left out).
    static var bindings: [KeyBinding] { ShortcutStore.shared.bindings }

    static func binding(_ id: String) -> KeyBinding? { ShortcutStore.shared.bindings.first { $0.id == id } }

    // MARK: Showing keys

    private static let codeNames: [UInt16: String] = [
        KeyCode.leftArrow: "←", KeyCode.rightArrow: "→", KeyCode.upArrow: "↑", KeyCode.downArrow: "↓",
        KeyCode.tab: "Tab", KeyCode.returnKey: "Return", KeyCode.keypadEnter: "Enter", KeyCode.space: "Space",
        KeyCode.escape: "Esc", KeyCode.delete: "⌫", KeyCode.forwardDelete: "⌦",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    private static let functionKeys: [UInt16: Int] = [122: NSF1FunctionKey, 120: NSF2FunctionKey, 99: NSF3FunctionKey, 118: NSF4FunctionKey,
        96: NSF5FunctionKey, 97: NSF6FunctionKey, 98: NSF7FunctionKey, 100: NSF8FunctionKey, 101: NSF9FunctionKey,
        109: NSF10FunctionKey, 103: NSF11FunctionKey, 111: NSF12FunctionKey]

    /// Keys stored by key code (everything else is stored as its character).
    static func isSpecial(_ code: UInt16) -> Bool { codeNames[code] != nil }

    static func label(_ key: KeyBinding.Key, option: Bool) -> String {
        let k: String
        switch key {
        case .character(let c): k = c.uppercased()
        case .code(let code): k = codeNames[code] ?? "Key \(code)"
        }
        return (option ? "⌥" : "") + k
    }

    /// "P", "⌥9", "—" when unassigned.
    static func label(_ id: String) -> String {
        guard let b = binding(id) else { return "—" }
        return label(b.key, option: b.option)
    }

    /// Several ids for one line of help, e.g. "P / X / U".
    static func labels(_ ids: [String], separator: String = " / ") -> String { ids.map(label).joined(separator: separator) }

    private static func equivalent(_ key: KeyBinding.Key) -> KeyEquivalent? {
        switch key {
        case .character(let c): return c.first.map { KeyEquivalent($0) }
        case .code(let code):
            switch code {
            case KeyCode.leftArrow: return .leftArrow
            case KeyCode.rightArrow: return .rightArrow
            case KeyCode.upArrow: return .upArrow
            case KeyCode.downArrow: return .downArrow
            case KeyCode.tab: return .tab
            case KeyCode.returnKey, KeyCode.keypadEnter: return .return
            case KeyCode.space: return .space
            case KeyCode.escape: return .escape
            case KeyCode.delete: return .delete
            case KeyCode.forwardDelete: return .deleteForward
            default: return functionKeys[code].flatMap { UnicodeScalar($0) }.map { KeyEquivalent(Character($0)) }
            }
        }
    }

    /// The menu shortcut for an action's current key (nil when unassigned), so menus always show — and only
    /// respond to — the key the user chose.
    static func menuShortcut(_ id: String, shift: Bool = false) -> KeyboardShortcut? {
        guard let b = binding(id), let eq = equivalent(b.key) else { return nil }
        var mods: EventModifiers = []
        if b.option { mods.insert(.option) }
        if shift { mods.insert(.shift) }
        return KeyboardShortcut(eq, modifiers: mods)
    }

    /// Menu shortcuts that are not in the key map; a custom key can shadow them (see `fixedShortcut`).
    static let fixedMenuKeys: [(key: Character, modifiers: EventModifiers, title: String)] = [
        ("s", .shift, "Stacks On"), ("s", .option, "Switch Bursts ↔ Similar"),
        ("[", .option, "Stricter Similarity"), ("]", .option, "Looser Similarity"),
        ("2", .option, "2 Compare Slots"), ("3", .option, "3 Compare Slots"), ("4", .option, "4 Compare Slots"),
    ]

    /// A fixed menu shortcut (e.g. ⇧S Stacks On) unless one of the user's keys now produces it — then the key
    /// map wins and the menu shows no shortcut rather than one that does something else.
    static func fixedShortcut(_ c: Character, _ mods: EventModifiers) -> KeyboardShortcut? {
        let option = mods.contains(.option), shift = mods.contains(.shift)
        let clash = bindings.contains { b in
            b.key == .character(String(c).lowercased()) && b.option == option && (!shift || b.shiftAdvances || b.shiftExtends)
        }
        return clash ? nil : KeyboardShortcut(KeyEquivalent(c), modifiers: mods)
    }

    /// Key hint for AppKit context menus.
    static func menuKey(_ id: String) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        guard let b = binding(id) else { return ("", []) }
        let key: String
        switch b.key {
        case .character(let c): key = c
        case .code(let code):
            switch code {
            case KeyCode.leftArrow: key = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case KeyCode.rightArrow: key = String(UnicodeScalar(NSRightArrowFunctionKey)!)
            case KeyCode.upArrow: key = String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case KeyCode.downArrow: key = String(UnicodeScalar(NSDownArrowFunctionKey)!)
            case KeyCode.delete: key = String(UnicodeScalar(NSBackspaceCharacter)!)
            case KeyCode.forwardDelete: key = String(UnicodeScalar(NSDeleteFunctionKey)!)
            case KeyCode.space: key = " "
            case KeyCode.tab: key = "\t"
            case KeyCode.returnKey, KeyCode.keypadEnter: key = "\r"
            case KeyCode.escape: key = "\u{1b}"
            default: key = functionKeys[code].flatMap { UnicodeScalar($0) }.map { String($0) } ?? ""
            }
        }
        return (key, b.option ? [.option] : [])
    }

    struct Match {
        var action: KeyAction
        var advance: Bool
        var extend = false
    }

    /// Resolves an event to an action. Events with ⌘ or ⌃ are left to the menus.
    static func match(_ event: NSEvent) -> Match? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) { return nil }
        let shift = mods.contains(.shift)
        let option = mods.contains(.option)
        let base = event.characters(byApplyingModifiers: [])?.lowercased() ?? ""
        let autoAdvance = mods.contains(.capsLock)

        for b in bindings {
            let keyMatches: Bool
            switch b.key {
            case .character(let c): keyMatches = base == c
            case .code(let code): keyMatches = event.keyCode == code
            }
            guard keyMatches, b.option == option else { continue }
            if shift && !b.shiftAdvances && !b.shiftExtends { continue }
            let isMark: Bool = { if case .mark = b.action { return true } else { return false } }()
            return Match(action: b.action, advance: isMark && (shift || autoAdvance), extend: shift && b.shiftExtends)
        }
        return nil
    }
}
