#if DEBUG
import Foundation
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
            s.viewMode = .grid
        }

        if let t = try? RenameTemplate("{date:yyyyMMdd}_{seq:4}_{original}") {
            let plans = s.planRename(Array(s.items(in: .filtered).prefix(3)), template: t, sequenceStart: 1)
            check(plans.count == 3 && plans.allSatisfy { $0.newBaseName.hasPrefix("2026") }, "rename preview: \(plans.map(\.newBaseName))")
        }

        let st = s.app.pipeline.stats
        Log.session.info("SELFTEST stats thumbs=\(st.thumbRequests) gen=\(st.thumbGenerated) previews=\(st.previewRequests) lastPreviewMs=\(st.lastPreviewMs)")
        Log.session.info("SELFTEST \(failures.isEmpty ? "PASS" : "FAILED: \(failures)", privacy: .public)")
    }
}
#endif
