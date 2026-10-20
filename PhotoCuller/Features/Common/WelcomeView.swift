import SwiftUI
import CullerKit

struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var dropTargeted = false
    @State private var showAllRecents = false

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                header
                recents
                features
                footer
            }
            .padding(.vertical, 36)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .background(dropTargeted ? Theme.accentStart.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            app.recentFolders.add(url)
            app.sidebar.adopt(url)
            app.open(folder: url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: Theme.accentEnd.opacity(0.35), radius: 30)
            Text(AppConstants.appName)
                .font(.system(size: 40, weight: .bold, design: .rounded))
            Text("Pick the keepers from every shoot — fast, right from the keyboard.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                app.showOpenPanel()
            } label: {
                Label("Open Folder…", systemImage: "folder").padding(.horizontal, 8)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o")
            .padding(.top, 6)
        }
    }

    @ViewBuilder private var recents: some View {
        let all = app.recentFolders.entries
        if !all.isEmpty {
            let shown = showAllRecents ? all : Array(all.prefix(5))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Recent").font(.headline)
                    Spacer()
                    if all.count > 5 {
                        Button(showAllRecents ? "Show less" : "Show all \(all.count)") { withAnimation { showAllRecents.toggle() } }
                            .buttonStyle(.borderless)
                            .font(.callout)
                    }
                }
                .padding(.bottom, 4)
                ForEach(shown) { e in
                    Button { app.open(recent: e) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill").foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.name)
                                Text(e.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(e.path)
                }
            }
            .frame(maxWidth: 520)
            .padding(16)
            .glassCard(18)
        }
    }

    private var features: some View {
        let k: (String) -> String = { KeyMap.label($0) }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 12)], spacing: 12) {
            TipCard(symbol: "flag.fill", title: "Mark fast",
                    text: "\(k("mark.pick")) pick · \(k("mark.reject")) reject · \(k("rating.1"))–\(k("rating.5")) stars. Hold ⇧ to mark and move on.")
            TipCard(symbol: "rectangle.split.2x1", title: "Find the keeper",
                    text: "Similar shots stack together. \(k("view.compare")) compares them side by side, \(k("focus.peaking")) shows what is sharp.")
            TipCard(symbol: "crop", title: "Crop & export",
                    text: "\(k("edit.crop")) crops (4:5 for Instagram). ⇧⌘E exports with a white border or an Instagram canvas.")
            TipCard(symbol: "square.and.arrow.up", title: "Send it on",
                    text: "⌃⌘L imports into Lightroom. Share, ⌘C to paste anywhere, or move rejects to the Trash.")
        }
        .frame(maxWidth: 980)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { app.showGuide = true } label: { Label("Getting started", systemImage: "book") }
                .buttonStyle(.borderless)
                .help("A short tour of folders, RAW+JPG, marking, stacks, compare and focus tools")
            Text("Drop a folder anywhere here · press ? for every shortcut")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

private struct TipCard: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(Theme.accent)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .glassCard(16)
    }
}
