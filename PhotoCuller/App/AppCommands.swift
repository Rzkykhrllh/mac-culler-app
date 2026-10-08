import SwiftUI
import CullerKit

/// Menu bar. Single-key shortcuts are handled by `KeyboardController` (menus would also fire while typing),
/// so menu titles show them as hints; ⌘ shortcuts are real key equivalents here.
struct AppCommands: Commands {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    private var session: FolderSession? { app.session }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder…") { app.showOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(app.recentFolders.entries) { e in
                    Button(e.path) { app.open(recent: e) }
                }
                Divider()
                Button("Clear Menu") { app.recentFolders.clear() }
            }
            Toggle("Include Subfolders", isOn: Binding(
                get: { session?.includeSubfolders ?? app.settings.includeSubfoldersByDefault },
                set: { v in
                    if session != nil { app.reopenCurrent(includeSubfolders: v) } else { app.settings.includeSubfoldersByDefault = v }
                }))
            Button("Close Folder") { Task { await app.closeSession() } }
                .disabled(session == nil)
            Divider()
            Button("Rename…  (F2)") { session?.activeSheet = .rename }
                .disabled(session == nil)
            Button("Move…") { session?.activeSheet = .move }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(session == nil)
            Button("Copy…") { session?.activeSheet = .copy }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(session == nil)
            Button("Reveal in Finder") {
                if let i = session?.currentItem { NSWorkspace.shared.activateFileViewerSelecting(i.files.allURLs) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(session?.currentItem == nil)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { session?.undo() }
                .keyboardShortcut("z")
                .disabled(!(session?.canUndo ?? false))
            Button("Redo") { session?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(session?.canRedo ?? false))
        }

        CommandMenu("Photo") {
            Button("Pick  (P)") { session?.apply(.flag(.pick)) }
            Button("Reject  (X)") { session?.apply(.flag(.reject)) }
            Button("Unflag  (U)") { session?.apply(.flag(.none)) }
            Divider()
            Menu("Rating") {
                ForEach(0...5, id: \.self) { r in
                    Button(r == 0 ? "None  (0)" : "\(String(repeating: "★", count: r))  (\(r))") { session?.apply(.rating(r)) }
                }
            }
            Menu("Color Label") {
                Button("Red  (6)") { session?.apply(.toggleLabel(.red)) }
                Button("Yellow  (7)") { session?.apply(.toggleLabel(.yellow)) }
                Button("Green  (8)") { session?.apply(.toggleLabel(.green)) }
                Button("Blue  (9)") { session?.apply(.toggleLabel(.blue)) }
                Button("Purple") { session?.apply(.toggleLabel(.purple)) }
                Divider()
                Button("None") { session?.apply(.setLabel(.none)) }
            }
            Button("Edit Note…  (M)") { session?.beginNoteEditing() }
            Divider()
            Button("Next Unflagged  (⌥→)") { session?.moveToUnflagged(1) }
            Button("Previous Unflagged  (⌥←)") { session?.moveToUnflagged(-1) }
            Divider()
            Button("Expand / Collapse Stack  (S)") { session?.toggleCurrentStack() }
            Button("Expand All Stacks") { session?.expandAllStacks(true) }
            Button("Collapse All Stacks") { session?.expandAllStacks(false) }
            Divider()
            Button("Retry Failed Saves") { session?.retryFailedWrites() }
                .disabled((session?.writeFailures ?? 0) == 0)
        }

        CommandGroup(before: .toolbar) {
            Button("Grid  (G)") { session?.viewMode = .grid }
            Button("Loupe  (E)") { if session?.currentID != nil { session?.viewMode = .loupe } }
            Button("Compare  (C)") { session?.enterCompare() }
            Divider()
            Button("Toggle 100% Zoom  (Z)") {
                guard let s = session else { return }
                s.viewports.toggleZoom(slot: s.viewMode == .compare ? s.compare.active : 0)
            }
            Button("Info Panel  (I)") { session?.showInfoPanel.toggle() }
            Button("Histogram  (H)") { session?.showHistogram.toggle() }
            Button("Find / Filter") { NotificationCenter.default.post(name: .focusFilterBar, object: nil) }
                .keyboardShortcut("f")
            Divider()
            Button("Larger Thumbnails") { app.settings.thumbnailSize = min(420, app.settings.thumbnailSize + 30) }
                .keyboardShortcut("+")
            Button("Smaller Thumbnails") { app.settings.thumbnailSize = max(90, app.settings.thumbnailSize - 30) }
                .keyboardShortcut("-")
            Divider()
        }

        CommandGroup(after: .windowArrangement) {
            Button("Operation History") { openWindow(id: "history") }
                .keyboardShortcut("y", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
                .keyboardShortcut("/", modifiers: .command)
        }

        CommandMenu("Debug") {
            Toggle("Show Debug Overlay", isOn: Binding(get: { app.settings.showDebugOverlay }, set: { app.settings.showDebugOverlay = $0 }))
            Button("Clear Caches") { app.clearCaches() }
        }
    }
}
