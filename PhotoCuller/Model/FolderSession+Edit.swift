import AppKit
import CullerKit

/// Crop / straighten (non-destructive, stored with the marks in XMP) and export with border / canvas.
extension FolderSession {
    // MARK: Crop

    /// K: crop the photo in the loupe (opens the loupe from the grid).
    func beginCrop() {
        guard let item = viewMode == .grid ? (markTargets.first ?? currentItem) : currentItem else { return }
        if currentID != item.id { select(item.id) }
        ensureLoaded(item)
        viewMode = .loupe
        viewports.fitAll()
        cropDraft = item.metadata.crop ?? .full
        cropItemID = item.id
        cropEditing = true
    }

    func cancelCrop() {
        cropEditing = false
        cropDraft = nil
        cropItemID = nil
    }

    /// Return / Done: the draft becomes the photo's crop (undoable).
    func commitCrop() {
        defer { cancelCrop() }
        guard let item = cropItemID.flatMap({ items[$0] }), let draft = cropDraft else { return }
        setCrop(draft.isIdentity ? nil : draft, for: [item])
    }

    /// Reset Crop: removes the crop of the photos marks would apply to.
    func resetCrop() {
        let targets = markTargets.filter { $0.metadata.crop != nil }
        guard !targets.isEmpty else { return showToast("No crop to reset") }
        setCrop(nil, for: targets)
    }

    private func setCrop(_ crop: CropSpec?, for targets: [PhotoItem]) {
        var changes: [(id: ItemID, old: PhotoMetadata, new: PhotoMetadata)] = []
        for item in targets {
            ensureLoaded(item)
            var m = item.metadata
            m.crop = crop?.normalized
            if m != item.metadata { changes.append((item.id, item.metadata, m)) }
        }
        guard !changes.isEmpty else { return }
        setMetadata(changes.map { ($0.id, $0.new) })
        pushUndo(.metadata(changes))
        showToast(crop == nil ? (changes.count == 1 ? "Crop removed" : "Crop removed from \(changes.count) photos")
                              : "Cropped · ⌘Z to undo")
    }

    // MARK: Export

    /// ⇧⌘E: the selection (grid), photo / block (loupe).
    func beginExport() {
        guard !markTargets.isEmpty else { return showToast("Select photos to export") }
        exportTargets = markTargets.map(\.id)
        activeSheet = .export
    }

    /// Renders each photo off the main thread (two at a time). `folder` nil = an "Exports" folder next to each photo.
    func export(_ ids: [ItemID], options: ExportOptions, to folder: URL?) async {
        let jobs = ids.compactMap { items[$0] }.map { (files: $0.files, crop: $0.metadata.crop) }
        guard !jobs.isEmpty else { return }
        let cancel = CancelToken()
        currentCancel = cancel
        fileOperation = FileOperationProgress(title: "Exporting", done: 0, total: jobs.count, cancellable: true)
        var written: [URL] = []
        var failures: [String] = []
        var next = 0
        await withTaskGroup(of: (Int, Result<URL, Error>).self) { group in
            func addNext() {
                guard next < jobs.count, !cancel.isCancelled else { return }
                let i = next, job = jobs[i]
                next += 1
                let dest = folder ?? job.files.folder.appendingPathComponent("Exports", isDirectory: true)
                group.addTask {
                    await Offload.run {
                        (i, Result { try PhotoExporter.export(job.files, crop: job.crop, options: options, to: dest) })
                    }
                }
            }
            addNext(); addNext()
            for await (i, r) in group {
                switch r {
                case .success(let u): written.append(u)
                case .failure(let e): failures.append("\(jobs[i].files.primary.fileName): \(e.localizedDescription)")
                }
                fileOperation?.done += 1
                addNext()
            }
        }
        fileOperation = nil
        currentCancel = nil
        lastExports = written
        if !written.isEmpty {
            showToast("Exported \(written.count) photo\(written.count == 1 ? "" : "s") · Photo ▸ Show Last Export")
        }
        if !failures.isEmpty {
            app.alert = AppAlert(title: "\(failures.count) photo\(failures.count == 1 ? "" : "s") could not be exported",
                                 message: failures.prefix(5).joined(separator: "\n"))
        }
    }

    /// Reveal the files of the last export in Finder.
    func revealLastExports() {
        guard !lastExports.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(lastExports)
    }
}

/// The last export options, remembered between exports.
enum ExportSettings {
    private static let key = "export.lastOptions"
    static var last: ExportOptions {
        get {
            guard let d = UserDefaults.standard.data(forKey: key), let o = try? JSONDecoder().decode(ExportOptions.self, from: d) else { return .instagram }
            return o
        }
        set { if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: key) } }
    }
}
