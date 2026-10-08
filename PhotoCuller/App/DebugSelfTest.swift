#if DEBUG
import AppKit
import CullerKit

/// DEBUG-only smoke test driven through the real session (launch with `-openFolder <dir> -selfTest`).
/// Exercises marking → background write → undo, stacks, filters, compare and rename planning inside the sandbox.
enum DebugSelfTest {
    static func run(_ s: FolderSession) async {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            Log.session.info("SELFTEST \(ok ? "ok  " : "FAIL", privacy: .public) \(what, privacy: .public)")
            if !ok { failures.append(what) }
        }
        while s.phase != .ready || s.indexing != nil { try? await Task.sleep(for: .milliseconds(100)) }

        let sizes = s.stackMembers.values.map(\.count).sorted()
        check(!sizes.isEmpty, "stacks built: \(sizes)")
        let bodies = Set(s.stackMembers.values.map { Set($0.compactMap { s.items[$0]?.exif?.bodyKey }).count })
        check(bodies == [1], "no stack mixes camera bodies")

        guard let first = s.display.first, let item = s.items[first.itemID] else { return check(false, "has items") }
        s.select(item.id)
        s.viewMode = .loupe
        s.apply(.flag(.pick))
        s.apply(.rating(4))
        s.apply(.toggleLabel(.green))
        check(item.metadata == PhotoMetadata(flag: .pick, rating: 4, label: .green), "in-memory marks applied immediately")
        try? await Task.sleep(for: .milliseconds(900))
        let onDisk = MetadataStore.read(item.files, recover: false).metadata
        check(onDisk == item.metadata, "marks written to disk: \(onDisk)")
        check(item.writeState == .saved, "write state saved")
        if item.files.needsSidecar { check(item.files.sidecarURL != nil, "sidecar created for RAW") }

        var f = FilterState()
        f.flags = [.pick]
        s.filter = f
        check(s.matchingCount == 1, "filter pick → 1 match (got \(s.matchingCount))")
        s.filter = FilterState()

        s.undo(); s.undo(); s.undo()
        check(item.metadata == .empty, "undo x3 clears marks")
        try? await Task.sleep(for: .milliseconds(900))
        check(MetadataStore.read(item.files, recover: false).metadata == .empty, "undo persisted to disk")

        // Advance with shift-style marking.
        s.apply(.rating(2), advance: true)
        check(s.currentID != item.id, "advance moved to next item")
        s.undo()

        // Compare from a stack.
        if let sid = s.stackMembers.keys.first, let m = s.stackMembers[sid] {
            s.select(m[0])
            s.enterCompare()
            check(s.viewMode == .compare && s.compare.slots.count >= 2 && s.compare.candidates.count == m.count, "compare entered with stack candidates")
            let before = s.compare.activeItemID
            s.stepActiveSlot(1)
            check(s.compare.activeItemID != before, "←/→ changes active slot item")
            s.cycleActiveSlot()
            check(s.compare.active == 0 || s.compare.active == 1, "tab cycles slots")

            // Drag & drop: payload survives a real pasteboard, and a drop fills the right slot.
            let pb = NSPasteboard(name: NSPasteboard.Name("PhotoCuller.selftest"))
            pb.clearContents()
            let dragged = s.display.last!.itemID
            pb.writeObjects([DragPayload.pasteboardItem(for: s.items[dragged]!)])
            let dropped = DragPayload.itemID(from: pb)
            check(dropped == dragged, "drag payload round-trips")
            if let dropped { s.put(dropped, inSlot: 1) }
            check(s.compare.slots[1] == dragged && s.compare.active == 1, "drop puts photo in right slot")
            pb.releaseGlobally()

            let base = s.compare.candidates.count
            s.setCompareStripShowsAll(true)
            check(s.compare.candidates.count == s.allDisplayItemIDs.count && s.compare.candidates.count > base,
                  "filmstrip all photos (\(s.compare.candidates.count)) vs candidates (\(base))")
            s.setCompareStripShowsAll(false)
            check(s.compare.candidates.count == base, "filmstrip back to candidates")
            check(s.showFilmstrip, "filmstrip visible by default")
            s.viewMode = .grid
        }

        if let t = try? RenameTemplate("{date:yyyyMMdd}_{seq:4}_{original}") {
            let plans = s.planRename(Array(s.items(in: .filtered).prefix(3)), template: t, sequenceStart: 1)
            check(plans.count == 3 && plans.allSatisfy { $0.newBaseName.hasPrefix("2026") }, "rename preview: \(plans.map(\.newBaseName))")
        }

        // Multi-select: ⇧-range then S expands every selected stack.
        s.viewMode = .grid
        s.expandAllStacks(false)
        let covers = s.display.filter(\.isCollapsedStack).map(\.itemID)
        if covers.count >= 2 {
            s.select(covers[0])
            s.selectionAnchor = covers[0]
            let target = s.displayIndex[covers[1]]! - s.displayIndex[covers[0]]!
            for _ in 0..<target { s.move(1, extend: true) }
            check(s.selection.isSuperset(of: [covers[0], covers[1]]), "⇧→ extends selection across \(target + 1) entries")
            s.toggleSelectedStacks()
            let expanded = Set([covers[0], covers[1]].compactMap { s.stackOf[$0] })
            check(expanded.isSubset(of: s.expandedStacks), "S expands all selected stacks (\(expanded.count))")
            s.toggleSelectedStacks()
            check(expanded.isDisjoint(with: s.expandedStacks), "S again collapses them")
        }
        check(PhotoContextMenu.make(s)?.items.count ?? 0 > 10, "context menu builds for selection")

        // RAW / JPEG display modes.
        let start = s.fileView
        func waitRegroup() async { for _ in 0..<60 where s.indexing != nil || true { try? await Task.sleep(for: .milliseconds(100)); if s.indexing == nil { break } } }
        s.setFileView(.combined); await waitRegroup(); try? await Task.sleep(for: .milliseconds(600))
        let combined = s.matchingCount
        s.setFileView(.both); try? await Task.sleep(for: .milliseconds(800)); await waitRegroup()
        let both = s.matchingCount
        s.setFileView(.jpegOnly); try? await Task.sleep(for: .milliseconds(200))
        let jpeg = s.matchingCount
        s.setFileView(.rawOnly); try? await Task.sleep(for: .milliseconds(200))
        let raw = s.matchingCount
        let pairs = s.items.values.filter { $0.files.primary.kind.isRaw }.count
        check(both == combined + pairs && jpeg == combined && raw == pairs, "file modes: one=\(combined) separate=\(both) jpeg=\(jpeg) raw=\(raw)")
        s.setFileView(start); try? await Task.sleep(for: .milliseconds(800)); await waitRegroup()
        check(s.matchingCount == (start == .combined ? combined : both), "back to \(start.rawValue)")

        // Sidebar tree.
        let sidebar = s.app.sidebar
        let wasPinned = sidebar.isPinned(s.folder)
        sidebar.pin(s.folder)
        let node = await sidebar.reveal(s.folder)
        await node?.load()
        check(node?.photoCount == combined, "sidebar counts \(node?.photoCount ?? -1) photos")
        check(sidebar.favorites.count == 5 && !sidebar.locations.isEmpty, "Finder-like favorites (\(sidebar.favorites.map(\.name))) + \(sidebar.locations.count) locations")
        if let home = sidebar.favorites.first {
            await home.load(force: true)
            check(home.needsAccess != AccessGrants.canRead(home.url), "home folder access state matches sandbox (locked: \(home.needsAccess))")
        }
        if !wasPinned, let n = sidebar.pinned.first(where: { $0.url == s.folder.standardizedFileURL }) { sidebar.unpin(n) }

        // Tabs: a second workspace on the same folder keeps its own state; switching back restores the first.
        let app = s.app
        let firstTab = app.activeTab
        s.viewMode = .grid
        s.select(s.display[1].itemID)
        let keepCurrent = s.currentID
        let t2 = app.newTab(folder: s.folder)
        for _ in 0..<80 where t2.session?.phase != .ready { try? await Task.sleep(for: .milliseconds(100)) }
        check(app.tabs.count >= 2 && app.session === t2.session && t2.session !== s, "new tab opens its own session")
        t2.session?.viewMode = .loupe
        app.selectTab(firstTab)
        check(app.session === s && s.currentID == keepCurrent && s.viewMode == .grid, "switching back restores tab 1 state")
        app.selectTab(t2)
        check(app.session?.viewMode == .loupe, "tab 2 kept its own view mode")
        app.closeTab(t2)
        check(app.activeTab === firstTab && app.session === s, "closing tab returns to tab 1")

        // Menu bar: no two commands may share a shortcut.
        var seen: [String: String] = [:]
        var dupes: [String] = []
        func walk(_ m: NSMenu, _ path: String) {
            for it in m.items {
                if let sub = it.submenu { walk(sub, path + it.title + " > ") }
                guard !it.keyEquivalent.isEmpty else { continue }
                let key = "\(it.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control, .function]).rawValue)-\(it.keyEquivalent.lowercased())"
                if let other = seen[key] { dupes.append("\(other) ↔ \(path + it.title)") } else { seen[key] = path + it.title }
            }
        }
        if let main = NSApp.mainMenu { walk(main, "") }
        check(dupes.isEmpty, "no duplicate menu shortcuts \(dupes) (\(seen.count) shortcuts)")

        let st = s.app.pipeline.stats
        Log.session.info("SELFTEST stats thumbs=\(st.thumbRequests) gen=\(st.thumbGenerated) previews=\(st.previewRequests) lastPreviewMs=\(st.lastPreviewMs)")
        Log.session.info("SELFTEST \(failures.isEmpty ? "PASS" : "FAILED: \(failures)", privacy: .public)")
    }
}
#endif
