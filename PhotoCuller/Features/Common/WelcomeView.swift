import SwiftUI
import CullerKit

struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text(AppConstants.appName).font(.largeTitle.bold())
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
                .padding()
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("or drop a folder here").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            app.recentFolders.add(url)
            app.open(folder: url, securityScoped: false)
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}
