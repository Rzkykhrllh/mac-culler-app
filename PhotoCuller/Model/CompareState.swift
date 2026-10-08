import AppKit

/// Compare mode state (spec §6.3).
struct CompareState: Equatable {
    /// Item shown in each slot (nil = empty slot).
    var slots: [ItemID?] = [nil, nil]
    var active = 0
    /// Filmstrip contents: the items slots can be filled from.
    var candidates: [ItemID] = []
    /// "Pin current best": slot 0 holds the best, ←/→ cycles the other slot, Return promotes.
    var pinBest = false
    var syncZoom = true

    var activeItemID: ItemID? { slots.indices.contains(active) ? slots[active] : nil }

    mutating func setSlotCount(_ n: Int) {
        let n = max(2, min(4, n))
        if slots.count < n {
            // Fill new slots with candidates not shown yet.
            let shown = Set(slots.compactMap { $0 })
            var fresh = candidates.filter { !shown.contains($0) }.makeIterator()
            while slots.count < n { slots.append(fresh.next()) }
        } else {
            slots = Array(slots.prefix(n))
        }
        active = min(active, n - 1)
    }
}

extension FolderSession {
    /// C: enter compare. ≥2 selected → those; current inside a stack → stack members; else the filtered list.
    func enterCompare() {
        let n = max(2, min(4, settings.compareSlotCount))
        var c = CompareState()
        c.pinBest = settings.comparePinBest
        c.syncZoom = compare.candidates.isEmpty ? settings.compareSyncDefault : compare.syncZoom
        let ordered = selection.sorted { (displayIndex[$0] ?? 0) < (displayIndex[$1] ?? 0) }
        if viewMode == .grid, ordered.count >= 2 {
            c.candidates = ordered
            c.slots = (0..<n).map { ordered.indices.contains($0) ? ordered[$0] : nil }
            c.active = 0
        } else if let cur = currentID, let sid = stackOf[cur] {
            let members = visibleMembers(ofStack: sid)
            c.candidates = members
            c.slots = (0..<n).map { members.indices.contains($0) ? members[$0] : nil }
            c.active = members.count > 1 ? 1 : 0
        } else {
            c.candidates = display.map(\.itemID)
            c.slots = [currentID] + Array(repeating: nil, count: n - 1)
            c.active = currentID == nil ? 0 : 1
        }
        if c.pinBest { c.active = min(1, c.slots.count - 1) }
        compare = c
        viewMode = .compare
    }

    /// Clicking a filmstrip item puts it into the active slot.
    func putInActiveSlot(_ id: ItemID) {
        guard compare.slots.indices.contains(compare.active) else { return }
        compare.slots[compare.active] = id
        currentID = id
    }

    /// Tab: next slot.
    func cycleActiveSlot() {
        var start = compare.active
        repeat {
            start = (start + 1) % compare.slots.count
        } while compare.pinBest && start == 0 && compare.slots.count > 1
        compare.active = start
        if let id = compare.activeItemID { currentID = id }
    }

    /// ←/→ in compare: change the active slot's item to the previous / next candidate.
    func stepActiveSlot(_ offset: Int) {
        let list = compare.candidates
        guard !list.isEmpty else { return }
        let skip: Set<ItemID> = compare.pinBest ? Set([compare.slots.first ?? nil].compactMap { $0 }) : []
        var idx = compare.activeItemID.flatMap { list.firstIndex(of: $0) } ?? (offset > 0 ? -1 : list.count)
        repeat {
            idx += offset
        } while list.indices.contains(idx) && skip.contains(list[idx])
        guard list.indices.contains(idx) else { NSSound.beep(); return }
        putInActiveSlot(list[idx])
    }

    /// Return in pin mode: the candidate becomes the new best.
    func promoteCandidate() {
        guard compare.pinBest, compare.slots.count > 1, let candidate = compare.slots[compare.active], compare.active != 0 else { return }
        compare.slots[0] = candidate
        compare.active = 1
        stepActiveSlot(1)
    }
}
