import AppKit
import CullerKit

enum UndoAction {
    case metadata([(id: ItemID, old: PhotoMetadata, new: PhotoMetadata)])
    case fileOperation(UUID)

    var title: String {
        switch self {
        case .metadata(let c): return c.count == 1 ? "Mark" : "Mark \(c.count) Photos"
        case .fileOperation: return "File Operation"
        }
    }
}

/// A marking command (spec §9).
enum MarkCommand: Equatable {
    case flag(Flag)
    case rating(Int)
    case toggleLabel(ColorLabel)
    case setLabel(ColorLabel)
    case note(String)
}

extension FolderSession {
    // MARK: Targets

    /// Items a marking command applies to: compare → active slot; loupe → current; grid → selection.
    var markTargets: [PhotoItem] {
        switch viewMode {
        case .compare:
            return compare.activeItemID.flatMap { items[$0] }.map { [$0] } ?? []
        case .loupe:
            return currentItem.map { [$0] } ?? []
        case .grid:
            let ids = selection.isEmpty ? Set(currentID.map { [$0] } ?? []) : selection
            return ids.compactMap { items[$0] }.sorted { (displayIndex[$0.id] ?? 0) < (displayIndex[$1.id] ?? 0) }
        }
    }

    // MARK: Apply

    func apply(_ cmd: MarkCommand, advance: Bool = false) {
        let targets = markTargets
        guard !targets.isEmpty else { return }
        var changes: [(id: ItemID, old: PhotoMetadata, new: PhotoMetadata)] = []
        for item in targets {
            ensureLoaded(item)
            var m = item.metadata
            switch cmd {
            case .flag(let f): m.flag = f
            case .rating(let r): m.rating = r
            case .toggleLabel(let l): m.label = (m.label == l) ? .none : l
            case .setLabel(let l): m.label = l
            case .note(let n): m.note = n
            }
            if m != item.metadata { changes.append((item.id, item.metadata, m)) }
        }
        // Advance target is chosen before the display is rebuilt (a filter may hide the item just marked).
        let nextID = advance ? neighbourID(offset: 1) : nil
        if !changes.isEmpty {
            setMetadata(changes.map { ($0.id, $0.new) })
            pushUndo(.metadata(changes))
        }
        if advance {
            if viewMode == .compare {
                stepActiveSlot(1)
            } else if let n = nextID {
                select(n)
            }
        }
    }

    /// Writes new metadata values to items (memory immediately, disk via the background queue).
    func setMetadata(_ values: [(ItemID, PhotoMetadata)]) {
        var needsRebuild = filter.isActive || sort.key == .rating
        for (id, m) in values {
            guard let item = items[id] else { continue }
            if item.metadata.flag != m.flag, stackOf[id] != nil { needsRebuild = true }  // stack cover may change
            item.metadata = m
            item.metadataLoaded = true
            enqueueWrite(item)
        }
        if needsRebuild {
            let keep = currentID, oldIndex = currentIndex
            rebuildDisplay()
            // A filter may now hide the current item: stay at the same position in the list.
            if let keep, displayIndex[keep] == nil || currentID != keep, let oldIndex, !display.isEmpty {
                let alt = display[min(oldIndex, display.count - 1)].itemID
                currentID = alt
                selection = [alt]
            }
        }
    }

    // MARK: Undo / redo

    func pushUndo(_ a: UndoAction) {
        undoStack.append(a)
        if undoStack.count > 500 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoRevision += 1
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let a = undoStack.popLast() else { return }
        switch a {
        case .metadata(let changes):
            setMetadata(changes.map { ($0.id, $0.old) })
            if let first = changes.first?.id, displayIndex[first] != nil { select(first) }
            redoStack.append(a)
        case .fileOperation(let id):
            if undoFileOperation(id) { redoStack.append(a) } else { undoStack.append(a) }
        }
        undoRevision += 1
    }

    func redo() {
        guard let a = redoStack.popLast() else { return }
        switch a {
        case .metadata(let changes):
            setMetadata(changes.map { ($0.id, $0.new) })
            if let first = changes.first?.id, displayIndex[first] != nil { select(first) }
            undoStack.append(a)
        case .fileOperation(let id):
            if redoFileOperation(id) { undoStack.append(a) } else { redoStack.append(a) }
        }
        undoRevision += 1
    }

    // MARK: Navigation

    func neighbourID(offset: Int) -> ItemID? {
        guard !display.isEmpty else { return nil }
        guard let i = currentIndex else { return display.first?.itemID }
        let j = i + offset
        guard display.indices.contains(j) else { return nil }
        return display[j].itemID
    }

    func select(_ id: ItemID, extendSelection: Bool = false) {
        if let c = currentIndex, let n = displayIndex[id] { lastDirection = n >= c ? 1 : -1 }
        currentID = id
        if !extendSelection { selection = [id] }
    }

    func move(_ offset: Int, extend: Bool = false) {
        guard let n = neighbourID(offset: offset) ?? (offset > 0 ? display.last?.itemID : display.first?.itemID),
              n != currentID else { return }
        guard extend, let anchorID = selectionAnchor ?? currentID,
              let a = displayIndex[anchorID], let b = displayIndex[n] else {
            select(n)
            selectionAnchor = n
            return
        }
        // ⇧+arrow: select the range from the anchor to the new position.
        currentID = n
        lastDirection = offset > 0 ? 1 : -1
        selection = Set(display[min(a, b)...max(a, b)].map(\.itemID))
        selectionAnchor = anchorID
    }

    /// ⌥→ / ⌥←: next / previous unflagged item.
    func moveToUnflagged(_ direction: Int) {
        guard let start = currentIndex else { return }
        var i = start + direction
        while display.indices.contains(i) {
            if let item = items[display[i].itemID], item.metadata.flag == .none {
                select(item.id)
                return
            }
            i += direction
        }
        NSSound.beep()
    }

    func selectAll() {
        selection = Set(display.map(\.itemID))
    }
}
