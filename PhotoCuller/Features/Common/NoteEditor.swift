import SwiftUI

/// Inline note editor (M). Esc cancels, ⌘Return saves (spec §9).
struct NoteEditor: View {
    let session: FolderSession
    let itemID: ItemID
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "text.bubble")
                Text("Note — \(session.items[itemID]?.fileName ?? "")").font(.headline)
            }
            TextEditor(text: $text)
                .font(.body)
                .focused($focused)
                .frame(width: 380, height: 110)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Text("Esc to cancel · ⌘↩ to save").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { session.editingNote = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { session.commitNote(text) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .onAppear {
            text = session.items[itemID]?.metadata.note ?? ""
            focused = true
        }
    }
}
