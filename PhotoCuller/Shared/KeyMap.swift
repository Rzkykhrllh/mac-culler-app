import AppKit
import CullerKit

/// Single-key actions (spec §9). Hardcoded in v1, but defined in this one table so v2 can make it customizable.
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
}

struct KeyBinding {
    enum Key: Equatable {
        case character(String)   // layout-independent base character (no modifiers applied)
        case code(UInt16)        // virtual key code for non-character keys
    }

    var key: Key
    /// Shift variant applies the action and then advances once (marking keys only).
    var shiftAdvances = false
    var option = false
    var action: KeyAction
    var title: String
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
}

enum KeyMap {
    static let bindings: [KeyBinding] = {
        var b: [KeyBinding] = [
            .init(key: .character("p"), shiftAdvances: true, action: .mark(.flag(.pick)), title: "Pick"),
            .init(key: .character("x"), shiftAdvances: true, action: .mark(.flag(.reject)), title: "Reject"),
            .init(key: .character("u"), shiftAdvances: true, action: .mark(.flag(.none)), title: "Unflag"),
        ]
        for r in 0...5 {
            b.append(.init(key: .character("\(r)"), shiftAdvances: true, action: .mark(.rating(r)),
                           title: r == 0 ? "Clear rating" : "\(r) star\(r == 1 ? "" : "s")"))
        }
        let labels: [(String, ColorLabel)] = [("6", .red), ("7", .yellow), ("8", .green), ("9", .blue)]
        for (k, l) in labels {
            b.append(.init(key: .character(k), shiftAdvances: true, action: .mark(.toggleLabel(l)), title: "\(l.displayName) label"))
        }
        b += [
            .init(key: .code(KeyCode.rightArrow), action: .next, title: "Next photo"),
            .init(key: .code(KeyCode.leftArrow), action: .previous, title: "Previous photo"),
            .init(key: .code(KeyCode.upArrow), action: .up, title: "Up (grid)"),
            .init(key: .code(KeyCode.downArrow), action: .down, title: "Down (grid)"),
            .init(key: .code(KeyCode.rightArrow), option: true, action: .nextUnflagged, title: "Next unflagged"),
            .init(key: .code(KeyCode.leftArrow), option: true, action: .previousUnflagged, title: "Previous unflagged"),
            .init(key: .character("s"), action: .toggleStack, title: "Expand / collapse stack"),
            .init(key: .character("g"), action: .showGrid, title: "Grid"),
            .init(key: .character("e"), action: .showLoupe, title: "Loupe"),
            .init(key: .character("c"), action: .showCompare, title: "Compare"),
            .init(key: .code(KeyCode.tab), action: .switchSlot, title: "Switch compare slot"),
            .init(key: .code(KeyCode.returnKey), action: .enter, title: "Open in loupe / promote candidate"),
            .init(key: .code(KeyCode.keypadEnter), action: .enter, title: "Open in loupe / promote candidate"),
            .init(key: .character("z"), action: .toggleZoom, title: "Toggle 100% zoom"),
            .init(key: .code(KeyCode.space), action: .toggleZoom, title: "Toggle 100% zoom"),
            .init(key: .character("i"), action: .toggleInfo, title: "Info panel"),
            .init(key: .character("h"), action: .toggleHistogram, title: "Histogram"),
            .init(key: .character("m"), action: .editNote, title: "Edit note"),
            .init(key: .code(KeyCode.f2), action: .rename, title: "Rename…"),
            .init(key: .code(KeyCode.escape), action: .escape, title: "Back"),
        ]
        return b
    }()

    struct Match {
        var action: KeyAction
        var advance: Bool
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
            if shift && !b.shiftAdvances { continue }
            let isMark: Bool = { if case .mark = b.action { return true } else { return false } }()
            return Match(action: b.action, advance: isMark && (shift || autoAdvance))
        }
        return nil
    }
}
