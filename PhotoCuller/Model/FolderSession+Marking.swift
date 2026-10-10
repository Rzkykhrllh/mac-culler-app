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
            // A block selected in the filmstrip (⇧←/→, ⇧-click) is marked as a whole; otherwise the photo shown.
            if selection.count > 1, let c = currentID, selection.contains(c) {
                return selection.compactMap { items[$0] }.sorted { (displayIndex[$0.id] ?? 0) < (displayIndex[$1.id] ?? 0) }
            }
            return currentItem.map { [$0] } ?? []
        case .grid:
            let ids = selection.isEmpty ? Set(currentID.map { [$0] } ?? []) : selection
            return ids.compactMap { items[$0] }.sorted { (displayIndex[$0.id] ?? 0) < (displayIndex[$1.id] ?? 0) }
        }
    }

    // MARK: Apply

    func apply(_ cmd: MarkCommand, advance: Bool = false) {
        apply(cmd, to: markTargets, advance: advance)
    }

    /// Hover-bar actions in the grid: one photo, selection untouched.
    func apply(_ cmd: MarkCommand, toItem id: ItemID) {
        guard let item = items[id] else { return }
        apply(cmd, to: [item], advance: false)
    }

    private func apply(_ cmd: MarkCommand, to targets: [PhotoItem], advance: Bool) {
        guard !targets.isEmpty else { return }
        showHUD(for: cmd, count: targets.count, result: targets.first?.metadata)
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
        // With a block marked, "advance" continues after the block, not inside it.
        let lastIndex = targets.compactMap { displayIndex[$0.id] }.max()
        let nextID: ItemID? = !advance ? nil
            : targets.count > 1 ? lastIndex.flatMap { $0 + 1 < display.count ? display[$0 + 1].itemID : nil }
            : neighbourID(offset: 1)
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
            setMarks(item, m)
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
        hud = MarkHUD(symbol: "arrow.uturn.backward", text: "Undo", detail: a.title, tint: .neutral)
        hudTask?.cancel()
        hudTask = Task { [weak self] in try? await Task.sleep(for: .milliseconds(700)); if !Task.isCancelled { self?.hud = nil } }
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
        hud = MarkHUD(symbol: "arrow.uturn.forward", text: "Redo", detail: a.title, tint: .neutral)
        hudTask?.cancel()
        hudTask = Task { [weak self] in try? await Task.sleep(for: .milliseconds(700)); if !Task.isCancelled { self?.hud = nil } }
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

    /// ⇧-click: everything from the anchor (last plain click) to `id`, in grid order.
    /// ⌘⇧-click adds that range to the current selection.
    func selectRange(to id: ItemID, adding: Bool = false) {
        guard let anchorID = selectionAnchor ?? currentID, let a = displayIndex[anchorID], let b = displayIndex[id] else {
            select(id)
            selectionAnchor = id
            return
        }
        let range = Set(display[min(a, b)...max(a, b)].map(\.itemID))
        selection = adding ? selection.union(range) : range
        currentID = id
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

/// What the marking HUD shows.
struct MarkHUD: Equatable {
    var id = UUID()
    var symbol: String?
    var text: String
    var detail: String?
    var tint: HUDTint

    enum HUDTint: Equatable { case neutral, pick, reject, star, label(ColorLabel) }
}

extension FolderSession {
    /// Confirms a mark with a big, brief HUD (keyboard culling needs immediate feedback).
    func showHUD(for cmd: MarkCommand, count: Int, result before: PhotoMetadata?) {
        var h: MarkHUD
        switch cmd {
        case .flag(.pick): h = MarkHUD(symbol: "flag.fill", text: "Pick", tint: .pick)
        case .flag(.reject): h = MarkHUD(symbol: "xmark.circle.fill", text: "Reject", tint: .reject)
        case .flag(.none): h = MarkHUD(symbol: "flag.slash", text: "Unflagged", tint: .neutral)
        case .rating(let r): h = MarkHUD(symbol: nil, text: r == 0 ? "No rating" : String(repeating: "★", count: r), tint: r == 0 ? .neutral : .star)
        case .toggleLabel(let l):
            let removing = count == 1 && before?.label == l
            h = MarkHUD(symbol: removing ? "circle.slash" : "circle.fill", text: removing ? "Label removed" : "\(l.displayName) label", tint: removing ? .neutral : .label(l))
        case .setLabel(let l): h = MarkHUD(symbol: l == .none ? "circle.slash" : "circle.fill", text: l == .none ? "No label" : "\(l.displayName) label", tint: l == .none ? .neutral : .label(l))
        case .note: h = MarkHUD(symbol: "text.bubble.fill", text: "Note saved", tint: .neutral)
        }
        if count > 1 { h.detail = "\(count) photos" }
        hud = h
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            self?.hud = nil
        }
    }
}
