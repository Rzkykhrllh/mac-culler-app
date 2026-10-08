import SwiftUI
import CullerKit

/// Menu bar: every action is here with its shortcut (spec §9).
/// Single-key shortcuts are normally handled first by `KeyboardController`; while typing, keystrokes go
/// straight to the text field, so these key equivalents never fire by accident.
struct AppCommands: Commands {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    private var session: FolderSession? { app.session }
    private var canAct: Bool { session?.phase == .ready && session?.activeSheet == nil && session?.editingNote == nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { app.newTab() }
                .keyboardShortcut("t")
            Button("Open Folder…") { app.showOpenPanel() }
                .keyboardShortcut("o")
            Button("Open Folder in New Tab…") { app.showOpenPanel(newTab: true) }
                .keyboardShortcut("o", modifiers: [.command, .option])
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
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Close Tab") { app.closeTab() }
                .keyboardShortcut("w")
            Button("Reopen Closed Tab") { app.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Close Folder") { Task { await app.closeSession() } }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(session == nil)
            Divider()
            Button("Rename…") { session?.activeSheet = .rename }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)), modifiers: [])
                .disabled(!canAct)
            Button("Move…") { session?.activeSheet = .move }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!canAct)
            Button("Copy…") { session?.activeSheet = .copy }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!canAct)
            Button("Reveal in Finder") {
                if let s = session { NSWorkspace.shared.activateFileViewerSelecting(s.markTargets.flatMap(\.files.allURLs)) }
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

        // Standard text editing still works in text fields; outside them ⌘A selects all photos.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }.keyboardShortcut("x")
            Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }.keyboardShortcut("c")
            Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }.keyboardShortcut("v")
            Button("Select All") {
                if KeyboardController.isEditingText || session == nil {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                } else {
                    session?.selectAll()
                }
            }
            .keyboardShortcut("a")
            Button("Deselect All") { session?.selection = session?.currentID.map { [$0] } ?? [] }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(session == nil)
        }

        CommandMenu("Photo") {
            Group {
                Button("Pick") { session?.apply(.flag(.pick)) }.keyboardShortcut("p", modifiers: [])
                Button("Reject") { session?.apply(.flag(.reject)) }.keyboardShortcut("x", modifiers: [])
                Button("Unflag") { session?.apply(.flag(.none)) }.keyboardShortcut("u", modifiers: [])
                Button("Pick and Next") { session?.apply(.flag(.pick), advance: true) }.keyboardShortcut("p", modifiers: .shift)
                Button("Reject and Next") { session?.apply(.flag(.reject), advance: true) }.keyboardShortcut("x", modifiers: .shift)
            }
            .disabled(!canAct)
            Divider()
            Menu("Rating") {
                ForEach(0...5, id: \.self) { r in
                    Button(r == 0 ? "No Rating" : String(repeating: "★", count: r)) { session?.apply(.rating(r)) }
                        .keyboardShortcut(KeyEquivalent(Character("\(r)")), modifiers: [])
                }
            }
            .disabled(!canAct)
            Menu("Color Label") {
                Button("Red") { session?.apply(.toggleLabel(.red)) }.keyboardShortcut("6", modifiers: [])
                Button("Yellow") { session?.apply(.toggleLabel(.yellow)) }.keyboardShortcut("7", modifiers: [])
                Button("Green") { session?.apply(.toggleLabel(.green)) }.keyboardShortcut("8", modifiers: [])
                Button("Blue") { session?.apply(.toggleLabel(.blue)) }.keyboardShortcut("9", modifiers: [])
                Button("Purple") { session?.apply(.toggleLabel(.purple)) }.keyboardShortcut("9", modifiers: .option)
                Divider()
                Button("No Label") { session?.apply(.setLabel(.none)) }.keyboardShortcut("0", modifiers: .option)
            }
            .disabled(!canAct)
            Button("Edit Note…") { session?.beginNoteEditing() }
                .keyboardShortcut("m", modifiers: [])
                .disabled(!canAct)
            Divider()
            Group {
                Button("Next Photo") { session?.viewMode == .compare ? session?.stepActiveSlot(1) : session?.move(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("Previous Photo") { session?.viewMode == .compare ? session?.stepActiveSlot(-1) : session?.move(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next Unflagged") { session?.moveToUnflagged(1) }
                    .keyboardShortcut(.rightArrow, modifiers: .option)
                Button("Previous Unflagged") { session?.moveToUnflagged(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: .option)
            }
            .disabled(!canAct)
            Divider()
            Menu("Stacks") {
                Toggle("Stacks On", isOn: Binding(get: { app.settings.stackBursts }, set: { app.setStackBursts($0) }))
                    .keyboardShortcut("s", modifiers: .shift)
                Divider()
                Toggle("Group Bursts (Time)", isOn: Binding(get: { app.stackChoice == .bursts }, set: { if $0 { app.setStackChoice(.bursts) } }))
                Toggle("Group Similar Photos", isOn: Binding(get: { app.stackChoice == .similar }, set: { if $0 { app.setStackChoice(.similar) } }))
                Button("Switch Bursts ↔ Similar") { app.setStackChoice(app.stackChoice == .similar ? .bursts : .similar) }
                    .keyboardShortcut("s", modifiers: .option)
                Divider()
                Button("Stricter Similarity") { app.adjustSimilarity(-0.05) }
                    .keyboardShortcut("[", modifiers: .option)
                Button("Looser Similarity") { app.adjustSimilarity(0.05) }
                    .keyboardShortcut("]", modifiers: .option)
            }
            Group {
                Button("Expand / Collapse Selected Stacks") { session?.toggleSelectedStacks() }
                    .keyboardShortcut("s", modifiers: [])
                Button("Go to Sharpest in Stack") { session?.goToSharpest() }
                    .keyboardShortcut("b", modifiers: [])
                Button("Expand All Stacks") { session?.expandAllStacks(true) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Collapse All Stacks") { session?.expandAllStacks(false) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            }
            .disabled(!canAct)
            Divider()
            Button("Retry Failed Saves") { session?.retryFailedWrites() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled((session?.writeFailures ?? 0) == 0)
        }

        CommandGroup(before: .toolbar) {
            Group {
                Button("Grid") { session?.viewMode = .grid }.keyboardShortcut("g", modifiers: [])
                Button("Loupe") { if session?.currentID != nil { session?.viewMode = .loupe } }.keyboardShortcut("e", modifiers: [])
                Button("Compare") { session?.enterCompare() }.keyboardShortcut("c", modifiers: [])
                Button("Toggle 100% Zoom") {
                    guard let s = session else { return }
                    s.viewports.toggleZoom(slot: s.viewMode == .compare ? s.compare.active : 0)
                }
                .keyboardShortcut("z", modifiers: [])
            }
            .disabled(!canAct)
            Menu("RAW + JPEG") {
                ForEach(FileViewMode.allCases) { m in
                    Toggle(m.title, isOn: Binding(get: { (session?.fileView ?? app.settings.fileViewMode) == m },
                                                  set: { if $0 { if let s = session { s.setFileView(m) } else { app.settings.fileViewMode = m } } }))
                        .keyboardShortcut(KeyEquivalent(m.shortcutKey), modifiers: [.command, .option])
                }
            }
            Toggle("True RAW (no camera look)", isOn: Binding(get: { app.settings.rawRendering == .rendered },
                                                               set: { app.setRawRendering($0 ? .rendered : .embedded) }))
                .keyboardShortcut("r", modifiers: [.command, .option])
            Menu("Sort By") {
                ForEach(Array(SortKey.allCases.enumerated()), id: \.offset) { i, k in
                    Toggle(k.rawValue, isOn: Binding(get: { session?.sort.key == k }, set: { if $0 { session?.sort.key = k } }))
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .control])
                }
                Divider()
                Toggle("Descending", isOn: Binding(get: { session?.sort.ascending == false }, set: { session?.sort.ascending = !$0 }))
                    .keyboardShortcut("r", modifiers: [.command, .control])
            }
            .disabled(session == nil)
            Menu("Compare") {
                ForEach(2...4, id: \.self) { n in
                    Button("\(n) Slots") {
                        if session?.viewMode != .compare { session?.enterCompare() }
                        session?.compare.setSlotCount(n)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .option)
                }
                Divider()
                Toggle("Sync Zoom & Pan", isOn: Binding(get: { session?.compare.syncZoom ?? true }, set: { session?.compare.syncZoom = $0 }))
                    .keyboardShortcut("z", modifiers: .option)
                Toggle("Pin Current Best", isOn: Binding(get: { session?.compare.pinBest ?? false }, set: { session?.compare.pinBest = $0 }))
                    .keyboardShortcut("p", modifiers: .option)
                Toggle("Filmstrip Shows All Photos", isOn: Binding(get: { session?.compare.stripShowsAll ?? false },
                                                                   set: { session?.setCompareStripShowsAll($0) }))
                    .keyboardShortcut("a", modifiers: .option)
            }
            .disabled(session == nil)
            Divider()
            Group {
                Toggle("Info Panel", isOn: Binding(get: { session?.showInfoPanel ?? false }, set: { session?.showInfoPanel = $0 }))
                    .keyboardShortcut("i", modifiers: [])
                Toggle("Histogram", isOn: Binding(get: { session?.showHistogram ?? false }, set: { session?.showHistogram = $0 }))
                    .keyboardShortcut("h", modifiers: [])
                Toggle("Focus Peaking", isOn: Binding(get: { session?.showPeaking ?? false }, set: { session?.showPeaking = $0 }))
                    .keyboardShortcut("f", modifiers: [])
                Toggle("Highlight / Shadow Clipping", isOn: Binding(get: { session?.showClipping ?? false }, set: { session?.showClipping = $0 }))
                    .keyboardShortcut("j", modifiers: [])
                Button("Zoom to Eyes / Face / Animal") { session?.zoomToSubject() }
                    .keyboardShortcut("y", modifiers: [])
                Toggle("Filmstrip", isOn: Binding(get: { session?.showFilmstrip ?? true }, set: { session?.showFilmstrip = $0 }))
                    .keyboardShortcut("b", modifiers: [.command, .option])
            }
            .disabled(!canAct)
            Button("Find / Filter") { NotificationCenter.default.post(name: .focusFilterBar, object: nil) }
                .keyboardShortcut("f")
                .disabled(session == nil)
            Button("Clear Filters") { session?.filter = FilterState() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(!(session?.filter.isActive ?? false))
            Divider()
            Button("Larger Thumbnails") { app.settings.thumbnailSize = min(480, app.settings.thumbnailSize + 40) }
                .keyboardShortcut("=")
            Button("Smaller Thumbnails") { app.settings.thumbnailSize = max(90, app.settings.thumbnailSize - 40) }
                .keyboardShortcut("-")
            Button(app.sidebarVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar") { app.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
        }

        CommandMenu("Go") {
            Button("Home") { app.openFromSidebar(AccessGrants.realHome) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Desktop") { app.openFromSidebar(AccessGrants.realHome.appendingPathComponent("Desktop")) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Documents") { app.openFromSidebar(AccessGrants.realHome.appendingPathComponent("Documents")) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Downloads") { app.openFromSidebar(AccessGrants.realHome.appendingPathComponent("Downloads")) }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Button("Pictures") { app.openFromSidebar(AccessGrants.realHome.appendingPathComponent("Pictures")) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Enclosing Folder") { app.openParentFolder() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Next Folder") { app.openNeighbourFolder(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Folder") { app.openNeighbourFolder(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        }

        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Show Next Tab") { app.cycleTab(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Show Previous Tab") { app.cycleTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            ForEach(1...9, id: \.self) { n in
                Button(n == 9 ? "Last Tab" : "Tab \(n)") { app.selectTab(number: n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Divider()
            Button("Operation History") { openWindow(id: "history") }
                .keyboardShortcut("y", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
                .keyboardShortcut("/", modifiers: .command)
        }

        CommandMenu("Debug") {
            Toggle("Show Debug Overlay", isOn: Binding(get: { app.settings.showDebugOverlay }, set: { app.settings.showDebugOverlay = $0 }))
                .keyboardShortcut("d", modifiers: [.command, .option])
            Button("Clear Caches") { app.clearCaches() }
                .keyboardShortcut("k", modifiers: [.command, .option, .shift])
        }
    }
}
