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
                    if args.contains("-hangWatch") { HangWatch.start() }
                    if let i = args.firstIndex(of: "-openFolder"), args.indices.contains(i + 1) {
                        app.open(folder: URL(fileURLWithPath: args[i + 1]), securityScoped: false,
                                 includeSubfolders: args.contains("-subfolders") ? true : nil)
                        if args.contains("-expandTest") {
                            Task {
                                while app.session == nil { try? await Task.sleep(for: .milliseconds(100)) }
                                await DebugSelfTest.runExpand(app.session!)
                            }
                        }
                        if args.contains("-uiSnapshots") {
                            Task {
                                while app.session == nil { try? await Task.sleep(for: .milliseconds(100)) }
                                await DebugSelfTest.runSnapshots(app.session!)
                            }
                        }
                        if args.contains("-focusTest") {
                            Task {
                                while app.session == nil { try? await Task.sleep(for: .milliseconds(100)) }
                                await DebugSelfTest.runFocus(app.session!)
                            }
                        }
                        if args.contains("-similarityTest") {
                            Task {
                                while app.session == nil { try? await Task.sleep(for: .milliseconds(100)) }
                                await DebugSelfTest.runSimilarity(app.session!)
                            }
                        }
                        if args.contains("-shortcutTest") {
                            Task {
                                while app.session == nil { try? await Task.sleep(for: .milliseconds(100)) }
                                await DebugSelfTest.runShortcuts(app.session!)
                            }
                        }
                        if args.contains("-modeTest") {
                            Task {
                                while app.session == nil { try? await Task.sleep(for: .milliseconds(100)) }
                                await DebugSelfTest.runModeSwitch(app.session!)
                            }
                        }
                        if args.contains("-scrollTest") {
                            Task {
                                while app.session == nil { try? await Task.sleep(for: .milliseconds(100)) }
                                await DebugSelfTest.runScroll(app.session!)
                            }
                        }
                        if args.contains("-trashTest") {
                            Task {
                                while app.session == nil { try? await Task.sleep(for: .milliseconds(100)) }
                                await DebugSelfTest.runTrash(app.session!)
                            }
                        }
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
        // The minimum window size is set on the NSWindow itself (ContentView's WindowAccessor). `.contentMinSize`
        // made SwiftUI re-measure the whole window (every ViewThatFits variant) on each tiny update — with a big
        // folder's progress updates that alone kept the main thread busy.
        .windowResizability(.automatic)
        .defaultSize(width: 1400, height: 900)
        .commands { AppCommands(app: app) }

        Window("Operation History", id: "history") {
            HistoryWindow().environment(app)
        }
        .defaultSize(width: 600, height: 420)

        Window("About \(AppConstants.appName)", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

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
    private var menuObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS inserts "Emoji & Symbols" / "Start Dictation" into the Edit menu itself; with custom Edit
        // commands it can do so twice. Remove duplicates whenever the menu changes.
        Self.dedupeMenus()
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.dedupeMenus() }
        }
    }

    static func dedupeMenus() {
        guard let main = NSApp.mainMenu else { return }
        for top in main.items {
            guard let menu = top.submenu else { continue }
            var seen = Set<String>()
            for item in menu.items.reversed() where !item.isSeparatorItem {
                let key = "\(item.title)|\(item.keyEquivalent)|\(item.keyEquivalentModifierMask.rawValue)"
                if seen.contains(key), item.title.contains("Emoji") || item.title.contains("Dictation") {
                    menu.removeItem(item)
                } else {
                    seen.insert(key)
                }
            }
        }
    }

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
                row("Stacks on / off", "⇧S")
                row("Stacks by bursts ↔ similar photos", "⌥S")
                row("Similarity stricter / looser", "⌥[ / ⌥]")
                row("Expand / collapse a stack", "double-click it · S")
                row("RAW+JPEG one · separate · JPEG · RAW", "⌥⌘1 / 2 / 3 / 4")
                row("RAW look: True RAW ↔ camera preview", "⌥⌘R")
                row("Sort by time · name · rating · date · size", "⌃⌘1 … 5")
                row("Reverse sort order", "⌃⌘R")
                row("Compare with 2 / 3 / 4 slots", "⌥2 / ⌥3 / ⌥4")
                row("Move… / Copy…", "⇧⌘M / ⇧⌘C")
                row("Move to Trash / all rejects to Trash", "⌫ or ⌘⌫ / ⇧⌘⌫")
                row("Import to Lightroom / all picks", "⌃⌘L / ⌃⇧⌘L")
                row("Reveal in Finder", "⇧⌘R")
                row("Find / clear filters", "⌘F / ⌥⌘F")
                row("Thumbnail size", "⌘= / ⌘−")
                row("New tab / close tab / reopen closed", "⌘T / ⌘W / ⇧⌘T")
                row("Next / previous tab", "⌃Tab / ⌃⇧Tab")
                row("Go to tab 1…8 / last", "⌘1 … ⌘8 / ⌘9")
                row("Open folder in new tab", "⌥⌘O · ⌘-click in sidebar or path bar")
                row("Home · Desktop · Documents · Downloads · Pictures", "⇧⌘H · ⇧⌘D · ⇧⌘O · ⌥⌘L · ⇧⌘P")
                row("Enclosing / next / previous folder", "⌘↑ / ⌥⌘↓ / ⌥⌘↑")
                row("Show / hide sidebar", "⌃⌘S")
                row("Open folder", "⌘O")
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
