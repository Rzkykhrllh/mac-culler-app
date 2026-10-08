import SwiftUI
import CullerKit

/// Finder-like folder browser: Favorites, pinned folders and Locations; every folder expands lazily.
/// Click opens in the current tab, ⌘-click (or the context menu) in a new tab.
struct FolderSidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let sidebar = app.sidebar
        List(selection: Binding(get: { sidebar.selectedURL }, set: { _ in })) {
            if !sidebar.pinned.isEmpty {
                Section("Pinned") {
                    ForEach(sidebar.pinned) { FolderRow(node: $0, isRoot: true) }
                }
            }
            Section("Favorites") {
                ForEach(sidebar.favorites) { FolderRow(node: $0, isRoot: true) }
            }
            Section {
                ForEach(sidebar.locations) { FolderRow(node: $0, isRoot: true) }
            } header: {
                HStack {
                    Text("Locations")
                    Spacer()
                    Button { app.showOpenPanel() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Open / grant access to another folder… (⇧⌘O)")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 420)
    }
}

private struct FolderRow: View {
    @Environment(AppModel.self) private var app
    let node: FolderNode
    var isRoot = false

    var body: some View {
        Group {
            if node.hasChildren {
                DisclosureGroup(isExpanded: Binding(get: { node.isExpanded }, set: { expand in
                    if expand && node.needsAccess {
                        Task { await app.sidebar.requestAccess(node) }
                    } else {
                        node.isExpanded = expand
                    }
                })) {
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
        let isOpen = app.sidebar.selectedURL == node.url
        return HStack(spacing: 6) {
            Image(systemName: isOpen && node.symbol == "folder" ? "folder.fill" : node.symbol)
                .foregroundStyle(isOpen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            Text(node.name).lineLimit(1)
            Spacer(minLength: 4)
            if node.needsAccess {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                    .help("Click to give \(AppConstants.appName) access to this folder (once)")
            } else if let n = node.photoCount, n > 0 {
                Text("\(n)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
        }
        .tag(node.url)
        .contentShape(Rectangle())
        .onTapGesture { open(newTab: NSEvent.modifierFlags.contains(.command)) }
        .help(node.url.path)
        .contextMenu {
            Button("Open") { open(newTab: false) }
            Button("Open in New Tab") { open(newTab: true) }
            Button("Open with Subfolders") {
                if app.sidebar.ensureAccess(node.url) { app.open(folder: node.url, includeSubfolders: true) }
            }
            Divider()
            if app.sidebar.isPinned(node.url) {
                Button("Unpin") { app.sidebar.unpin(node) }
            } else {
                Button("Pin to Sidebar") { app.sidebar.pin(node.url) }
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Button("Refresh") { Task { await node.load(force: true) } }
        }
    }

    private func open(newTab: Bool) {
        Task {
            if node.needsAccess {
                guard await app.sidebar.requestAccess(node) else { return }
            }
            app.openFromSidebar(node.url, newTab: newTab)
        }
    }
}
