import SwiftUI
import CullerKit

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $app.sidebarVisibility) {
            FolderSidebarView()
        } detail: {
            HStack(spacing: 0) {
            VStack(spacing: 0) {
                TabBar()
                if let s = app.session {
                    PathBar(session: s)
                    SessionView(session: s)
                        .id(ObjectIdentifier(s))
                } else if app.activeTab.pendingFolder != nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    WelcomeView()
                        .toolbar {
                            ToolbarItem(placement: .navigation) {
                                Button { app.showOpenPanel() } label: { Label("Open Folder", systemImage: "folder.badge.plus") }
                            }
                        }
                }
            }
            // The split view sizes the column from its content's *ideal* width (the widest ViewThatFits variant);
            // a small explicit ideal lets the window shrink while the bars switch to their compact variants.
            // Worst case still fits the 900 pt minimum window: sidebar ≤ 300 + info 260 + content ≥ 340.
            .frame(minWidth: 340, idealWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            // Info panel as a plain trailing column (SwiftUI's .inspector adds a nested split view with a
            // large minimum width that pushed the layout off-screen in small windows).
            if let s = app.session, s.showInfoPanel {
                InfoPanel(session: s)
                    .frame(width: 260)
                    .background(.ultraThinMaterial)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1) }
                    .transition(.move(edge: .trailing))
            }
            }
            .animation(.smooth(duration: 0.2), value: app.session?.showInfoPanel)
            .appBackdrop()
        }
        .onAppear { app.activateRestoredTabIfNeeded() }
        .frame(minWidth: 900, minHeight: 560)
        .background(WindowAccessor { window in
            KeyboardController.shared.mainWindow = window
            window.tabbingMode = .disallowed
        })
        .alert(item: $app.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message))
        }
        .navigationTitle(app.session?.folder.lastPathComponent ?? AppConstants.appName)
        .preferredColorScheme(.dark)
        .tint(Theme.accentStart)
    }
}

struct SessionView: View {
    @Bindable var session: FolderSession
    @FocusState private var filterFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if session.showFilterBar && !session.isFullScreen {
                    FilterBar(session: session, focused: $filterFocused)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                ZStack {
                    switch session.phase {
                    case .scanning:
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Scanning \(session.folder.lastPathComponent)…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failed(let msg):
                        ContentUnavailableView("Can’t Open Folder", systemImage: "exclamationmark.triangle", description: Text(msg))
                    case .ready:
                        switch session.viewMode {
                        case .grid: GridView(session: session)
                        case .loupe: LoupeView(session: session)
                        case .compare: CompareView(session: session)
                        }
                    }
                    if let hud = session.hud {
                        MarkHUDView(hud: hud)
                            .id(hud.id)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                    if session.showShortcuts {
                        Color.black.opacity(0.3).ignoresSafeArea().onTapGesture { session.showShortcuts = false }
                        ShortcutSheet { session.showShortcuts = false }
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                    if let id = session.editingNote {
                        Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { session.editingNote = nil }
                        NoteEditor(session: session, itemID: id)
                    }
                    if session.app.settings.showDebugOverlay {
                        DebugOverlay(pipeline: session.app.pipeline)
                    }
                    VStack(spacing: 6) {
                        if let t = session.toast {
                            Text(t).font(.callout.weight(.medium))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .glassCapsule()
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if session.viewMode != .grid && (session.showPeaking || session.showClipping) {
                            HStack(spacing: 6) {
                                if session.showPeaking { Chip(systemImage: "scope", text: "Focus peaking  F", tint: Color(red: 1, green: 0.35, blue: 0.3)) }
                                if session.showClipping { Chip(systemImage: "circle.lefthalf.filled", text: "Clipping  J", tint: .white) }
                            }
                            .padding(4).glassCapsule()
                        }
                        Spacer()
                    }
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                    .animation(.smooth(duration: 0.2), value: session.toast)
                }
                if !session.isFullScreen && session.viewMode == .grid {
                    Color.clear.frame(height: 44) // room for the floating status bar
                }
            }
            if !session.isFullScreen && session.viewMode == .grid {
                StatusBar(session: session)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .animation(.smooth(duration: 0.2), value: session.showFilterBar)
        .animation(.spring(duration: 0.22, bounce: 0.3), value: session.hud)
        .animation(.smooth(duration: 0.18), value: session.showShortcuts)
        .toolbar { SessionToolbar(session: session) }
        .sheet(item: $session.activeSheet) { sheet in
            switch sheet {
            case .rename: RenameSheet(session: session)
            case .move: MoveCopySheet(session: session, mode: .move)
            case .copy: MoveCopySheet(session: session, mode: .copy)
            }
        }
        .onChange(of: session.showFilterBar) { if session.showFilterBar { filterFocused = true } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { n in
            if (n.object as? NSWindow) === KeyboardController.shared.mainWindow { session.isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { n in
            if (n.object as? NSWindow) === KeyboardController.shared.mainWindow { session.isFullScreen = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusFilterBar)) { _ in
            session.showFilterBar = true
            filterFocused = true
        }
    }
}

extension Notification.Name {
    static let focusFilterBar = Notification.Name("PhotoCuller.focusFilterBar")
}

struct SessionToolbar: ToolbarContent {
    @Bindable var session: FolderSession

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: Binding(get: { session.viewMode }, set: { m in
                if m == .compare { session.enterCompare() } else { session.viewMode = m }
            })) {
                ForEach(ViewMode.allCases) { m in Label(m.title, systemImage: m.symbol).tag(m) }
            }
            .pickerStyle(.segmented)
            .help("Grid (G) · Loupe (E) · Compare (C)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if session.writeFailures > 0 {
                Button { session.retryFailedWrites() } label: {
                    Label("\(session.writeFailures) not saved", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .help("Some marks could not be written (e.g. read-only volume). They are kept and retried. Click to retry now (⇧⌘S).")
            }
            if session.viewMode == .grid {
                Slider(value: Binding(get: { session.settings.thumbnailSize }, set: { session.settings.thumbnailSize = $0 }), in: 90...480)
                    .frame(width: 110)
                    .help("Thumbnail size (⌘+ / ⌘−)")
            }
            Menu {
                Picker("Sort by", selection: $session.sort.key) {
                    ForEach(SortKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Order", selection: $session.sort.ascending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort (⌃⌘1–5, reverse ⌃⌘R)")
            Toggle(isOn: $session.showFilterBar) {
                Label("Filter", systemImage: session.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help("Filter bar (⌘F)")
            Toggle(isOn: $session.showInfoPanel) { Label("Info", systemImage: "info.circle") }
                .help("Info panel (I)")
        }
    }
}

/// Floating glass status bar.
struct StatusBar: View {
    let session: FolderSession

    var body: some View {
        let picks = session.items.values.filter { $0.metadata.flag == .pick }.count
        let rejects = session.items.values.filter { $0.metadata.flag == .reject }.count
        // Secondary chips drop out first when the window is narrow.
        ViewThatFits(in: .horizontal) {
            row(picks: picks, rejects: rejects, compact: false)
            row(picks: picks, rejects: rejects, compact: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassCapsule()
    }

    private func row(picks: Int, rejects: Int, compact: Bool) -> some View {
        HStack(spacing: 8) {
            Chip(systemImage: "photo.on.rectangle", text: "\(session.matchingCount) of \(session.items.count)")
            if !compact, session.display.count != session.matchingCount {
                Chip(text: "\(session.display.count) shown")
            }
            if session.selection.count > 1 { Chip(systemImage: "checkmark.circle", text: "\(session.selection.count) selected", tint: Theme.accentStart) }
            if !compact, session.includeSubfolders { Chip(systemImage: "folder.badge.plus", text: "Subfolders") }
            if !compact, session.fileView != .combined { Chip(systemImage: "square.stack.3d.down.right", text: session.fileView.shortTitle) }
            if let p = session.indexing {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: compact ? 40 : 70).controlSize(.small)
                if !compact { Chip(text: "Indexing \(p.done)/\(p.total)") }
            }
            if let p = session.analysisProgress {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: compact ? 40 : 70).controlSize(.small)
                if !compact { Chip(systemImage: "scope", text: "Checking focus \(p.done)/\(p.total)") }
            }
            if let p = session.similarityProgress {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: compact ? 40 : 70).controlSize(.small)
                if !compact { Chip(systemImage: "sparkles", text: "Finding similar \(p.done)/\(p.total)") }
            }
            if let p = session.fileOperation {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: 70).controlSize(.small)
                Chip(text: "\(p.title) \(p.done)/\(p.total)")
            }
            Spacer(minLength: 8)
            if session.app.capsLockOn {
                Chip(systemImage: "forward.fill", text: compact ? "Auto" : "Auto-advance", tint: Theme.accentStart)
                    .help("Caps Lock is on: marking moves to the next photo")
            }
            Chip(systemImage: "flag.fill", text: "\(picks)", tint: .white).help("Picks")
            Chip(systemImage: "xmark.circle.fill", text: "\(rejects)", tint: .red.opacity(0.9)).help("Rejects")
        }
    }
}

/// Load times and cache hit rates (Debug menu).
struct DebugOverlay: View {
    let pipeline: ImagePipeline

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let s = pipeline.stats
            VStack(alignment: .leading, spacing: 2) {
                Text("Thumbs: \(s.thumbRequests) req · hit \(Int(s.thumbHitRate * 100))% (mem \(s.thumbMemoryHits), disk \(s.thumbDiskHits)) · gen \(s.thumbGenerated)")
                Text("Previews: \(s.previewRequests) req · hit \(Int(s.previewHitRate * 100))% · last \(String(format: "%.0f", s.lastPreviewMs)) ms · avg \(String(format: "%.0f", s.avgPreviewMs)) ms")
                Text("Full decodes: \(s.fullDecodes) · last \(String(format: "%.0f", s.lastFullMs)) ms · failures \(s.failures)")
            }
            .font(.caption2.monospaced())
            .padding(8)
            .glassCard(10)
            .foregroundStyle(.green)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(8)
            .allowsHitTesting(false)
        }
    }
}

/// Gives access to the hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
    }
}
