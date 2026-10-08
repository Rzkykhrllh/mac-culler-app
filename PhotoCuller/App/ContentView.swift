import SwiftUI
import CullerKit

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if let s = app.session {
                SessionView(session: s)
                    .id(ObjectIdentifier(s))
            } else {
                WelcomeView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(WindowAccessor { window in
            KeyboardController.shared.mainWindow = window
            window.tabbingMode = .disallowed
        })
        .alert(item: $app.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message))
        }
        .navigationTitle(app.session?.folder.lastPathComponent ?? AppConstants.appName)
    }
}

struct SessionView: View {
    @Bindable var session: FolderSession
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if session.showFilterBar && !session.isFullScreen {
                FilterBar(session: session, focused: $filterFocused)
                Divider()
            }
            ZStack {
                switch session.phase {
                case .scanning:
                    ProgressView("Scanning \(session.folder.lastPathComponent)…")
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
                if let id = session.editingNote {
                    Color.black.opacity(0.2).ignoresSafeArea().onTapGesture { session.editingNote = nil }
                    NoteEditor(session: session, itemID: id)
                }
                if session.app.settings.showDebugOverlay {
                    DebugOverlay(pipeline: session.app.pipeline)
                }
            }
            if !session.isFullScreen {
                Divider()
                StatusBar(session: session)
            }
        }
        .inspector(isPresented: $session.showInfoPanel) {
            InfoPanel(session: session)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar { SessionToolbar(session: session) }
        .sheet(item: $session.activeSheet) { sheet in
            switch sheet {
            case .rename: RenameSheet(session: session)
            case .move: MoveCopySheet(session: session, mode: .move)
            case .copy: MoveCopySheet(session: session, mode: .copy)
            }
        }
        .onChange(of: session.showFilterBar) { if session.showFilterBar { filterFocused = true } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in session.isFullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in session.isFullScreen = false }
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
        ToolbarItem(placement: .navigation) {
            Button { session.app.showOpenPanel() } label: { Label("Open Folder", systemImage: "folder") }
                .help("Open Folder… (⌘O)")
        }
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
                .help("Some marks could not be written (e.g. read-only volume). They are kept and retried. Click to retry now.")
            }
            if session.viewMode == .grid {
                Slider(value: Binding(get: { session.settings.thumbnailSize }, set: { session.settings.thumbnailSize = $0 }), in: 90...420)
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
            .help("Sort")
            Toggle(isOn: $session.showFilterBar) {
                Label("Filter", systemImage: session.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help("Filter bar (⌘F)")
            Toggle(isOn: $session.showInfoPanel) { Label("Info", systemImage: "info.circle") }
                .help("Info panel (I)")
        }
    }
}

struct StatusBar: View {
    let session: FolderSession

    var body: some View {
        HStack(spacing: 14) {
            Text("\(session.display.count) shown · \(session.matchingCount) of \(session.items.count) photos")
            if session.selection.count > 1 { Text("\(session.selection.count) selected") }
            if session.includeSubfolders { Label("Subfolders", systemImage: "folder.badge.plus") }
            if let p = session.indexing {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: 80)
                Text("Indexing EXIF \(p.done)/\(p.total)")
            }
            if let p = session.fileOperation {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total))).frame(width: 80)
                Text("\(p.title) \(p.done)/\(p.total)")
            }
            Spacer()
            if session.app.capsLockOn {
                Label("Auto-advance", systemImage: "forward.fill").foregroundStyle(.tint)
                    .help("Caps Lock is on: marking moves to the next photo")
            }
            let picks = session.items.values.filter { $0.metadata.flag == .pick }.count
            let rejects = session.items.values.filter { $0.metadata.flag == .reject }.count
            Label("\(picks)", systemImage: "flag.fill").help("Picks")
            Label("\(rejects)", systemImage: "xmark.circle").help("Rejects")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
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
            .padding(6)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
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
