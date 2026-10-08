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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .move ? "Move Photos" : "Copy Photos").font(.title2.bold())

            Picker("", selection: $mode) {
                Text("Move").tag(TransferMode.move)
                Text("Copy").tag(TransferMode.copy)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .disabled(running)

            Picker("Apply to", selection: $scope) {
                ForEach(FolderSession.OperationScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 380)
            .disabled(running)

            HStack {
                Text("Destination:")
                Text(destination?.path ?? "None chosen").foregroundStyle(destination == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Menu("Recent") {
                    ForEach(app.recentDestinations.entries) { e in
                        Button(e.path) { useRecent(e) }
                    }
                    if app.recentDestinations.entries.isEmpty { Text("No recent destinations") }
                }
                .fixedSize()
                .disabled(running)
                Button("Choose…") { choose() }.disabled(running)
            }

            let collisions = plans.filter(\.hadCollision)
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(plans.count) photo\(plans.count == 1 ? "" : "s"), \(plans.reduce(0) { $0 + $1.moves.count }) files (RAW, paired files and sidecars move together).")
                    if mode == .move {
                        Text("Moves to another disk copy, verify (size + checksum) and only then delete the originals.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !collisions.isEmpty {
                        Label("\(collisions.count) name collision\(collisions.count == 1 ? "" : "s") at the destination — will be renamed:", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        ScrollView {
                            VStack(alignment: .leading) {
                                ForEach(collisions) { p in
                                    Text("\(p.oldBaseName) → \(p.newBaseName)").font(.caption.monospaced())
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let p = session.fileOperation {
                HStack {
                    ProgressView(value: Double(p.done), total: Double(max(1, p.total)))
                    Text("\(p.done)/\(p.total)").font(.caption.monospacedDigit())
                    Button("Cancel") { session.cancelFileOperation() }
                }
            }

            if let r = result {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(r.completed.count) completed" + (r.cancelled ? " — cancelled (completed items stay done)" : ""))
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
                    Button(mode == .move ? "Move" : "Copy") { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(running || destination == nil || plans.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 620)
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
