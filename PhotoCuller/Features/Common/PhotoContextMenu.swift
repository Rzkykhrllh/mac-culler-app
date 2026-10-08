import AppKit
import CullerKit

/// Target object that runs a closure; kept alive by the menu item's `representedObject`.
private final class MenuAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

/// Menu item running a closure. `key` is shown as the shortcut hint: a context menu only uses key
/// equivalents while it is open, so showing the real shortcut never makes it fire elsewhere.
@MainActor
func ActionMenuItem(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], enabled: Bool = true,
                    handler: @escaping () -> Void) -> NSMenuItem {
    let action = MenuAction(handler)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = action
    item.representedObject = action
    item.isEnabled = enabled
    return item
}

/// Right-click menu for the photos a command would act on (grid selection, loupe photo, active compare slot).
enum PhotoContextMenu {
    static func make(_ s: FolderSession) -> NSMenu? {
        let targets = s.markTargets
        guard !targets.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if targets.count > 1 {
            let header = NSMenuItem(title: "\(targets.count) Photos Selected", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }
        let single = targets.count == 1 ? targets[0].metadata : nil

        func check(_ item: NSMenuItem, _ on: Bool) -> NSMenuItem { item.state = on ? .on : .off; return item }

        menu.addItem(check(ActionMenuItem("Pick", key: "p") { s.apply(.flag(.pick)) }, single?.flag == .pick))
        menu.addItem(check(ActionMenuItem("Reject", key: "x") { s.apply(.flag(.reject)) }, single?.flag == .reject))
        menu.addItem(check(ActionMenuItem("Unflag", key: "u") { s.apply(.flag(.none)) }, single?.flag == Flag.none))

        let rating = NSMenu()
        for r in 0...5 {
            rating.addItem(check(ActionMenuItem(r == 0 ? "No Rating" : String(repeating: "★", count: r), key: "\(r)") { s.apply(.rating(r)) },
                                 single?.rating == r))
        }
        menu.addItem(submenu("Rating", rating))

        let labels = NSMenu()
        let keyed: [(ColorLabel, String, NSEvent.ModifierFlags)] = [
            (.red, "6", []), (.yellow, "7", []), (.green, "8", []), (.blue, "9", []), (.purple, "9", [.option]),
        ]
        for (l, k, m) in keyed {
            let item = check(ActionMenuItem(l.displayName, key: k, modifiers: m) { s.apply(.toggleLabel(l)) }, single?.label == l)
            item.image = swatch(l)
            labels.addItem(item)
        }
        labels.addItem(.separator())
        labels.addItem(ActionMenuItem("No Label", key: "0", modifiers: [.option]) { s.apply(.setLabel(.none)) })
        menu.addItem(submenu("Color Label", labels))
        menu.addItem(ActionMenuItem(targets.count == 1 && targets[0].metadata.hasNote ? "Edit Note…" : "Add Note…", key: "m") { s.beginNoteEditing() })

        menu.addItem(.separator())
        if s.viewMode != .loupe {
            menu.addItem(ActionMenuItem("Open in Loupe", key: "e") {
                if let first = targets.first { s.select(first.id); s.viewMode = .loupe }
            })
        }
        if s.viewMode != .compare {
            menu.addItem(ActionMenuItem(targets.count > 1 ? "Compare Selected" : "Compare", key: "c") { s.enterCompare() })
        } else {
            menu.addItem(ActionMenuItem("Back to Grid", key: "g") { s.viewMode = .grid })
        }
        let ids = Set(targets.map(\.id)).union(s.selection)
        let stacks = Set(ids.compactMap { s.stackOf[$0] })
        if !stacks.isEmpty {
            let expand = stacks.contains { !s.expandedStacks.contains($0) }
            let title = expand ? (stacks.count > 1 ? "Expand \(stacks.count) Stacks" : "Expand Stack")
                               : (stacks.count > 1 ? "Collapse \(stacks.count) Stacks" : "Collapse Stack")
            menu.addItem(ActionMenuItem(title, key: "s") { s.toggleSelectedStacks() })
        }

        if s.viewMode != .grid {
            menu.addItem(ActionMenuItem("Zoom to Eyes / Face", key: "y") { s.zoomToSubject() })
        }
        if !stacks.isEmpty {
            menu.addItem(ActionMenuItem("Go to Sharpest in Stack", key: "b") { s.goToSharpest() })
        }
        menu.addItem(check(ActionMenuItem("Focus Peaking", key: "f") { s.showPeaking.toggle() }, s.showPeaking))
        menu.addItem(check(ActionMenuItem("Clipping", key: "j") { s.showClipping.toggle() }, s.showClipping))

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Rename…", key: String(UnicodeScalar(NSF2FunctionKey)!)) { s.activeSheet = .rename })
        menu.addItem(ActionMenuItem("Move…", key: "m", modifiers: [.command, .shift]) { s.activeSheet = .move })
        menu.addItem(ActionMenuItem("Copy…", key: "c", modifiers: [.command, .shift]) { s.activeSheet = .copy })

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Reveal in Finder", key: "r", modifiers: [.command, .shift]) {
            NSWorkspace.shared.activateFileViewerSelecting(targets.flatMap(\.files.allURLs))
        })
        menu.addItem(check(ActionMenuItem("Show Info", key: "i") { s.showInfoPanel.toggle() }, s.showInfoPanel))
        return menu
    }

    private static func submenu(_ title: String, _ m: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = m
        return item
    }

    private static func swatch(_ l: ColorLabel) -> NSImage {
        let color: NSColor = [.red: .systemRed, .yellow: .systemYellow, .green: .systemGreen, .blue: .systemBlue, .purple: .systemPurple][l] ?? .clear
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r).fill()
            return true
        }
    }
}
