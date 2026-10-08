#if DEBUG
import AppKit
import CullerKit

/// DEBUG-only smoke test driven through the real session (launch with `-openFolder <dir> -selfTest`).
/// Exercises marking → background write → undo, stacks, filters, compare and rename planning inside the sandbox.
enum DebugSelfTest {
    /// `-openFolder <dir> -expandTest`: expands stacks through real mouse events / S and reports where the pointer is.
    static func runExpand(_ s: FolderSession) async {
        while s.phase != .ready || s.indexing != nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let w = KeyboardController.shared.mainWindow, let content = w.contentView else { return }
        let saved = (s.settings.stackBursts, s.settings.groupingMode)
        let savedSize = s.settings.thumbnailSize
        defer { s.settings.stackBursts = saved.0; s.settings.groupingMode = saved.1; s.settings.thumbnailSize = savedSize; s.regroup() }
        s.settings.stackBursts = true; s.settings.groupingMode = .time; s.regroup()
        s.settings.thumbnailSize = 160   // several rows on screen whatever the user's size is
        s.expandAllStacks(false)
        s.viewMode = .grid
        w.setContentSize(NSSize(width: 1300, height: 820))
        try? await Task.sleep(for: .seconds(2))
        func name(_ id: ItemID?) -> String { id.map { ($0 as NSString).lastPathComponent } ?? "nil" }
        func cells(_ v: NSView) -> [ThumbnailCellView] { (v as? ThumbnailCellView).map { [$0] } ?? v.subviews.flatMap(cells) }
        func collection(_ v: NSView) -> NSCollectionView? { (v as? NSCollectionView) ?? v.subviews.lazy.compactMap(collection).first }
        func report(_ label: String, stack sid: String) {
            let members = s.stackMembers[sid] ?? []
            let cv = collection(content)
            let cvSel = cv?.selectionIndexPaths.map { s.display.indices.contains($0.item) ? name(s.display[$0.item].itemID) : "?" } ?? []
            let ringed = cells(content).filter(\.isCurrent).compactMap { $0.item?.id }.map(name)
            Log.session.info("EXPANDTEST \(label, privacy: .public): current=\(name(s.currentID), privacy: .public) inStack=\(members.contains(s.currentID ?? ""), privacy: .public) selection=\(s.selection.map(name).sorted(), privacy: .public) cvSelection=\(cvSel, privacy: .public) ring=\(ringed, privacy: .public) members=\(members.map(name), privacy: .public)")
        }
        // Pick a collapsed stack that is NOT the first entry, select something else first.
        guard let entryIndex = s.display.indices.dropFirst(2).first(where: { s.display[$0].isCollapsedStack }),
              let sid = s.display[entryIndex].stackID else { Log.session.info("EXPANDTEST no stack"); return }
        s.select(s.display[0].itemID)
        try? await Task.sleep(for: .milliseconds(500))
        // Real double-click on that stack's cell.
        let coverID = s.display[entryIndex].itemID
        guard let cell = cells(content).first(where: { $0.item?.id == coverID }) else { Log.session.info("EXPANDTEST cell not visible"); return }
        let r = cell.convert(cell.bounds, to: nil)
        let p = NSPoint(x: r.midX, y: r.midY)
        for clicks in 1...2 {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1) {
                    w.sendEvent(e)
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(800))
        report("after double-click", stack: sid)
        // Collapse again with S, then expand with S from the cover.
        _ = s.perform(KeyMap.Match(action: .toggleStack, advance: false))
        try? await Task.sleep(for: .milliseconds(600))
        report("after S (collapse)", stack: sid)
        _ = s.perform(KeyMap.Match(action: .toggleStack, advance: false))
        try? await Task.sleep(for: .milliseconds(600))
        report("after S (expand)", stack: sid)
        func expectFirst(_ what: String) {
            let first = s.visibleMembers(ofStack: sid).first
            let ok = s.currentID == first && s.selection.contains(first ?? "")
            Log.session.info("EXPANDTEST \(ok ? "ok  " : "FAIL", privacy: .public) \(what, privacy: .public): pointer \(name(s.currentID), privacy: .public), first frame \(name(first), privacy: .public)")
        }
        expectFirst("S expands → pointer on first frame")
        // Badge click with the pointer on another photo.
        s.expandAllStacks(false)
        s.select(s.display[0].itemID)
        s.toggleStack(sid)
        try? await Task.sleep(for: .milliseconds(400))
        expectFirst("badge expands while pointer elsewhere → pointer moves into the stack")
        s.toggleStack(sid)
        let cover = s.display.first { $0.stackID == sid }?.itemID
        Log.session.info("EXPANDTEST \(s.currentID == cover ? "ok  " : "FAIL", privacy: .public) collapse → pointer on cover")

        // Scenario 2: a pick in the middle becomes the cover; expand from the cover.
        let members = s.stackMembers[sid] ?? []
        if members.count >= 3 {
            s.apply(.flag(.pick), toItem: members[2])
            s.expandAllStacks(false)
            try? await Task.sleep(for: .milliseconds(500))
            let cover = s.display.first { $0.stackID == sid }?.itemID
            Log.session.info("EXPANDTEST cover after pick: \(name(cover), privacy: .public)")
            if let cover { s.select(cover) }
            try? await Task.sleep(for: .milliseconds(400))
            _ = s.perform(KeyMap.Match(action: .toggleStack, advance: false))
            try? await Task.sleep(for: .milliseconds(600))
            report("pick-cover, after S (expand)", stack: sid)
            expectFirst("pick cover: expand → pointer on first frame")
            // Scenario 3: same in the loupe (filmstrip).
            s.expandAllStacks(false)
            if let cover { s.select(cover) }
            s.viewMode = .loupe
            // A leftover multi-selection from the grid must not survive the expand.
            s.selection.formUnion(s.display.prefix(3).map(\.itemID))
            try? await Task.sleep(for: .milliseconds(1200))
            func ringX() -> CGFloat? { cells(content).first(where: \.isCurrent).map { $0.convert($0.bounds, to: nil).minX } }
            let before = ringX()
            _ = s.perform(KeyMap.Match(action: .toggleStack, advance: false))
            try? await Task.sleep(for: .milliseconds(800))
            let after = ringX()
            report("loupe, after S (expand)", stack: sid)
            expectFirst("loupe: expand → pointer on first frame")
            let single = s.selection == Set([s.currentID].compactMap { $0 })
            Log.session.info("EXPANDTEST \(single ? "ok  " : "FAIL", privacy: .public) loupe: only the first frame selected (\(s.selection.count, privacy: .public))")
            let still = before != nil && after != nil && abs(before! - after!) < 2
            Log.session.info("EXPANDTEST \(still ? "ok  " : "FAIL", privacy: .public) loupe: strip did not move (x \(before.map { "\($0)" } ?? "nil", privacy: .public) → \(after.map { "\($0)" } ?? "nil", privacy: .public))")
            s.viewMode = .grid
            s.apply(.flag(.none), toItem: members[2])
        }
        Log.session.info("EXPANDTEST done")
    }

    /// `-openFolder <dir> -uiSnapshots`: renders key UI states to Documents/Snapshots for review.
    static func runSnapshots(_ s: FolderSession) async {
        while s.phase != .ready || s.indexing != nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let w = KeyboardController.shared.mainWindow, let content = w.contentView else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func snap(_ name: String) {
            content.layoutSubtreeIfNeeded()
            guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            Log.session.info("SNAP \(name, privacy: .public)")
        }
        w.setContentSize(NSSize(width: 1300, height: 820))
        let savedSize = s.settings.thumbnailSize
        defer { s.settings.thumbnailSize = savedSize }
        s.settings.thumbnailSize = 200   // same layout whatever size the user picked
        s.viewMode = .grid
        try? await Task.sleep(for: .seconds(4))   // thumbnails
        // A few marks to show the badges (undone at the end).
        let ids = s.display.prefix(6).map(\.itemID)
        let cmds: [MarkCommand] = [.flag(.pick), .flag(.reject), .rating(3), .toggleLabel(.red), .note("check focus"), .rating(5)]
        for (id, c) in zip(ids, cmds) { s.apply(c, toItem: id) }
        s.hud = nil
        try? await Task.sleep(for: .milliseconds(600))
        snap("grid")
        w.setContentSize(NSSize(width: 900, height: 640))
        try? await Task.sleep(for: .milliseconds(800))
        snap("grid-small")
        w.setContentSize(NSSize(width: 1300, height: 820))
        try? await Task.sleep(for: .milliseconds(800))
        // Hover on the 3rd cell, pointer over the 4th star.
        func cells(_ v: NSView) -> [ThumbnailCellView] { (v as? ThumbnailCellView).map { [$0] } ?? v.subviews.flatMap(cells) }
        if let cell = cells(content).sorted(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }).dropFirst(2).first(where: { $0.convert($0.bounds, to: nil).maxY > 300 }) {
            let r = cell.convert(cell.bounds, to: nil)
            let p = NSPoint(x: r.maxX - 32, y: r.minY + 24)
            if let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                  context: nil, eventNumber: 0, trackingNumber: 0, userData: nil),
               let move = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                cell.mouseEntered(with: enter)
                cell.mouseMoved(with: move)
            }
            try? await Task.sleep(for: .milliseconds(300))
            snap("grid-hover")
        }
        if let id = ids.dropFirst(2).first { s.select(id) }
        s.apply(.rating(4))
        try? await Task.sleep(for: .milliseconds(250))
        snap("hud")
        try? await Task.sleep(for: .milliseconds(900))
        s.showShortcuts = true
        try? await Task.sleep(for: .milliseconds(500))
        snap("shortcuts")
        s.showShortcuts = false
        s.viewMode = .loupe
        try? await Task.sleep(for: .seconds(2))
        snap("loupe")
        s.viewMode = .grid
        // Pairs without stacks: the RAW card behind each JPG.
        let stacksBefore = s.settings.stackBursts
        s.settings.stackBursts = false
        s.regroup()
        try? await Task.sleep(for: .seconds(2))
        snap("pairs")
        s.settings.stackBursts = stacksBefore
        s.regroup()
        // Separate mode: hover a JPG, its RAW gets the dashed outline.
        let savedMode = s.fileView
        let savedStacks = s.settings.stackBursts
        s.settings.stackBursts = false
        s.setFileView(.both)
        try? await Task.sleep(for: .seconds(4))
        // Select a JPG (its RAW gets the PAIR outline) and hover some other tile: all three states at once.
        if let jpg = cells(content).first(where: { $0.item?.files.primary.kind == .jpeg && $0.partnerName != nil })?.item?.id {
            s.select(jpg)
            try? await Task.sleep(for: .milliseconds(300))
            // Bring the pair on screen (synthetic RAWs sort after the JPGs).
            func collection(_ v: NSView) -> NSCollectionView? { (v as? NSCollectionView) ?? v.subviews.lazy.compactMap(collection).first }
            if let partner = s.partner(of: jpg), let i = s.displayIndex[partner], let cv = collection(content) {
                cv.scrollToItems(at: [IndexPath(item: i, section: 0)], scrollPosition: .centeredVertically)
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
        if let jpgCell = cells(content).first(where: { !$0.isCurrent && !$0.isPartnerHighlighted && $0.item != nil
                                                        && $0.convert($0.bounds, to: nil).maxY > 300 }) {
            let r = jpgCell.convert(jpgCell.bounds, to: nil)
            let p = NSPoint(x: r.midX, y: r.midY)
            if let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                  context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                jpgCell.mouseEntered(with: enter)
            }
            try? await Task.sleep(for: .milliseconds(300))
            let lit = cells(content).filter(\.isPartnerHighlighted).compactMap { $0.item?.fileName }
            Log.session.info("SNAP current \(s.currentItem?.fileName ?? "?", privacy: .public), hovered \(jpgCell.item?.fileName ?? "?", privacy: .public), pair: \(lit, privacy: .public)")
            snap("separate-hover")
            if let exit = NSEvent.enterExitEvent(with: .mouseExited, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                 context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) {
                jpgCell.mouseExited(with: exit)
            }
        }
        s.setFileView(savedMode)
        s.settings.stackBursts = savedStacks
        s.regroup()
        try? await Task.sleep(for: .seconds(2))
        // Guide pages.
        s.app.showGuide = true
        try? await Task.sleep(for: .seconds(1))
        if let sheet = w.attachedSheet, let sc = sheet.contentView {
            func snapSheet(_ n: String) {
                sc.layoutSubtreeIfNeeded()
                if let rep = sc.bitmapImageRepForCachingDisplay(in: sc.bounds) {
                    sc.cacheDisplay(in: sc.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(n + ".png"))
                }
            }
            snapSheet("guide-1")
            for _ in 0..<2 { if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) { sheet.sendEvent(e) } ; try? await Task.sleep(for: .milliseconds(400)) }
            snapSheet("guide-3")
            s.app.showGuide = false
        }
        // Undo the demo marks.
        for _ in 0..<(cmds.count + 1) { s.undo() }
        try? await Task.sleep(for: .milliseconds(1500))
        Log.session.info("SNAP done")
    }

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

    /// Move to Trash + undo/redo. Run on a throwaway folder: phase 1 uses a fake Trash (a temp folder),
    /// phase 2 the real system Trash for one test file, then undoes it.
    static func runTrash(_ s: FolderSession) async {
        func check(_ ok: Bool, _ what: String) {
            Log.session.info("TRASHTEST \(ok ? "ok  " : "FAIL", privacy: .public) \(what, privacy: .public)")
        }
        func exists(_ urls: [URL]) -> Bool { urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } }
        func gone(_ urls: [URL]) -> Bool { urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }
        func waitFor(_ cond: () -> Bool) async { for _ in 0..<50 where !cond() { try? await Task.sleep(for: .milliseconds(100)) } }
        while s.phase != .ready || s.indexing != nil { try? await Task.sleep(for: .milliseconds(100)) }
        let log = s.app.operationLog
        let savedTrasher = log.trasher
        defer { log.trasher = savedTrasher }

        let bin = FileManager.default.temporaryDirectory.appendingPathComponent("FakeTrash-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        log.trasher = { url in
            let dest = bin.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
        let total = s.items.count
        guard let item = s.items[s.display[0].itemID] else { return check(false, "has items") }
        let urls = item.files.allURLs
        check(urls.count >= 2, "first photo has \(urls.count) files (pair)")
        await s.trash([item])
        check(gone(urls), "all files of the photo left the folder")
        check(s.items[item.id] == nil && s.items.count == total - 1, "photo removed from the grid (\(s.items.count)/\(total))")
        check(s.currentID != nil && s.currentID != item.id, "pointer moved to a neighbour")
        check(log.all.last?.kind == .trash, "recorded in Operation History")
        s.undo()
        check(exists(urls), "⌘Z put every file back")
        await waitFor { s.items[item.id] != nil }
        check(s.items[item.id] != nil, "photo back in the grid after undo")
        s.redo()
        check(gone(urls), "⇧⌘Z trashed it again")
        s.undo()
        check(exists(urls), "undo again restores it")
        await waitFor { s.items[item.id] != nil }

        // Rejects: mark two photos rejected, trash only those.
        let two = s.display.prefix(3).dropFirst().compactMap { s.items[$0.itemID] }
        for p in two { s.select(p.id); s.apply(.flag(.reject)) }
        let rejects = s.items.values.filter { $0.metadata.flag == .reject }
        check(rejects.count == two.count, "\(rejects.count) rejects marked")
        await s.trash(rejects)
        check(rejects.allSatisfy { s.items[$0.id] == nil } && s.items.count == total - two.count, "only rejects trashed")
        s.undo()
        check(rejects.allSatisfy { exists($0.files.allURLs) }, "rejects restored")
        await waitFor { s.items.count == total }

        // Real system Trash, one photo; undo must bring it back out of the Trash.
        log.trasher = savedTrasher
        if let last = s.items[s.display.last!.itemID] {
            let lurls = last.files.allURLs
            await s.trash([last])
            let where_ = log.all.last?.entries.map(\.to).joined(separator: ", ") ?? "?"
            check(gone(lurls), "system Trash took the files → \(where_)")
            s.undo()
            check(exists(lurls), "undo from the system Trash restored the files")
        }
        await waitFor { s.items.count == total }
        check(s.items.count == total, "folder back to \(total) photos")
        try? FileManager.default.removeItem(at: bin)
        Log.session.info("TRASHTEST done")
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
        // Marks left by an interrupted earlier run are fine: undo must bring back exactly this state.
        let startMarks = item.metadata
        s.apply(.flag(.pick))
        s.apply(.rating(4))
        s.apply(.toggleLabel(.green))
        check(item.metadata.flag == .pick && item.metadata.rating == 4 && item.metadata.label == (startMarks.label == .green ? .none : .green),
              "in-memory marks applied immediately")
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
        check(item.metadata == startMarks, "undo x3 restores the marks")
        try? await Task.sleep(for: .milliseconds(900))
        check(MetadataStore.read(item.files, recover: false).metadata == startMarks, "undo persisted to disk")

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
