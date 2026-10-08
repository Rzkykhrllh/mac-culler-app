import AppKit
import SwiftUI
import CullerKit

/// Virtualized `NSCollectionView` used for the grid and the filmstrips (spec §6.1, §10).
struct ThumbnailCollection: NSViewRepresentable {
    enum Style: Equatable {
        case grid(cellSize: CGFloat)
        case strip(height: CGFloat)

        var isStrip: Bool { if case .strip = self { return true } else { return false } }
    }

    let session: FolderSession
    var entries: [DisplayEntry]
    /// Changes whenever `entries` must be reloaded.
    var revision: Int
    var currentID: ItemID?
    var selection: Set<ItemID>
    var compareSlots: [ItemID?] = []
    var style: Style
    var allowsMultipleSelection: Bool
    var onSelectionChange: (_ selection: Set<ItemID>, _ clicked: ItemID?) -> Void
    var onActivate: (ItemID) -> Void
    var onToggleStack: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        if style.isStrip { layout.scrollDirection = .horizontal }

        let cv = KeyPassingCollectionView()
        cv.collectionViewLayout = layout
        cv.isSelectable = true
        cv.allowsMultipleSelection = allowsMultipleSelection
        cv.allowsEmptySelection = true
        cv.backgroundColors = [NSColor(white: 0.11, alpha: 1)]
        cv.register(ThumbnailCell.self, forItemWithIdentifier: ThumbnailCell.identifier)
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.prefetchDataSource = context.coordinator

        let sv = NSScrollView()
        sv.documentView = cv
        sv.hasVerticalScroller = !style.isStrip
        sv.hasHorizontalScroller = style.isStrip
        sv.autohidesScrollers = true
        sv.drawsBackground = true
        sv.backgroundColor = NSColor(white: 0.11, alpha: 1)
        context.coordinator.collectionView = cv
        context.coordinator.apply(self, force: true)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.apply(self, force: false)
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewPrefetching, NSCollectionViewDelegateFlowLayout {
        var parent: ThumbnailCollection
        weak var collectionView: NSCollectionView?
        private var entries: [DisplayEntry] = []
        private var revision = -1
        private var style: Style?
        private var lastCurrent: ItemID?
        private var syncing = false
        private var prefetchTasks: [IndexPath: Task<Void, Never>] = [:]

        init(_ p: ThumbnailCollection) { parent = p }

        func apply(_ p: ThumbnailCollection, force: Bool) {
            parent = p
            guard let cv = collectionView else { return }
            if force || p.revision != revision {
                revision = p.revision
                entries = p.entries
                cv.reloadData()
            }
            if p.style != style {
                style = p.style
                cv.collectionViewLayout?.invalidateLayout()
            }
            cv.allowsMultipleSelection = p.allowsMultipleSelection
            syncSelection(cv)
            refreshVisibleState(cv)
            if p.currentID != lastCurrent || force {
                lastCurrent = p.currentID
                scrollToCurrent(cv)
            }
            updateColumns(cv)
        }

        private func indexPath(of id: ItemID) -> IndexPath? {
            if !parent.style.isStrip, let i = parent.session.displayIndex[id], entries.indices.contains(i), entries[i].itemID == id {
                return IndexPath(item: i, section: 0)
            }
            return entries.firstIndex { $0.itemID == id }.map { IndexPath(item: $0, section: 0) }
        }

        private func syncSelection(_ cv: NSCollectionView) {
            let wanted = Set(parent.selection.compactMap(indexPath(of:)))
            guard wanted != cv.selectionIndexPaths else { return }
            syncing = true
            cv.selectionIndexPaths = wanted
            syncing = false
        }

        private func refreshVisibleState(_ cv: NSCollectionView) {
            for case let cell as ThumbnailCell in cv.visibleItems() {
                guard let id = cell.representedID else { continue }
                cell.cellView.isCurrent = id == parent.currentID
                cell.cellView.compareSlot = parent.compareSlots.firstIndex(of: id)
            }
        }

        private func scrollToCurrent(_ cv: NSCollectionView) {
            guard let id = parent.currentID, let ip = indexPath(of: id) else { return }
            let pos: NSCollectionView.ScrollPosition = parent.style.isStrip ? .centeredHorizontally : .nearestHorizontalEdge
            if parent.style.isStrip {
                cv.animator().scrollToItems(at: [ip], scrollPosition: pos)
            } else if let frame = cv.layoutAttributesForItem(at: ip)?.frame, !cv.visibleRect.contains(frame) {
                cv.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
            }
        }

        private func updateColumns(_ cv: NSCollectionView) {
            guard case .grid(let size) = parent.style else { return }
            let w = cv.enclosingScrollView?.contentSize.width ?? cv.bounds.width
            parent.session.gridColumns = max(1, Int((w - 16 + 2) / (size + 2)))
        }

        // MARK: Data source

        func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { entries.count }

        func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
            let cell = cv.makeItem(withIdentifier: ThumbnailCell.identifier, for: ip) as! ThumbnailCell
            let entry = entries[ip.item]
            if let item = parent.session.items[entry.itemID] {
                cell.configure(entry: entry, item: item, pipeline: parent.session.app.pipeline, compact: parent.style.isStrip,
                               isCurrent: entry.itemID == parent.currentID, compareSlot: parent.compareSlots.firstIndex(of: entry.itemID))
            }
            let id = entry.itemID
            cell.cellView.onDoubleClick = { [weak self] in self?.parent.onActivate(id) }
            cell.cellView.onStackBadge = { [weak self] in
                if let sid = entry.stackID { self?.parent.onToggleStack(sid) }
            }
            return cell
        }

        // MARK: Layout

        func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout, sizeForItemAt ip: IndexPath) -> NSSize {
            switch parent.style {
            case .grid(let s): return NSSize(width: s, height: s)
            case .strip(let h):
                let inner = h - 16
                return NSSize(width: inner * 1.25, height: inner)
            }
        }

        // MARK: Selection

        func collectionView(_ cv: NSCollectionView, didSelectItemsAt ips: Set<IndexPath>) {
            guard !syncing else { return }
            let clicked = ips.sorted().last.map { entries[$0.item].itemID }
            report(cv, clicked: clicked)
        }

        func collectionView(_ cv: NSCollectionView, didDeselectItemsAt ips: Set<IndexPath>) {
            guard !syncing else { return }
            report(cv, clicked: nil)
        }

        private func report(_ cv: NSCollectionView, clicked: ItemID?) {
            let sel = Set(cv.selectionIndexPaths.compactMap { entries.indices.contains($0.item) ? entries[$0.item].itemID : nil })
            parent.onSelectionChange(sel, clicked)
        }

        // MARK: Prefetch

        func collectionView(_ cv: NSCollectionView, prefetchItemsAt ips: [IndexPath]) {
            let pipeline = parent.session.app.pipeline
            for ip in ips where entries.indices.contains(ip.item) {
                guard let item = parent.session.items[entries[ip.item].itemID] else { continue }
                let f = item.files.primary
                guard pipeline.cachedThumbnail(f) == nil else { continue }
                prefetchTasks[ip]?.cancel()
                prefetchTasks[ip] = Task { _ = await pipeline.thumbnail(f, priority: .low) }
            }
        }

        func collectionView(_ cv: NSCollectionView, cancelPrefetchingForItemsAt ips: [IndexPath]) {
            for ip in ips {
                // Cancels only the prefetch's own request; a visible cell waiting on the same thumbnail keeps it.
                prefetchTasks.removeValue(forKey: ip)?.cancel()
            }
        }
    }
}

/// Lets single-key shortcuts reach the app's key handler instead of being swallowed as type-select.
final class KeyPassingCollectionView: NSCollectionView {
    override func keyDown(with event: NSEvent) {
        // Arrow keys / letters are handled by KeyboardController before reaching here; anything else goes up.
        nextResponder?.keyDown(with: event)
    }
}
