#if DEBUG
import AppKit
import CullerKit

/// DEBUG-only smoke test driven through the real session (launch with `-openFolder <dir> -selfTest`).
/// Exercises marking → background write → undo, stacks, filters, compare and rename planning inside the sandbox.
enum DebugSelfTest {
    /// `-openFolder <dir> -focusTest`: focus analysis, sharpest-in-stack, zoom-to-subject and overlays on real photos.
    static func runFocus(_ s: FolderSession) async {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            Log.session.info("FOCUSTEST \(ok ? "ok  " : "FAIL", privacy: .public) \(what, privacy: .public)")
            if !ok { failures.append(what) }
        }
        while s.phase != .ready || s.indexing != nil { try? await Task.sleep(for: .milliseconds(100)) }
        let saved = (s.settings.stackBursts, s.settings.groupingMode)
        defer { s.settings.stackBursts = saved.0; s.settings.groupingMode = saved.1; s.regroup() }
        s.settings.stackBursts = true
        s.settings.groupingMode = .time
        s.regroup()
        let t0 = Date()
        while s.analysisTask != nil { try? await Task.sleep(for: .milliseconds(100)) }
        let all = Array(s.items.values)
        check(all.allSatisfy { $0.analysis != nil }, "all \(all.count) photos analyzed in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        let withSubject = all.filter { !($0.analysis?.subjects.isEmpty ?? true) }
        check(!withSubject.isEmpty, "subjects found in \(withSubject.count)/\(all.count): \(Set(withSubject.compactMap { $0.analysis?.subjects.first?.label ?? $0.analysis?.subjects.first?.kind.rawValue }))")
        for members in s.stackMembers.values.sorted(by: { ($0.first ?? "") < ($1.first ?? "") }) {
            let desc = members.map { id -> String in
                let i = s.items[id]!
                return "\((id as NSString).lastPathComponent.replacingOccurrences(of: ".JPG", with: ""))=\(Int(i.analysis?.sharpness ?? -1))\(i.isSharpestInStack ? "★" : "")"
            }.joined(separator: " ")
            Log.session.info("FOCUSTEST stack \(desc, privacy: .public)")
        }
        let marked = all.filter(\.isSharpestInStack)
        check(!marked.isEmpty && marked.allSatisfy { s.stackOf[$0.id] != nil }, "sharpest marked in \(marked.count) of \(s.stackMembers.count) stacks")
        if let best = marked.first, let sid = s.stackOf[best.id], let other = s.stackMembers[sid]?.first(where: { $0 != best.id }) {
            s.select(other)
            s.goToSharpest()
            check(s.currentID == best.id, "B jumps to the sharpest frame")
        }
        // Y in loupe.
        if let subj = withSubject.first {
            s.select(subj.id)
            s.viewMode = .loupe
            try? await Task.sleep(for: .milliseconds(1500))
            s.zoomToSubject()
            try? await Task.sleep(for: .milliseconds(1500))
            let vp = s.viewports.view(slot: 0)?.currentViewport
            let target = subj.analysis!.subjects[0].focusPoint
            check(vp?.isFit == false && abs((vp?.zoom ?? 0) - 1) < 0.05, "Y zooms to 100% (zoom \(String(format: "%.2f", vp?.zoom ?? 0)))")
            if let c = vp?.center {
                // The clip view may clamp at the image edge; allow for that.
                check(abs(c.x - target.x) < 0.2 && abs(c.y - target.y) < 0.2, "Y centers on the subject (\(String(format: "%.2f,%.2f", c.x, c.y)) → target \(String(format: "%.2f,%.2f", target.x, target.y)))")
            }
            // Overlays.
            s.showPeaking = true
            s.showClipping = true
            try? await Task.sleep(for: .milliseconds(1500))
            let canvas = s.viewports.view(slot: 0)?.canvas
            check(canvas?.peaking != nil && canvas?.clipping != nil, "peaking + clipping overlays shown (\(canvas?.peaking?.width ?? 0)×\(canvas?.peaking?.height ?? 0) for image \(canvas?.image?.width ?? 0)×\(canvas?.image?.height ?? 0))")
            if let img = canvas?.image {
                let t = Date(); _ = FocusOverlays.peaking(img); let pm = Date().timeIntervalSince(t) * 1000
                let t2 = Date(); _ = FocusOverlays.clipping(img); let cm = Date().timeIntervalSince(t2) * 1000
                check(pm < 300 && cm < 300, "overlay render \(Int(pm)) ms peaking, \(Int(cm)) ms clipping at \(img.width) px")
                if let pk = canvas?.peaking, let cl = canvas?.clipping {
                    let all = FocusOverlays.coverage(pk), onSubject = FocusOverlays.coverage(pk, in: subj.analysis!.subjects[0].rect)
                    check(onSubject > all && all > 0.002, "peaking lights the subject (\(String(format: "%.1f%%", onSubject * 100)) vs frame \(String(format: "%.1f%%", all * 100)))")
                    check(FocusOverlays.coverage(cl) < 0.1, "clipping only marks extremes (\(String(format: "%.2f%%", FocusOverlays.coverage(cl) * 100)))")
                }
            }
            s.viewports.view(slot: 0)?.apply(.fit)
            try? await Task.sleep(for: .milliseconds(800))
            if let w = KeyboardController.shared.mainWindow, let content = w.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Snapshots")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("peaking.png"))
            }
            s.showPeaking = false
            s.showClipping = false
        }
        // Y in compare: each slot on its own subject.
        let two = withSubject.prefix(2).map(\.id)
        if two.count == 2 {
            s.viewMode = .grid
            s.selection = Set(two)
            s.enterCompare()
            try? await Task.sleep(for: .milliseconds(1500))
            s.zoomToSubject()
            try? await Task.sleep(for: .milliseconds(1500))
            let a = s.viewports.view(slot: 0)?.currentViewport, b = s.viewports.view(slot: 1)?.currentViewport
            check(a?.isFit == false && b?.isFit == false, "Y zooms every compare slot")
            s.viewMode = .grid
        }
        Log.session.info("FOCUSTEST \(failures.isEmpty ? "PASS" : "FAILED: \(failures)", privacy: .public)")
    }

    /// `-openFolder <dir> -similarityTest`: similarity grouping on real photos, logs the groups by file name.
    static func runSimilarity(_ s: FolderSession) async {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            Log.session.info("SIMTEST \(ok ? "ok  " : "FAIL", privacy: .public) \(what, privacy: .public)")
            if !ok { failures.append(what) }
        }
        while s.phase != .ready || s.indexing != nil { try? await Task.sleep(for: .milliseconds(100)) }
        let saved = (s.settings.stackBursts, s.settings.groupingMode, s.settings.similarityThreshold)
        defer {
            s.settings.stackBursts = saved.0
            s.settings.groupingMode = saved.1
            s.app.setSimilarityThreshold(saved.2)
        }
        s.app.setSimilarityThreshold(0.45)
        let t0 = Date()
        s.app.setStackChoice(.similar)
        try? await Task.sleep(for: .milliseconds(200))
        while s.similarityTask != nil { try? await Task.sleep(for: .milliseconds(100)) }
        let visible = s.items.values.filter { s.fileView.shows($0.files) }.count
        check(s.featurePrints.count == visible, "feature prints for all \(visible) photos in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        func grouped() -> Int { s.stackMembers.values.reduce(0) { $0 + $1.count } }
        let at45 = grouped()
        check(!s.stackMembers.isEmpty, "similar stacks formed: \(s.stackMembers.count) stacks, \(at45) photos")
        for members in s.stackMembers.values.sorted(by: { ($0.first ?? "") < ($1.first ?? "") }) {
            Log.session.info("SIMTEST group \(members.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".JPG", with: "") }.joined(separator: " "), privacy: .public)")
        }
        let t1 = Date()
        s.app.setSimilarityThreshold(0.2)
        let strict = grouped()
        s.app.setSimilarityThreshold(0.8)
        let loose = grouped()
        let ms = Date().timeIntervalSince(t1) * 1000
        check(strict <= at45 && at45 <= loose, "stricter groups fewer photos (0.2: \(strict) ≤ 0.45: \(at45) ≤ 0.8: \(loose))")
        check(ms < 200, "slider regroup is instant (\(Int(ms)) ms for two changes)")
        // Second pass must come from the index cache.
        s.featurePrints = [:]
        let t2 = Date()
        s.ensureFeaturePrints()
        while s.similarityTask != nil { try? await Task.sleep(for: .milliseconds(20)) }
        check(s.featurePrints.count == visible, "reopen: prints from cache in \(Int(Date().timeIntervalSince(t2) * 1000)) ms")
        Log.session.info("SIMTEST \(failures.isEmpty ? "PASS" : "FAILED: \(failures)", privacy: .public)")
    }

    static func run(_ s: FolderSession) async {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            Log.session.info("SELFTEST \(ok ? "ok  " : "FAIL", privacy: .public) \(what, privacy: .public)")
            if !ok { failures.append(what) }
        }
        while s.phase != .ready || s.indexing != nil { try? await Task.sleep(for: .milliseconds(100)) }
        // This test checks burst stacks; restore the user's exact stack settings afterwards.
        let savedStacks = (s.settings.stackBursts, s.settings.groupingMode)
        s.settings.stackBursts = true
        s.settings.groupingMode = .time
        s.regroup()
        defer {
            s.settings.stackBursts = savedStacks.0
            s.settings.groupingMode = savedStacks.1
            s.regroup()
        }

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
        let mixed = s.stackMembers.values.filter { m in Set(m.compactMap { s.items[$0]?.files.primary.kind.isRaw }).count > 1 }
        check(mixed.isEmpty, "separate mode: no stack mixes a JPEG with a RAW (\(s.stackMembers.count) stacks)")
        let wasStacking = s.settings.stackBursts
        s.app.setStackBursts(false)
        check(s.stackMembers.isEmpty && s.display.count == s.matchingCount, "stacks off: every photo shown on its own")
        s.app.setStackBursts(wasStacking)
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

        // Layout at different window widths: nothing may stick out past the window, the minimum size holds.
        if let w = KeyboardController.shared.mainWindow, let content = w.contentView {
            let snapDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Snapshots")
            try? FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
            s.showInfoPanel = true
            s.showFilterBar = true
            for (mode, width) in [(ViewMode.grid, 900.0), (.grid, 1000), (.loupe, 900), (.compare, 900), (.grid, 1400)] {
                if mode == .compare { s.enterCompare() } else { s.viewMode = mode }
                w.setContentSize(NSSize(width: width, height: 640))
                try? await Task.sleep(for: .milliseconds(700))
                content.layoutSubtreeIfNeeded()
                let bounds = content.bounds
                var overflow: [String] = []
                func walk(_ v: NSView) {
                    if v is NSClipView { return }   // scrolled content may extend beyond by design
                    for sub in v.subviews where !sub.isHidden && sub.frame.width > 1 {
                        let f = sub.convert(sub.bounds, to: content)
                        if f.maxX > bounds.maxX + 2 || f.minX < bounds.minX - 2 { overflow.append("\(type(of: sub)) \(Int(f.minX))…\(Int(f.maxX))") }
                        walk(sub)
                    }
                }
                func findSplit(_ v: NSView) -> NSView? { v is NSSplitView ? v : v.subviews.lazy.compactMap(findSplit).first }
                if let split = findSplit(content) {
                    let f = split.convert(split.bounds, to: content)
                    if f.maxX > bounds.maxX + 2 || f.minX < bounds.minX - 2 { overflow.append("split view \(Int(f.minX))…\(Int(f.maxX))") }
                }
                check(overflow.isEmpty, "layout \(mode.rawValue) @\(Int(width))pt: nothing outside the window \(overflow.prefix(4))")
                if let rep = content.bitmapImageRepForCachingDisplay(in: bounds) {
                    content.cacheDisplay(in: bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: snapDir.appendingPathComponent("\(mode.rawValue)-\(Int(width)).png"))
                }
            }
            w.setContentSize(NSSize(width: 500, height: 400))
            try? await Task.sleep(for: .milliseconds(300))
            check(w.contentLayoutRect.width >= 899, "window can't shrink below its minimum (\(Int(w.contentLayoutRect.width))pt)")
            s.showInfoPanel = false
            s.showFilterBar = false
            s.viewMode = .grid
            w.setContentSize(NSSize(width: 1300, height: 820))
        }

        let st = s.app.pipeline.stats
        Log.session.info("SELFTEST stats thumbs=\(st.thumbRequests) gen=\(st.thumbGenerated) previews=\(st.previewRequests) lastPreviewMs=\(st.lastPreviewMs)")
        Log.session.info("SELFTEST \(failures.isEmpty ? "PASS" : "FAILED: \(failures)", privacy: .public)")
    }
}
#endif
