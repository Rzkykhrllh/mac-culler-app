import Foundation
import Vision
import CullerKit

extension FolderSession {
    /// Makes sure every shown photo has a feature print when grouping by similarity: cached ones come from the
    /// index, the rest are computed in the background (≈130 photos/s on an M2) and regrouped as they arrive.
    func ensureFeaturePrints() {
        guard settings.stackBursts, settings.groupingMode == .similarity, phase == .ready, similarityTask == nil else { return }
        let mode = fileView
        let missing = items.values.filter { featurePrints[$0.id] == nil && mode.shows($0.files) }
            .sorted { $0.captureDate < $1.captureDate }
            .map { (id: $0.id, files: $0.files) }
        guard !missing.isEmpty else { return }
        let index = app.index, pipeline = app.pipeline
        similarityProgress = (0, missing.count)
        similarityTask = Task { [weak self] in
            defer { self?.similarityTask = nil; self?.similarityProgress = nil }
            // 1. Cached prints (keyed by the primary file's path + size + mtime).
            let cached = await Task.detached(priority: .utility) { index.cachedFeaturePrints(for: missing.map(\.files.primary)) }.value
            guard let self else { return }
            var todo: [(id: ItemID, files: ItemFiles)] = []
            for m in missing {
                if let d = cached[m.files.primary.path], let o = FeaturePrints.observation(from: d) {
                    self.featurePrints[m.id] = o
                } else {
                    todo.append(m)
                }
            }
            var done = missing.count - todo.count
            self.similarityProgress = (done, missing.count)
            self.regroup()

            // 2. Compute the rest in chunks: thumbnails (async, from the grid cache) → prints (Vision, off the main thread).
            var lastRegroup = Date()
            var start = 0
            while start < todo.count {
                if Task.isCancelled { return }
                let chunk = Array(todo[start..<min(start + 24, todo.count)])
                start += chunk.count
                let images: [(Int, CGImage)] = await withTaskGroup(of: (Int, CGImage)?.self) { g in
                    for (i, m) in chunk.enumerated() { g.addTask { await pipeline.analysisThumbnail(for: m.files).map { (i, $0) } } }
                    var out: [(Int, CGImage)] = []
                    for await r in g { if let r { out.append(r) } }
                    return out
                }
                let prints: [(Int, Data)] = await withTaskGroup(of: (Int, Data)?.self) { g in
                    for (i, img) in images { g.addTask { await Offload.run { FeaturePrints.compute(from: img).map { (i, $0) } } } }
                    var out: [(Int, Data)] = []
                    for await r in g { if let r { out.append(r) } }
                    return out
                }
                if Task.isCancelled { return }
                var stored: [(FileRef, Data)] = []
                for (i, d) in prints {
                    guard let o = FeaturePrints.observation(from: d) else { continue }
                    self.featurePrints[chunk[i].id] = o
                    stored.append((chunk[i].files.primary, d))
                }
                Task.detached(priority: .background) { index.storeFeaturePrints(stored) }
                done += chunk.count
                if self.shouldPublishProgress("similarity") { self.similarityProgress = (done, missing.count) }
                if Date().timeIntervalSince(lastRegroup) > 1.5 {
                    lastRegroup = Date()
                    self.regroup()
                }
            }
            self.regroup()
        }
    }
}
