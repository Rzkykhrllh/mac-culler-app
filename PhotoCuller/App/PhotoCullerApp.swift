import SwiftUI
import CullerKit

@main
struct PhotoCullerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let app = AppModel.shared

    var body: some Scene {
        Window(AppConstants.appName, id: "main") {
            ContentView()
                .environment(app)
                .onAppear {
                    KeyboardController.shared.install()
                    #if DEBUG
                    // Development aid: `-openFolder <path>` opens a folder the sandbox can already reach (e.g. inside the container).
                    let args = ProcessInfo.processInfo.arguments
                    Log.session.info("Launch arguments: \(args, privacy: .public)")
                    if let i = args.firstIndex(of: "-openFolder"), args.indices.contains(i + 1) {
                        app.open(folder: URL(fileURLWithPath: args[i + 1]), securityScoped: false)
                        if args.contains("-selfTest") {
                            Task {
                                while app.session == nil { try? await Task.sleep(for: .milliseconds(100)) }
                                await DebugSelfTest.run(app.session!)
                            }
                        }
                    }
                    #endif
                }
        }
        .commands { AppCommands(app: app) }

        Window("Operation History", id: "history") {
            HistoryWindow().environment(app)
        }
        .defaultSize(width: 600, height: 420)

        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutsHelpView()
        }
        .defaultSize(width: 420, height: 620)

        Settings {
            SettingsView().environment(app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Flush pending metadata writes before quitting (spec §5.3.4).
        Task { @MainActor in
            await AppModel.shared.flushBeforeQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The keyboard reference, generated from the same table the key handler uses.
struct ShortcutsHelpView: View {
    var body: some View {
        List {
            Section("Single keys") {
                ForEach(Array(KeyMap.bindings.enumerated()), id: \.offset) { _, b in
                    HStack {
                        Text(b.title)
                        Spacer()
                        Text(label(b)).font(.body.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Modifiers") {
                row("Apply and advance once", "⇧ + P/X/U/0–9")
                row("Auto-advance after every mark", "Caps Lock")
                row("Extend selection (grid)", "⇧ + ← → ↑ ↓  ·  ⇧/⌘-click  ·  drag")
                row("Select all / deselect", "⌘A / ⇧⌘A")
                row("Expand / collapse all stacks", "⌥⌘→ / ⌥⌘←")
                row("RAW+JPEG one · separate · JPEG · RAW", "⌥⌘1 / 2 / 3 / 4")
                row("Sort by time · name · rating · date · size", "⌃⌘1 … 5")
                row("Reverse sort order", "⌃⌘R")
                row("Compare with 2 / 3 / 4 slots", "⌃⌘2 / 3 / 4")
                row("Move… / Copy…", "⇧⌘M / ⇧⌘C")
                row("Reveal in Finder", "⇧⌘R")
                row("Find / clear filters", "⌘F / ⌥⌘F")
                row("Thumbnail size", "⌘= / ⌘−")
                row("Enclosing / next / previous folder", "⌘↑ / ⌥⌘↓ / ⌥⌘↑")
                row("Show / hide sidebar", "⌃⌘S")
                row("Open folder / add to sidebar", "⌘O / ⇧⌘O")
                row("Include subfolders", "⌥⌘I")
                row("Close folder", "⇧⌘W")
                row("Retry failed saves", "⇧⌘S")
                row("Operation history", "⇧⌘Y")
                row("Undo / Redo", "⌘Z / ⇧⌘Z")
                row("Full screen", "⌃⌘F")
                row("Independent pan in compare", "hold ⌥ while panning")
                row("Put a photo in a compare slot", "drag it from the filmstrip onto the slot")
                row("Show / hide filmstrip", "⌥⌘B")
                row("Context menu", "right-click a photo")
            }
        }
    }

    private func row(_ a: String, _ b: String) -> some View {
        HStack { Text(a); Spacer(); Text(b).font(.body.monospaced()).foregroundStyle(.secondary) }
    }

    private func label(_ b: KeyBinding) -> String {
        let key: String
        switch b.key {
        case .character(let c): key = c.uppercased()
        case .code(let c):
            switch c {
            case KeyCode.leftArrow: key = "←"
            case KeyCode.rightArrow: key = "→"
            case KeyCode.upArrow: key = "↑"
            case KeyCode.downArrow: key = "↓"
            case KeyCode.tab: key = "Tab"
            case KeyCode.returnKey: key = "Return"
            case KeyCode.keypadEnter: key = "Enter"
            case KeyCode.space: key = "Space"
            case KeyCode.escape: key = "Esc"
            case KeyCode.f2: key = "F2"
            default: key = "?"
            }
        }
        return (b.option ? "⌥" : "") + key
    }
}
