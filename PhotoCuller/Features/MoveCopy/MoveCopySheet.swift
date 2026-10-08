import SwiftUI
import CullerKit

/// Move / copy dialog (spec §8.2). Collisions get a suffix and are listed before running.
struct MoveCopySheet: View {
    @Bindable var session: FolderSession
    @State var mode: TransferMode
    @Environment(\.dismiss) private var dismiss
    @State private var scope: FolderSession.OperationScope = .selected
    @State private var destination: URL?
    @State private var destinationScoped = false
    @State private var plans: [ItemPlan] = []
    @State private var running = false
    @State private var result: FileOperations.TransferResult?

    private var app: AppModel { session.app }

    /// Items in scope (independent of the destination, so counts show right away).
    private var scopeItems: [PhotoItem] { session.items(in: scope) }

    var body: some View {
        let items = scopeItems
        let fileCount = items.reduce(0) { $0 + $1.files.allURLs.count }
        let collisions = plans.filter(\.hadCollision)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: mode == .move ? "folder.badge.gearshape" : "doc.on.doc")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .glass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode == .move ? "Move Photos" : "Copy Photos").font(.title3.bold())
                    Text("\(items.count) photo\(items.count == 1 ? "" : "s") · \(fileCount) file\(fileCount == 1 ? "" : "s") — RAW, paired JPEG and sidecars stay together")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Action").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Picker("", selection: $mode) {
                        Text("Move").tag(TransferMode.move)
                        Text("Copy").tag(TransferMode.copy)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Apply to").foregroundStyle(.secondary)
                    Picker("", selection: $scope) {
                        ForEach(FolderSession.OperationScope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Destination").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill").foregroundStyle(destination == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.accent))
                            Text(destination.map { $0.path.replacingOccurrences(of: AccessGrants.realHome.path, with: "~") } ?? "No folder chosen")
                                .foregroundStyle(destination == nil ? .secondary : .primary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(minWidth: 280)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Menu {
                            ForEach(app.recentDestinations.entries) { e in
                                Button(e.path) { useRecent(e) }
                            }
                            if app.recentDestinations.entries.isEmpty { Text("No recent destinations") }
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Recent destinations")
                        Button("Choose…") { choose() }
                    }
                    .disabled(running)
                }
            }
            .disabled(running)

            VStack(alignment: .leading, spacing: 6) {
                if mode == .move {
                    Label("Moving to another disk copies, verifies (size + checksum) and only then removes the originals.", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Originals stay where they are.", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if destination != nil, plans.count < items.count {
                    Label("\(items.count - plans.count) photo\(items.count - plans.count == 1 ? " is" : "s are") already in that folder and will be skipped.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !collisions.isEmpty {
                    Label("\(collisions.count) name collision\(collisions.count == 1 ? "" : "s") at the destination — renamed with a suffix:", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(collisions) { p in
                                Text("\(p.oldBaseName) → \(p.newBaseName)").font(.caption.monospaced())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let p = session.fileOperation {
                HStack {
                    ProgressView(value: Double(p.done), total: Double(max(1, p.total)))
                    Text("\(p.done)/\(p.total)").font(.caption.monospacedDigit())
                    Button("Stop") { session.cancelFileOperation() }
                }
            }

            if let r = result {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(r.completed.count) of \(plans.count) done" + (r.cancelled ? " — stopped (finished photos stay done)" : ""),
                          systemImage: r.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.failed.isEmpty ? .green : .orange)
                    ForEach(r.failed, id: \.itemID) { f in
                        Text("\((f.itemID as NSString).lastPathComponent): \(f.error)").font(.caption).foregroundStyle(.red)
                    }
                }
            }

            HStack {
                Spacer()
                if result != nil {
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction).disabled(running)
                    Button(mode == .move ? "Move \(plans.count)" : "Copy \(plans.count)") { run() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(running || destination == nil || plans.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 600)
        .onAppear { recompute() }
        .onChange(of: scope) { recompute() }
        .onChange(of: destination) { recompute() }
    }

    private func recompute() {
        guard let destination else { plans = []; return }
        let items = session.items(in: scope)
        plans = FileOperations.planTransfer(items.map { ($0.id, $0.files) }, to: destination)
            .filter { p in !p.moves.allSatisfy { $0.from.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL } }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = mode == .move ? "Choose where to move the photos" : "Choose where to copy the photos"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        releaseDestination()
        app.recentDestinations.add(url)
        destination = url
    }

    private func useRecent(_ e: RecentFolders.Entry) {
        guard let url = app.recentDestinations.resolve(e) else {
            app.alert = AppAlert(title: "Destination unavailable", message: "“\(e.name)” can no longer be accessed. Please choose it again.")
            return
        }
        releaseDestination()
        destinationScoped = url.startAccessingSecurityScopedResource()
        destination = url
    }

    private func releaseDestination() {
        if destinationScoped, let destination { destination.stopAccessingSecurityScopedResource() }
        destinationScoped = false
    }

    private func run() {
        guard let destination else { return }
        running = true
        let p = plans, m = mode
        Task {
            result = await session.executeTransfer(p, mode: m, destination: destination)
            running = false
        }
    }

    private func close() {
        releaseDestination()
        dismiss()
    }
}
