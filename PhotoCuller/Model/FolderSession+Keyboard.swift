import AppKit
import CullerKit

enum SessionSheet: String, Identifiable {
    case rename, move, copy
    var id: String { rawValue }
}

extension FolderSession {
    /// Executes a key action. Returns false when the key should continue to the focused view.
    func perform(_ m: KeyMap.Match) -> Bool {
        switch m.action {
        case .mark(let cmd):
            apply(cmd, advance: m.advance)
        case .next:
            viewMode == .compare ? stepActiveSlot(1) : move(1, extend: m.extend)
        case .previous:
            viewMode == .compare ? stepActiveSlot(-1) : move(-1, extend: m.extend)
        case .up, .down:
            guard viewMode == .grid else { return false }
            move((m.action == .up ? -1 : 1) * max(1, gridColumns), extend: m.extend)
        case .nextUnflagged:
            moveToUnflagged(1)
        case .previousUnflagged:
            moveToUnflagged(-1)
        case .toggleStack:
            toggleSelectedStacks()
        case .toggleSyncZoom:
            compare.syncZoom.toggle()
        case .togglePinBest:
            compare.pinBest.toggle()
        case .togglePeaking:
            showPeaking.toggle()
        case .toggleClipping:
            showClipping.toggle()
        case .zoomToSubject:
            guard viewMode != .grid else { return false }
            zoomToSubject()
        case .sharpest:
            goToSharpest()
        case .trash:
            trashSelection()
        case .toggleStripShowsAll:
            guard viewMode == .compare else { return false }
            setCompareStripShowsAll(!compare.stripShowsAll)
        case .showGrid:
            viewMode = .grid
        case .showLoupe:
            if currentID != nil { viewMode = .loupe }
        case .showCompare:
            enterCompare()
        case .switchSlot:
            guard viewMode == .compare else { return false }
            cycleActiveSlot()
        case .enter:
            switch viewMode {
            case .grid:
                if currentID != nil { viewMode = .loupe }
            case .compare:
                guard compare.pinBest else { return false }
                promoteCandidate()
            case .loupe:
                return false
            }
        case .toggleZoom:
            guard viewMode != .grid else { return false }
            viewports.toggleZoom(slot: viewMode == .compare ? compare.active : 0)
        case .toggleInfo:
            showInfoPanel.toggle()
        case .toggleHistogram:
            showHistogram.toggle()
        case .editNote:
            beginNoteEditing()
        case .rename:
            activeSheet = .rename
        case .escape:
            if viewMode == .grid { return false }
            viewMode = .grid
        }
        return true
    }

    func beginNoteEditing() {
        guard let target = markTargets.first else { return }
        ensureLoaded(target)
        editingNote = target.id
    }

    func commitNote(_ text: String) {
        guard let id = editingNote else { return }
        editingNote = nil
        guard let item = items[id] else { return }
        let old = item.metadata
        var m = old
        m.note = text
        guard m != old else { return }
        setMetadata([(id, m)])
        pushUndo(.metadata([(id, old, m)]))
        showHUD(for: .note(text), count: 1, result: old)
    }
}
