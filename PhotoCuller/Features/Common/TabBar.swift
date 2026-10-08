import SwiftUI
import CullerKit

/// Browser-like tab strip: each tab is its own folder workspace.
struct TabBar: View {
    @Environment(AppModel.self) private var app
    @State private var hovered: UUID?

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(app.tabs.enumerated()), id: \.element.id) { i, tab in
                        TabPill(tab: tab, index: i, active: tab.id == app.activeTabID, hovered: hovered == tab.id)
                            .onHover { hovered = $0 ? tab.id : (hovered == tab.id ? nil : hovered) }
                            .onTapGesture { app.selectTab(tab) }
                            .draggable(tab.id.uuidString)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let s = ids.first, let src = app.tabs.first(where: { $0.id.uuidString == s }) else { return false }
                                app.moveTab(src, before: tab)
                                return true
                            }
                            .contextMenu {
                                Button("New Tab") { app.newTab() }
                                Button("Duplicate Tab") { app.newTab(folder: tab.folder) }
                                Divider()
                                Button("Close Tab") { app.closeTab(tab) }
                                Button("Close Other Tabs") { for t in app.tabs where t.id != tab.id { app.closeTab(t) } }
                            }
                    }
                }
                .padding(.horizontal, 2)
            }
            Button { app.newTab() } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .glass(in: Circle(), interactive: true)
            .help("New Tab (⌘T)")
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

private struct TabPill: View {
    @Environment(AppModel.self) private var app
    let tab: WorkspaceTab
    let index: Int
    let active: Bool
    let hovered: Bool

    var body: some View {
        HStack(spacing: 6) {
            if tab.session?.phase == .scanning || tab.session?.indexing != nil {
                ProgressView().controlSize(.mini).frame(width: 14)
            } else {
                Image(systemName: tab.folder == nil ? "plus.square.dashed" : (active ? "folder.fill" : "folder"))
                    .font(.system(size: 11))
                    .foregroundStyle(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            }
            Text(tab.title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            if let s = tab.session, s.phase == .ready {
                Text("\(s.items.count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            if index < 9 {
                Text("⌘\(index + 1)").font(.caption2).foregroundStyle(.tertiary).opacity(hovered || active ? 1 : 0)
            }
            Button { app.closeTab(tab) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .opacity(hovered || active ? 1 : 0)
            .help("Close Tab (⌘W)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background {
            if active {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1)
            } else if hovered {
                Capsule().fill(Color.white.opacity(0.05))
            }
        }
        .contentShape(Capsule())
        .help(tab.folder?.path ?? "Empty tab")
    }
}

/// Finder-like path bar for the current folder + chips for its subfolders (click to go there).
struct PathBar: View {
    @Environment(AppModel.self) private var app
    let session: FolderSession
    @State private var subfolders: [URL] = []

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { i, url in
                        if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary) }
                        Button {
                            app.openFromSidebar(url, newTab: NSEvent.modifierFlags.contains(.command))
                        } label: {
                            Text(i == 0 && url.path == "/" ? "Macintosh HD" : url.lastPathComponent)
                                .font(.system(size: 11, weight: i == segments.count - 1 ? .semibold : .regular))
                                .foregroundStyle(i == segments.count - 1 ? .primary : .secondary)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(url.path)
                    }
                    if !subfolders.isEmpty {
                        Divider().frame(height: 14).padding(.horizontal, 6)
                        ForEach(subfolders, id: \.self) { u in
                            Button {
                                app.openFromSidebar(u, newTab: NSEvent.modifierFlags.contains(.command))
                            } label: {
                                Label(u.lastPathComponent, systemImage: "folder")
                                    .font(.system(size: 11))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.white.opacity(0.07), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Open \(u.lastPathComponent) (⌘-click: new tab)")
                        }
                    }
                }
            }
            SubfolderToggle(session: session)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .task(id: session.folder) {
            let folder = session.folder
            subfolders = await Task.detached(priority: .utility) {
                let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                                         options: [.skipsHiddenFiles])) ?? []
                return urls.filter {
                    let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    return v?.isDirectory == true && v?.isPackage != true
                }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }.value
        }
    }

    /// From the home folder (or volume root) down to the current folder.
    private var segments: [URL] {
        let folder = session.folder.standardizedFileURL
        let home = AccessGrants.realHome.standardizedFileURL
        var parts: [URL] = []
        var u = folder
        while true {
            parts.insert(u, at: 0)
            if u == home || u.path == "/" || u.deletingLastPathComponent().path == "/Volumes" { break }
            let p = u.deletingLastPathComponent()
            if p.path == u.path { break }
            u = p
        }
        return parts
    }
}

/// On: the folder and every folder inside it (all levels) are scanned as one shoot.
struct SubfolderToggle: View {
    @Environment(AppModel.self) private var app
    let session: FolderSession

    var body: some View {
        let on = session.includeSubfolders
        Button { app.reopenCurrent(includeSubfolders: !on) } label: {
            Label("Subfolders", systemImage: on ? "folder.fill.badge.plus" : "folder.badge.plus")
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(on ? Theme.accentStart.opacity(0.14) : Color.white.opacity(0.06), in: Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help(on ? "Showing photos from this folder and every folder inside it. Click to show only this folder (⌥⌘I)."
                 : "Show only this folder. Click to also include every folder inside it, all levels deep (⌥⌘I).")
    }
}

/// The "what is shown" row right above the photos: Files (RAW / JPG mode) → Stacks → RAW look, always in that
/// order and left-aligned. Picks the widest variant that fits, so it never pushes the window content off-screen.
struct FileViewSwitcher: View {
    @Environment(AppModel.self) private var app
    let session: FolderSession

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(compact: false, labels: true)
            bar(compact: true, labels: true)
            bar(compact: true, labels: false)
            menu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var showsRawLook: Bool { session.fileView != .combined && session.fileView != .jpegOnly }

    private var modeBinding: Binding<FileViewMode> { Binding(get: { session.fileView }, set: { session.setFileView($0) }) }
    private var stackBinding: Binding<StackChoice> { Binding(get: { app.stackChoice }, set: { app.setStackChoice($0) }) }
    private var rawBinding: Binding<RawRendering> { Binding(get: { app.settings.rawRendering }, set: { app.setRawRendering($0) }) }

    private func bar(compact: Bool, labels: Bool) -> some View {
        HStack(spacing: compact ? 10 : 14) {
            group("Files", labels) {
                ChoiceBar(options: FileViewMode.allCases.map {
                    .init(value: $0, title: $0.segmentTitle, help: Explain.fileView($0))
                }, selection: modeBinding)
            }
            group("Stacks", labels) {
                ChoiceBar(options: StackChoice.allCases.map {
                    .init(value: $0, title: $0.title, symbol: $0.symbol, help: Explain.stacks($0))
                }, selection: stackBinding, compact: compact)
                if app.stackChoice == .similar {
                    SimilarityControl()
                }
            }
            if showsRawLook {
                group("RAW look", labels) {
                    ChoiceBar(options: RawRendering.allCases.reversed().map {
                        .init(value: $0, title: $0 == .rendered ? "True RAW" : (compact ? "Camera" : "Camera Preview"), help: Explain.rawLook($0))
                    }, selection: rawBinding)
                }
            }
        }
        .fixedSize()
    }

    /// A small caption followed by its control(s), in one glass capsule.
    private func group<C: View>(_ title: String, _ label: Bool, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) {
            if label {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 6)
            }
            content()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .glassCapsule()
    }

    /// Narrowest variant: everything in one menu.
    private var menu: some View {
        Menu {
            Picker("Show", selection: modeBinding) {
                ForEach(FileViewMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Stacks", selection: stackBinding) {
                ForEach(StackChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            if showsRawLook {
                Picker("RAW Look", selection: rawBinding) {
                    Text("True RAW").tag(RawRendering.rendered)
                    Text("Camera Preview").tag(RawRendering.embedded)
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label(session.fileView.segmentTitle, systemImage: "square.stack.3d.down.right")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassCapsule()
        .fixedSize()
    }
}

/// Strict ↔ loose slider for similarity stacks; regrouping is instant (distances are cached).
struct SimilarityControl: View {
    @Environment(AppModel.self) private var app
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .buttonStyle(.borderless)
        .help("How similar photos must be to stack (⌥[ stricter · ⌥] looser)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Similar-photo stacks").font(.headline)
                HStack {
                    Text("Strict").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { app.settings.similarityThreshold }, set: { app.setSimilarityThreshold($0) }), in: 0.15...0.9)
                        .frame(width: 200)
                    Text("Loose").font(.caption).foregroundStyle(.secondary)
                }
                if let s = app.session {
                    Text("\(s.stackMembers.count) stacks · \(s.stackMembers.values.reduce(0) { $0 + $1.count }) photos grouped")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text("Strict keeps only near-identical frames together; loose also joins different angles of the same scene. Photos more than 10 minutes apart or from different cameras never stack.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }
}
