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
            Spacer(minLength: 8)
            FileViewSwitcher(session: session)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
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

/// Always-visible RAW / JPEG mode switch (+ RAW look when RAW files are shown on their own).
struct FileViewSwitcher: View {
    @Environment(AppModel.self) private var app
    let session: FolderSession

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { session.fileView }, set: { session.setFileView($0) })) {
                ForEach(FileViewMode.allCases) { m in
                    Text(m.segmentTitle).tag(m).help("\(m.title) (⌥⌘\(String(m.shortcutKey)))")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("RAW + JPEG as one photo · separately · JPEG only · RAW only (⌥⌘1–4)")

            if session.fileView != .combined && session.fileView != .jpegOnly {
                Picker("", selection: Binding(get: { app.settings.rawRendering }, set: { app.setRawRendering($0) })) {
                    Text("True RAW").tag(RawRendering.rendered)
                    Text("Camera Preview").tag(RawRendering.embedded)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("True RAW: rendered from the sensor data, no film simulation. Camera Preview: the JPEG the camera embedded in the RAW (faster, camera look). (⌥⌘R)")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .glassCapsule()
    }
}
