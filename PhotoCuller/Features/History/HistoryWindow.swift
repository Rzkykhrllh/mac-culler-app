import SwiftUI
import CullerKit

/// Operation History (spec §8.4): file operations from the persistent log, undoable after a relaunch.
struct HistoryWindow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let _ = app.historyRevision
        let records = app.operationLog.all.reversed()
        Group {
            if records.isEmpty {
                ContentUnavailableView("No File Operations", systemImage: "clock.arrow.circlepath",
                                       description: Text("Renames, moves and copies appear here and can be undone, even after relaunching."))
            } else {
                List(Array(records)) { r in
                    HStack(alignment: .top) {
                        Image(systemName: icon(r.kind)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.summary).fontWeight(.medium).strikethrough(r.undone)
                            Text(r.date.formatted(date: .abbreviated, time: .standard) + " · \(r.entries.count) files")
                                .font(.caption).foregroundStyle(.secondary)
                            if let first = r.entries.first {
                                Text("\((first.from as NSString).lastPathComponent) → \((first.to as NSString).lastPathComponent)\(r.entries.count > 1 ? " …" : "")")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if r.undone {
                            Text("Undone").font(.caption).foregroundStyle(.secondary)
                            Button("Redo") { perform(r, undo: false) }
                        } else {
                            Button("Undo") { perform(r, undo: true) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 320)
    }

    private func icon(_ k: OperationRecord.Kind) -> String {
        switch k {
        case .rename: return "pencil"
        case .move: return "folder"
        case .copy: return "doc.on.doc"
        case .trash: return "trash"
        }
    }

    private func perform(_ r: OperationRecord, undo: Bool) {
        Task {
            await app.writeQueue.flush()
            FolderSession.perform(r, undo: undo, log: app.operationLog) {
                app.historyChanged()
                app.session?.scheduleRefresh(delay: .milliseconds(200))
            }
        }
    }
}
