import SwiftUI
import CullerKit

/// Rename with token templates and a mandatory old → new preview (spec §8.1).
struct RenameSheet: View {
    @Bindable var session: FolderSession
    @Environment(\.dismiss) private var dismiss
    @State private var scope: FolderSession.OperationScope = .selected
    @State private var templateText = "{date:yyyyMMdd}_{seq:4}_{original}"
    @State private var sequenceStart = 1
    @State private var plans: [ItemPlan] = []
    @State private var parseError: String?
    @State private var error: String?
    @State private var running = false
    @State private var newPresetName = ""
    @State private var showSavePreset = false

    private var settings: AppSettings { session.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Photos").font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Apply to")
                    Picker("", selection: $scope) {
                        ForEach(FolderSession.OperationScope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }
                GridRow {
                    Text("Preset")
                    HStack {
                        Menu("Choose…") {
                            ForEach(settings.renamePresets) { p in
                                Button(p.name) {
                                    templateText = p.template
                                    sequenceStart = p.sequenceStart
                                }
                            }
                        }
                        .fixedSize()
                        Button("Save as Preset…") { showSavePreset = true }
                    }
                }
                GridRow {
                    Text("Template")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Template", text: $templateText)
                            .font(.body.monospaced())
                            .frame(minWidth: 420)
                        HStack(spacing: 4) {
                            ForEach(RenameTemplate.availableTokens, id: \.self) { t in
                                Button(t) { templateText += t }
                                    .font(.caption.monospaced())
                                    .controlSize(.small)
                            }
                        }
                        if let parseError {
                            Text(parseError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                GridRow {
                    Text("Sequence start")
                    Stepper(value: $sequenceStart, in: 0...999_999) {
                        TextField("", value: $sequenceStart, format: .number).frame(width: 80)
                    }
                }
            }

            let collisions = plans.filter(\.hadCollision).count
            HStack {
                Text("Preview — \(plans.count) photo\(plans.count == 1 ? "" : "s")").font(.headline)
                if collisions > 0 {
                    Label("\(collisions) name collision\(collisions == 1 ? "" : "s") resolved with a suffix", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Table(previewRows) {
                TableColumn("Current name") { r in Text(r.old).font(.body.monospaced()) }
                TableColumn("") { _ in Image(systemName: "arrow.right").foregroundStyle(.secondary) }.width(20)
                TableColumn("New name") { r in
                    Text(r.new).font(.body.monospaced())
                        .foregroundStyle(r.collision ? .orange : (r.unchanged ? .secondary : .primary))
                }
            }
            .frame(minHeight: 260)
            Text("All files of a photo (RAW, paired JPEG, .xmp sidecar) are renamed together. Extensions keep their case.")
                .font(.caption).foregroundStyle(.secondary)

            if let error { Text(error).foregroundStyle(.red).font(.callout) }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(running ? "Renaming…" : "Rename \(plans.filter { !$0.isNoOp }.count)") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(running || parseError != nil || plans.allSatisfy(\.isNoOp))
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 600)
        .onAppear {
            if let first = settings.renamePresets.first { templateText = first.template; sequenceStart = first.sequenceStart }
            if session.selection.count <= 1 && session.viewMode == .grid && session.display.count > 1 { scope = .selected }
            recompute()
        }
        .onChange(of: templateText) { recompute() }
        .onChange(of: sequenceStart) { recompute() }
        .onChange(of: scope) { recompute() }
        .alert("Save Preset", isPresented: $showSavePreset) {
            TextField("Name", text: $newPresetName)
            Button("Save") {
                let name = newPresetName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                settings.renamePresets.removeAll { $0.name == name }
                settings.renamePresets.insert(RenamePreset(name: name, template: templateText, sequenceStart: sequenceStart), at: 0)
                newPresetName = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private struct Row: Identifiable {
        var id: String
        var old: String
        var new: String
        var collision: Bool
        var unchanged: Bool
    }

    /// One row per file, so the sidecar and the pair partner are visible too.
    private var previewRows: [Row] {
        plans.flatMap { p in
            p.moves.map { m in
                Row(id: m.from.path, old: m.from.lastPathComponent, new: m.to.lastPathComponent,
                    collision: p.hadCollision, unchanged: m.from == m.to)
            }
        }
    }

    private func recompute() {
        do {
            let t = try RenameTemplate(templateText)
            parseError = nil
            plans = session.planRename(session.items(in: scope), template: t, sequenceStart: sequenceStart)
        } catch {
            parseError = error.localizedDescription
            plans = []
        }
    }

    private func run() {
        running = true
        error = nil
        let p = plans
        Task {
            let err = await session.executeRename(p)
            running = false
            if let err { error = err } else { dismiss() }
        }
    }
}
