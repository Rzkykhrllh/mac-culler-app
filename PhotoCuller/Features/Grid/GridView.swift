import SwiftUI
import CullerKit

struct GridView: View {
    @Bindable var session: FolderSession

    var body: some View {
        ThumbnailCollection(
            session: session,
            entries: session.display,
            revision: session.displayRevision,
            currentID: session.currentID,
            selection: session.selection,
            style: .grid(cellSize: session.settings.thumbnailSize),
            allowsMultipleSelection: true,
            onSelectionChange: { sel, clicked in
                session.selection = sel
                if let clicked {
                    session.currentID = clicked
                    if sel.count == 1 { session.selectionAnchor = clicked }
                } else if let cur = session.currentID, !sel.contains(cur), let first = sel.first {
                    session.currentID = first
                }
            },
            onActivate: { id in
                session.select(id)
                session.viewMode = .loupe
            },
            onToggleStack: { session.toggleStack($0) },
            contextMenu: { PhotoContextMenu.make(session) },
            onQuickMark: { id, cmd in session.apply(cmd, toItem: id) },
            onRangeClick: { id, adding in session.selectRange(to: id, adding: adding) }
        )
        .overlay {
            if session.display.isEmpty && session.phase == .ready {
                ContentUnavailableView(session.items.isEmpty ? "No Photos" : "No Matches",
                                       systemImage: session.items.isEmpty ? "photo.on.rectangle.angled" : "line.3.horizontal.decrease.circle",
                                       description: Text(session.items.isEmpty ? "This folder contains no supported images." : "No photos match the current filters."))
            }
        }
    }
}

/// Horizontal filmstrip of the current display list (loupe) or compare candidates.
struct FilmstripView: View {
    let session: FolderSession
    var entries: [DisplayEntry]
    var revision: Int
    var currentID: ItemID?
    var highlighted: Set<ItemID>
    var compareSlots: [ItemID?] = []
    var onPick: (ItemID) -> Void

    var body: some View {
        ThumbnailCollection(
            session: session, entries: entries, revision: revision, currentID: currentID,
            selection: highlighted, compareSlots: compareSlots, style: .strip(height: 96), allowsMultipleSelection: false,
            onSelectionChange: { _, clicked in if let clicked { onPick(clicked) } },
            onActivate: { onPick($0) },
            onToggleStack: { session.toggleStack($0) },
            contextMenu: { PhotoContextMenu.make(session) }
        )
        .frame(height: 96)
    }
}
