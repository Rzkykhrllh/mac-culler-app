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
            Text("or drop a folder here").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            app.recentFolders.add(url)
            app.sidebar.add(url)
            app.open(folder: url, securityScoped: false)
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}
