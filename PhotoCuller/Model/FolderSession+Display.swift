import Foundation
import CullerKit

extension FolderSession {
    /// Recomputes stacks, keeping the cached similarity distances (threshold slider), then the display list.
    func regroup(keepPrepared: Bool = false) {
        rebuildStacks(keepPrepared: keepPrepared)
        rebuildDisplay()
    }

    /// Recomputes stacks: burst timing + camera body (spec §4.4), or visual similarity.
    func rebuildStacks(keepPrepared: Bool = false) {
        if !keepPrepared { similarityPrepared = nil }
        let previousExpanded = expandedStacks.compactMap { stackMembers[$0] }
        let mode = fileView
        guard settings.stackBursts else {
            stackMembers = [:]
            stackOf = [:]
            expandedStacks = []
            return
        }
        // In the separate modes a JPEG and its RAW share the exact capture time; keying stacks by file type
        // keeps them from collapsing into one stack (only real bursts of the same type stack).
        func groupKey(_ item: PhotoItem) -> String {
            var key = item.exif?.bodyKey ?? "unknown"
            if !mode.pairs { key += item.files.primary.kind.isRaw ? "|raw" : "|raster" }
            return key
        }
        let visible = items.values.filter { mode.shows($0.files) }
        let groups: [[String]]
        if settings.groupingMode == .similarity {
            if similarityPrepared == nil {
                similarityPrepared = SimilarityGrouper.prepare(visible.map {
                    .init(id: $0.id, captureDate: $0.exif?.captureDate, groupKey: groupKey($0), print: featurePrints[$0.id])
                })
            }
            groups = SimilarityGrouper.groups(similarityPrepared!, threshold: Float(settings.similarityThreshold))
        } else {
            groups = StackBuilder.build(visible.map {
                StackBuilder.Input(id: $0.id, captureDate: $0.exif?.captureDate, bodyKey: groupKey($0))
            }, threshold: settings.burstThreshold)
        }
        stackMembers = [:]
        stackOf = [:]
        for g in groups where g.count > 1 {
            let sid = g[0]
            stackMembers[sid] = g
            for id in g { stackOf[id] = sid }
        }
        updateSharpest()
        // Keep stacks expanded across rebuilds when they still contain the same first frames.
        var expanded: Set<String> = []
        for members in previousExpanded {
            if let sid = members.lazy.compactMap({ self.stackOf[$0] }).first { expanded.insert(sid) }
        }
        expandedStacks = expanded
    }

    /// Recomputes the filtered, sorted display list (spec §7: stacks stay intact, shown if ≥1 member matches).
    func rebuildDisplay() {
        let f = filter
        let filterActive = f.isActive
        let mode = fileView
        func matches(_ id: ItemID) -> Bool {
            guard let item = items[id] else { return false }
            guard mode.shows(item.files) else { return false }
            guard filterActive else { return true }
            return f.matches(metadata: item.metadata, exif: item.exif, files: item.files)
        }

        struct Unit {
            var representative: PhotoItem
            var stackID: String?
            var matching: [ItemID]
            var total: Int
        }
        var units: [Unit] = []
        units.reserveCapacity(items.count)
        var seenStacks: Set<String> = []
        var matchCount = 0
        for item in items.values where mode.shows(item.files) {
            if let sid = stackOf[item.id] {
                guard seenStacks.insert(sid).inserted, let members = stackMembers[sid] else { continue }
                let m = members.filter(matches)
                guard !m.isEmpty else { continue }
                matchCount += m.count
                let coverID = StackBuilder.cover(of: m) { self.items[$0]?.metadata.flag == .pick }
                units.append(Unit(representative: items[coverID] ?? item, stackID: sid, matching: m, total: members.count))
            } else if matches(item.id) {
                matchCount += 1
                units.append(Unit(representative: item, stackID: nil, matching: [item.id], total: 1))
            }
        }

        let order = sort
        units.sort { a, b in
            order.areInIncreasingOrder((a.representative.files, a.representative.exif, a.representative.metadata),
                                       (b.representative.files, b.representative.exif, b.representative.metadata))
        }

        var out: [DisplayEntry] = []
        out.reserveCapacity(matchCount)
        for u in units {
            guard let sid = u.stackID else {
                out.append(DisplayEntry(itemID: u.representative.id, stackID: nil, kind: .single))
                continue
            }
            if expandedStacks.contains(sid) {
                for (i, id) in u.matching.enumerated() {
                    out.append(DisplayEntry(itemID: id, stackID: sid, kind: .stackMember(position: i + 1, count: u.matching.count)))
                }
            } else {
                out.append(DisplayEntry(itemID: u.representative.id, stackID: sid,
                                        kind: .collapsedStack(matching: u.matching.count, total: u.total)))
            }
        }

        display = out
        var idx: [ItemID: Int] = [:]
        idx.reserveCapacity(out.count)
        for (i, e) in out.enumerated() { idx[e.itemID] = i }
        displayIndex = idx
        matchingCount = matchCount
        displayRevision += 1
        itemsRevision += 1

        // Keep the current item visible: if it was hidden inside a collapsed stack, jump to its cover.
        if let c = currentID, displayIndex[c] == nil {
            if let sid = stackOf[c], let cover = out.first(where: { $0.stackID == sid }) {
                currentID = cover.itemID
            } else {
                currentID = out.first?.itemID
            }
        }
        selection = selection.filter { displayIndex[$0] != nil }
        if selection.isEmpty, let c = currentID { selection = [c] }
    }

    /// Forces every view to re-request its images (e.g. after the RAW look changed).
    func imagesChanged() {
        imageRevision += 1
        displayRevision += 1
    }

    /// Item IDs of the members of a stack that pass the filter.
    func visibleMembers(ofStack sid: String) -> [ItemID] {
        guard let members = stackMembers[sid] else { return [] }
        guard filter.isActive else { return members }
        return members.filter { id in
            guard let i = items[id] else { return false }
            return filter.matches(metadata: i.metadata, exif: i.exif, files: i.files)
        }
    }

    /// Expands / collapses one stack and puts the pointer on it: the first frame when expanding,
    /// the cover when collapsing (so it never stays on a photo outside the stack).
    func toggleStack(_ sid: String) {
        let expanding = !expandedStacks.contains(sid)
        if expanding { expandedStacks.insert(sid) } else { expandedStacks.remove(sid) }
        rebuildDisplay()
        pointAt(stack: sid, expanded: expanding)
    }

    /// Pointer + selection onto a stack after it was expanded / collapsed.
    private func pointAt(stack sid: String, expanded: Bool) {
        let target = expanded ? visibleMembers(ofStack: sid).first { displayIndex[$0] != nil }
                              : display.first { $0.stackID == sid }?.itemID
        guard let target else { return }
        select(target)
        selectionAnchor = target
    }

    /// S: expand / collapse the stack of the current item.
    func toggleCurrentStack() {
        guard let c = currentID, let sid = stackOf[c] else { return }
        toggleStack(sid)
    }

    /// S with several photos selected: if any selected stack is collapsed, expand them all; otherwise collapse them all.
    func toggleSelectedStacks() {
        var ids = selection
        if let c = currentID { ids.insert(c) }
        let sids = Set(ids.compactMap { stackOf[$0] })
        guard !sids.isEmpty else { return }
        let expand = sids.contains { !expandedStacks.contains($0) }
        if expand { expandedStacks.formUnion(sids) } else { expandedStacks.subtract(sids) }
        let multi = sids.count > 1 || selection.count > 1
        rebuildDisplay()
        // The pointer goes to the first (in display order) of the stacks just toggled.
        let first = sids.min { (firstIndex(ofStack: $0) ?? .max) < (firstIndex(ofStack: $1) ?? .max) }
        if let first { pointAt(stack: first, expanded: expand) }
        // Keep every member of newly expanded stacks selected so the next action applies to the whole block.
        if expand, multi {
            selection = Set(sids.flatMap { visibleMembers(ofStack: $0) }).filter { displayIndex[$0] != nil }
        }
    }

    private func firstIndex(ofStack sid: String) -> Int? {
        display.firstIndex { $0.stackID == sid }
    }

    func expandAllStacks(_ expand: Bool) {
        expandedStacks = expand ? Set(stackMembers.keys) : []
        rebuildDisplay()
    }

    /// Values available for EXIF filters in the current folder.
    var cameraNames: [String] {
        Array(Set(items.values.compactMap { $0.exif?.cameraName })).sorted()
    }

    var lensNames: [String] {
        Array(Set(items.values.compactMap { $0.exif?.lens })).sorted()
    }

    func exifRange<T: Comparable>(_ key: (ExifInfo) -> T?) -> ClosedRange<T>? {
        let values = items.values.compactMap { $0.exif.flatMap(key) }
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return lo...hi
    }
}
