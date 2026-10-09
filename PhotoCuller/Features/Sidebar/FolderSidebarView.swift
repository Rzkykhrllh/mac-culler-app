import SwiftUI
import CullerKit

/// Finder-like folder browser: Favorites, pinned folders and Locations; every folder expands lazily.
/// Click opens in the current tab, ⌘-click (or the context menu) in a new tab.
struct FolderSidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let sidebar = app.sidebar
        // No List selection: its system-blue highlight followed clicks on its own and could sit on a different row
        // than the folder actually open. The open folder is marked by the row itself (accent pill), once.
        List {
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
        .frame(minWidth: 180, idealWidth: 220)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
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
            Text(node.name)
                .lineLimit(1)
                .fontWeight(isOpen ? .semibold : .regular)
            Spacer(minLength: 4)
            if node.needsAccess {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                    .help("Click to give \(AppConstants.appName) access to this folder (once)")
            } else if let n = node.photoCount, n > 0 {
                Text("\(n)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isOpen ? .primary : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(isOpen ? Theme.accentStart.opacity(0.28) : Color.white.opacity(0.08), in: Capsule())
            }
        }
        // Room on both ends, so the count never touches the highlight's edge.
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background {
            if isOpen {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.accentStart.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.accentStart.opacity(0.25)))
            }
        }
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
