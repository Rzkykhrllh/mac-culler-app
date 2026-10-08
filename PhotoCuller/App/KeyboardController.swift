import AppKit

/// Routes single-key shortcuts from the main window to the session (spec §9).
/// Installed as a local event monitor, so it sees keys before menus and the focused view.
final class KeyboardController {
    static let shared = KeyboardController()
    private var monitor: Any?
    /// The main browsing window; photo shortcuts are limited to it.
    weak var mainWindow: NSWindow?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            if event.type == .flagsChanged {
                AppModel.shared.capsLockOn = event.modifierFlags.contains(.capsLock)
                return event
            }
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    /// Keys that keep their normal meaning in text fields (dialog default / cancel buttons, focus movement).
    private static let passThroughInText: Set<UInt16> = [KeyCode.escape, KeyCode.returnKey, KeyCode.keypadEnter, KeyCode.tab]

    /// True while the user is typing in any text field.
    static var isEditingText: Bool { NSApp.keyWindow?.firstResponder is NSText }

    private func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])

        // Typing: plain keys go straight to the focused text field, so the single-key menu shortcuts
        // (P, X, 0–9 …) never fire while writing a note or a rename template — in any window.
        if let text = event.window?.firstResponder as? NSText {
            guard !mods.contains(.command), !mods.contains(.control), !Self.passThroughInText.contains(event.keyCode) else { return false }
            text.keyDown(with: event)
            return true
        }

        guard let window = event.window, window === mainWindow, window.attachedSheet == nil else { return false }
        guard let session = AppModel.shared.session, session.phase == .ready, session.editingNote == nil else { return false }
        guard let match = KeyMap.match(event) else { return false }
        return session.perform(match)
    }
}
