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
    /// Right-click menu for the (already selected) items.
    var contextMenu: () -> NSMenu? = { nil }

    static let spacing: CGFloat = 4
    static let inset: CGFloat = 8

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Self.spacing
        layout.minimumLineSpacing = Self.spacing
        layout.sectionInset = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        if style.isStrip { layout.scrollDirection = .horizontal }

        let cv = KeyPassingCollectionView()
        cv.collectionViewLayout = layout
        // Filmstrips do their own click handling (click on mouse-up, drag to a compare slot).
        cv.isSelectable = !style.isStrip
        cv.allowsMultipleSelection = allowsMultipleSelection
        cv.allowsEmptySelection = true
        cv.backgroundColors = [.clear]
        cv.register(ThumbnailCell.self, forItemWithIdentifier: ThumbnailCell.identifier)
        cv.dataSource = context.coordinator
        cv.delegate = context.coordinator
        cv.prefetchDataSource = context.coordinator

        let sv = NSScrollView()
        sv.documentView = cv
        sv.hasVerticalScroller = !style.isStrip
        sv.hasHorizontalScroller = style.isStrip
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.contentView.postsFrameChangedNotifications = true
        context.coordinator.collectionView = cv
        context.coordinator.observeResize(sv)
        cv.onRightClick = { [weak coordinator = context.coordinator] ip in coordinator?.rightClicked(ip) }
        context.coordinator.apply(self, force: true)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.apply(self, force: false)
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSCollectionViewPrefetching {
        var parent: ThumbnailCollection
        weak var collectionView: KeyPassingCollectionView?
        private var entries: [DisplayEntry] = []
        private var revision = -1
        private var style: Style?
        private var lastCurrent: ItemID?
        private var lastWidth: CGFloat = 0
        private var syncing = false
        private var prefetchTasks: [IndexPath: Task<Void, Never>] = [:]

        init(_ p: ThumbnailCollection) { parent = p }

        func observeResize(_ sv: NSScrollView) {
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: sv.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateItemSize(force: false) }
            }
        }

        func apply(_ p: ThumbnailCollection, force: Bool) {
            parent = p
            guard let cv = collectionView else { return }
            cv.contextMenuProvider = p.contextMenu
            if force || p.revision != revision {
                revision = p.revision
                entries = p.entries
                cv.reloadData()
            }
            if p.style != style {
                style = p.style
                updateItemSize(force: true)
            }
            cv.allowsMultipleSelection = p.allowsMultipleSelection
            syncSelection(cv)
            refreshVisibleState(cv)
            if p.currentID != lastCurrent || force {
                lastCurrent = p.currentID
                scrollToCurrent(cv)
            }
        }

        /// Sets the layout's item size directly (all cells change together) and fits the columns to the width,
        /// so cells grow evenly instead of leaving wide gaps.
        func updateItemSize(force: Bool) {
            guard let cv = collectionView, let layout = cv.collectionViewLayout as? NSCollectionViewFlowLayout,
                  let sv = cv.enclosingScrollView else { return }
            let width = sv.contentSize.width
            guard force || abs(width - lastWidth) > 0.5 else { return }
            lastWidth = width
            let size: NSSize
            switch parent.style {
            case .grid(let target):
                let available = max(1, width - 2 * ThumbnailCollection.inset)
                let s = ThumbnailCollection.spacing
                let cols = max(1, Int((available + s) / (target + s)))
                let w = floor((available - CGFloat(cols - 1) * s) / CGFloat(cols))
                size = NSSize(width: w, height: w)
                parent.session.gridColumns = cols
            case .strip(let h):
                let inner = h - 2 * ThumbnailCollection.inset
                size = NSSize(width: floor(inner * 1.25), height: inner)
            }
            guard layout.itemSize != size else { return }
            layout.itemSize = size
            layout.invalidateLayout()
            for case let cell as ThumbnailCell in cv.visibleItems() { cell.view.needsDisplay = true }
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
                if parent.style.isStrip { cell.cellView.isSelectedCell = parent.selection.contains(id) }
            }
        }

        private func scrollToCurrent(_ cv: NSCollectionView) {
            guard let id = parent.currentID, let ip = indexPath(of: id) else { return }
            if parent.style.isStrip {
                cv.animator().scrollToItems(at: [ip], scrollPosition: .centeredHorizontally)
            } else if let frame = cv.layoutAttributesForItem(at: ip)?.frame, !cv.visibleRect.contains(frame) {
                cv.scrollToItems(at: [ip], scrollPosition: .nearestHorizontalEdge)
            }
        }

        /// Right-click on an unselected item selects it first (Finder behaviour).
        func rightClicked(_ ip: IndexPath?) {
            guard let cv = collectionView, let ip, entries.indices.contains(ip.item) else { return }
            if parent.style.isStrip {
                let id = entries[ip.item].itemID
                if !parent.selection.contains(id) { parent.onSelectionChange([id], id) }
                return
            }
            if !cv.selectionIndexPaths.contains(ip) {
                syncing = true
                cv.selectionIndexPaths = [ip]
                syncing = false
                report(cv, clicked: entries[ip.item].itemID)
            }
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
            cell.cellView.manualClicks = parent.style.isStrip
            if parent.style.isStrip {
                cell.cellView.isSelectedCell = parent.selection.contains(id)
                cell.cellView.onClick = { [weak self] in self?.parent.onSelectionChange([id], id) }
            }
            cell.cellView.onStackBadge = { [weak self] in
                if let sid = entry.stackID { self?.parent.onToggleStack(sid) }
            }
            return cell
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

/// Lets single-key shortcuts reach the app's key handler instead of being swallowed as type-select,
/// and provides the right-click menu.
final class KeyPassingCollectionView: NSCollectionView {
    var onRightClick: ((IndexPath?) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        // Shortcuts are handled by KeyboardController before reaching here; anything else goes up.
        nextResponder?.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let ip = indexPathForItem(at: p) else { return nil }
        onRightClick?(ip)
        return contextMenuProvider?()
    }
}
