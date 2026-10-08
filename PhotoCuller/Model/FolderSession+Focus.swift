import AppKit
import CullerKit

extension FolderSession {
    // MARK: Background analysis (faces / animals + sharpness)

    /// Analyzes every shown photo once (≈175 ms each, 3 in parallel; cached in the index by file attributes).
    func ensureAnalysis() {
        guard phase == .ready, analysisTask == nil else { return }
        let mode = fileView
        let missing = items.values.filter { $0.analysis == nil && mode.shows($0.files) }
            .sorted { $0.captureDate < $1.captureDate }
            .map { (id: $0.id, files: $0.files) }
        guard !missing.isEmpty else { return }
        let index = app.index, pipeline = app.pipeline
        analysisProgress = (0, missing.count)
        analysisTask = Task { [weak self] in
            defer { self?.analysisTask = nil; self?.analysisProgress = nil }
            let cached = await Task.detached(priority: .utility) { index.cachedAnalysis(for: missing.map(\.files.primary)) }.value
            guard let self else { return }
            var todo: [(id: ItemID, files: ItemFiles)] = []
            for m in missing {
                if let a = cached[m.files.primary.path] { self.items[m.id]?.analysis = a } else { todo.append(m) }
            }
            var done = missing.count - todo.count
            self.analysisProgress = (done, missing.count)
            self.updateSharpest()
            var last = Date()
            var start = 0
            while start < todo.count {
                if Task.isCancelled { return }
                let chunk = Array(todo[start..<min(start + 12, todo.count)])
                start += chunk.count
                let results: [(Int, PhotoAnalysis)] = await withTaskGroup(of: (Int, PhotoAnalysis)?.self) { g in
                    for (i, m) in chunk.enumerated() {
                        g.addTask {
                            guard let img = await pipeline.analysisImage(for: m.files) else { return nil }
                            return await Offload.run { (i, FocusAnalyzer.analyze(img)) }
                        }
                    }
                    var out: [(Int, PhotoAnalysis)] = []
                    for await r in g { if let r { out.append(r) } }
                    return out
                }
                if Task.isCancelled { return }
                var stored: [(FileRef, PhotoAnalysis)] = []
                for (i, a) in results {
                    self.items[chunk[i].id]?.analysis = a
                    stored.append((chunk[i].files.primary, a))
                }
                Task.detached(priority: .background) { index.storeAnalysis(stored) }
                done += chunk.count
                self.analysisProgress = (done, missing.count)
                if Date().timeIntervalSince(last) > 1.5 { last = Date(); self.updateSharpest() }
            }
            self.updateSharpest()
        }
    }

    /// Marks the sharpest frame of every stack (once the whole stack is analyzed).
    func updateSharpest() {
        var byID: [String: PhotoAnalysis] = [:]
        for members in stackMembers.values { for id in members { if let a = items[id]?.analysis { byID[id] = a } } }
        let best = FocusAnalyzer.sharpest(in: Array(stackMembers.values), analysis: byID)
        for item in items.values {
            let v = best.contains(item.id)
            if item.isSharpestInStack != v { item.isSharpestInStack = v }
        }
    }

    // MARK: B — sharpest in stack

    func goToSharpest() {
        if viewMode == .compare {
            let candidates = compare.candidates.compactMap { items[$0] }
            guard let best = candidates.filter({ $0.analysis != nil }).max(by: { $0.analysis!.sharpness < $1.analysis!.sharpness }) else {
                return showToast("Still analyzing sharpness…")
            }
            putInActiveSlot(best.id)
            return
        }
        guard let cur = currentID, let sid = stackOf[cur], let members = stackMembers[sid] else {
            return showToast("Not in a stack")
        }
        let analysed = members.compactMap { items[$0] }.filter { $0.analysis != nil }
        guard analysed.count == members.count, let best = analysed.max(by: { ($0.analysis!.sharpness, $0.analysis!.energy) < ($1.analysis!.sharpness, $1.analysis!.energy) }) else {
            return showToast("Still analyzing sharpness…")
        }
        if !expandedStacks.contains(sid) { toggleStack(sid) }
        select(best.id)
    }

    // MARK: Y — zoom to eyes / face / animal

    /// 100% zoom on the subject of the shown photo(s); in compare every slot zooms to its own subject.
    func zoomToSubject() {
        let targets: [(slot: Int, item: PhotoItem)]
        switch viewMode {
        case .grid: return
        case .loupe: targets = currentItem.map { [(0, $0)] } ?? []
        case .compare: targets = compare.slots.enumerated().compactMap { i, id in id.flatMap { items[$0] }.map { (i, $0) } }
        }
        guard !targets.isEmpty else { return }
        Task {
            var centers: [Int: CGPoint] = [:]
            for t in targets {
                let analysis: PhotoAnalysis?
                if let a = t.item.analysis {
                    analysis = a
                } else if let img = await app.pipeline.analysisImage(for: t.item.files) {
                    let a = await Offload.run { FocusAnalyzer.analyze(img) }
                    t.item.analysis = a
                    analysis = a
                } else {
                    analysis = nil
                }
                guard let subjects = analysis?.subjects, !subjects.isEmpty else { continue }
                // Pressing Y again moves to the next subject.
                let zoomed = viewports.view(slot: t.slot).map { !$0.isFit } ?? false
                let n = zoomed ? ((subjectCycle[t.item.id] ?? -1) + 1) % subjects.count : 0
                subjectCycle[t.item.id] = n
                centers[t.slot] = subjects[n].focusPoint
            }
            guard !centers.isEmpty else { return showToast("No face, eyes or animal found") }
            let active = viewMode == .compare ? compare.active : 0
            viewports.focus(on: centers, active: active, zoom: 1)
            if centers.count < targets.count { showToast("No subject found in \(targets.count - centers.count) photo\(targets.count - centers.count == 1 ? "" : "s")") }
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
