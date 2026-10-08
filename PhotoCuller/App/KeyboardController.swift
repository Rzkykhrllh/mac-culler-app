import AppKit

/// Routes single-key shortcuts from the main window to the session (spec §9).
/// Installed as a local event monitor so it works whichever AppKit view has focus,
/// while leaving text fields, sheets and ⌘/⌃ shortcuts (menus) alone.
final class KeyboardController {
    static let shared = KeyboardController()
    private var monitor: Any?
    /// The main browsing window; key handling is limited to it.
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

    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === mainWindow, window.attachedSheet == nil else { return false }
        if let r = window.firstResponder, r is NSText || r is NSTextField || r is NSSearchField { return false }
        guard let session = AppModel.shared.session, session.phase == .ready, session.editingNote == nil else { return false }
        // ⌘A selects all photos unless a text field is focused (checked above).
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.charactersIgnoringModifiers == "a" {
            session.selectAll()
            return true
        }
        guard let match = KeyMap.match(event) else { return false }
        return session.perform(match)
    }
}
