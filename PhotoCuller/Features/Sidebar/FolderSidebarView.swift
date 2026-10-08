import SwiftUI
import CullerKit

/// Folder tree: click any folder or subfolder to open it (no Open dialog needed once a root is added).
struct FolderSidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let sidebar = app.sidebar
        List(selection: Binding(get: { sidebar.selectedURL }, set: { url in
            guard let url else { return }
            sidebar.selectedURL = url
            app.openFromSidebar(url)
        })) {
            Section {
                if sidebar.roots.isEmpty {
                    Button {
                        app.showOpenPanel()
                    } label: {
                        Label("Add a folder…", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                ForEach(sidebar.roots) { root in
                    FolderRow(node: root, isRoot: true)
                }
            } header: {
                HStack {
                    Text("Folders")
                    Spacer()
                    Button { app.showOpenPanel() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add Folder to Sidebar… (⇧⌘O)")
                }
            }

            let recents = app.recentFolders.entries.filter { sidebar.root(containing: URL(fileURLWithPath: $0.path)) == nil }.prefix(5)
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(Array(recents)) { e in
                        Label(e.name, systemImage: "clock")
                            .lineLimit(1)
                            .contentShape(Rectangle())
                            .onTapGesture { app.open(recent: e) }
                            .help(e.path)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
    }
}

private struct FolderRow: View {
    @Environment(AppModel.self) private var app
    let node: FolderNode
    var isRoot = false

    var body: some View {
        Group {
            if node.hasChildren {
                DisclosureGroup(isExpanded: Binding(get: { node.isExpanded }, set: { node.isExpanded = $0 })) {
                    ForEach(node.children ?? []) { FolderRow(node: $0) }
                } label: {
                    label
                }
            } else {
                label
            }
        }
        .task(id: node.isExpanded) {
            await node.load()
            if node.isExpanded { for c in node.children ?? [] { await c.load() } }
        }
    }

    private var label: some View {
        let isOpen = app.session?.folder.standardizedFileURL == node.url
        return HStack(spacing: 6) {
            Image(systemName: isRoot ? "externaldrive.fill" : (isOpen ? "folder.fill" : "folder"))
                .foregroundStyle(isOpen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            Text(node.name).lineLimit(1)
            Spacer(minLength: 4)
            if let n = node.photoCount, n > 0 {
                Text("\(n)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
        }
        .tag(node.url)
        .help(node.url.path)
        .contextMenu {
            Button("Open") { app.openFromSidebar(node.url) }
            Button("Open with Subfolders") { app.open(folder: node.url, securityScoped: false, includeSubfolders: true) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Button("Refresh") { Task { await node.load(force: true) } }
            if isRoot {
                Divider()
                Button("Remove from Sidebar") { app.sidebar.remove(node) }
            }
        }
    }
}
