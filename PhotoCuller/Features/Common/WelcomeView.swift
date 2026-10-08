import SwiftUI
import CullerKit

struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(Theme.accent)
                .padding(26)
                .glass(in: Circle())
                .shadow(color: Theme.accentEnd.opacity(0.35), radius: 40)
            VStack(spacing: 6) {
                Text(AppConstants.appName).font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                Text("Open a folder, mark fast with the keyboard, keep the best frame of every burst.")
                    .foregroundStyle(.secondary)
            }
            Button {
                app.showOpenPanel()
            } label: {
                Label("Open Folder…", systemImage: "folder").padding(.horizontal, 8)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("o")

            let recents = app.recentFolders.entries
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent").font(.headline).padding(.bottom, 2)
                    ForEach(recents) { e in
                        Button {
                            app.open(recent: e)
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                VStack(alignment: .leading) {
                                    Text(e.name)
                                    Text(e.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                }
                .frame(width: 420)
                .padding(16)
                .glassCard(18)
            }
            HStack(spacing: 12) {
                TipCard(symbol: "flag.fill", title: "Mark fast", text: "P pick · X reject · 1–5 stars · 6–9 labels. Hold ⇧ to jump to the next photo.")
                TipCard(symbol: "rectangle.split.2x1", title: "Pick the keeper", text: "C compares a burst; drag photos from the filmstrip onto a side. B finds the sharpest.")
                TipCard(symbol: "scope", title: "Check focus", text: "F focus peaking · J clipping · Y zooms to the eyes or animal at 100%.")
            }
            .frame(maxWidth: 760)
            Text("Drop a folder here · press ? anytime for all shortcuts").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            app.recentFolders.add(url)
            app.sidebar.adopt(url)
            app.open(folder: url)
            return true
        } isTargeted: { dropTargeted = $0 }
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
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .glassCard(16)
    }
}
