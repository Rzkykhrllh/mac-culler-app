import AppKit
import CullerKit

extension FolderSession {
    enum OperationScope: String, CaseIterable, Identifiable {
        case selected = "Selected Photos"
        case filtered = "All Photos in View"
        var id: String { rawValue }
    }

    /// Items in display order for a scope. Collapsed stacks contribute all their (matching) members.
    func items(in scope: OperationScope) -> [PhotoItem] {
        var ids: [ItemID] = []
        switch scope {
        case .selected:
            let sel = selection.isEmpty ? Set(currentID.map { [$0] } ?? []) : selection
            for e in display where sel.contains(e.itemID) {
                if e.isCollapsedStack, let sid = e.stackID { ids += visibleMembers(ofStack: sid) } else { ids.append(e.itemID) }
            }
        case .filtered:
            for e in display {
                if e.isCollapsedStack, let sid = e.stackID { ids += visibleMembers(ofStack: sid) } else { ids.append(e.itemID) }
            }
        }
        var seen = Set<ItemID>()
        return ids.filter { seen.insert($0).inserted }.compactMap { items[$0] }
    }

    func renameContext(_ item: PhotoItem) -> RenameTemplate.Context {
        RenameTemplate.Context(originalBaseName: item.files.baseName,
                               captureDate: item.exif?.captureDate ?? item.files.primary.modificationDate,
                               timeZone: item.exif?.captureTimeZone ?? .current,
                               camera: item.exif?.cameraName, lens: item.exif?.lens, rating: item.metadata.rating)
    }

    func planRename(_ items: [PhotoItem], template: RenameTemplate, sequenceStart: Int) -> [ItemPlan] {
        FileOperations.planRename(items.map { .init(itemID: $0.id, files: $0.files, context: renameContext($0)) },
                                  template: template, sequenceStart: sequenceStart)
    }

    // MARK: Rename

    func executeRename(_ plans: [ItemPlan]) async -> String? {
        await app.writeQueue.flush()
        let result = await Task.detached(priority: .userInitiated) { () -> Result<[ItemPlan], Error> in
            Result { try FileOperations.executeRename(plans) }
        }.value
        switch result {
        case .failure(let e):
            return "Rename failed, nothing was changed: \(e.localizedDescription)"
        case .success(let done):
            guard !done.isEmpty else { return nil }
            let record = OperationRecord.make(kind: .rename, plans: done, folderBookmarks: [Bookmarks.make(for: folder)].compactMap { $0 })
            app.operationLog.record(record)
            app.historyChanged()
            applyRenamed(done)
            pushUndo(.fileOperation(record.id))
            return nil
        }
    }

    /// Updates items in place after a rename so marks, selection and stacks survive without a rescan.
    func applyRenamed(_ plans: [ItemPlan]) {
        var renamedIDs: [ItemID: ItemID] = [:]
        for p in plans {
            guard let item = items.removeValue(forKey: p.itemID) else { continue }
            let map = Dictionary(p.moves.map { ($0.from.standardizedFileURL.path, $0.to) }, uniquingKeysWith: { a, _ in a })
            var files = item.files
            files.files = files.files.map { f in
                var g = f
                if let to = map[f.url.standardizedFileURL.path] { g.url = to }
                return g
            }
            if let sc = files.sidecarURL, let to = map[sc.standardizedFileURL.path] { files.sidecarURL = to }
            item.files = ItemFiles(files: files.files, sidecarURL: files.sidecarURL)
            items[item.id] = item
            renamedIDs[p.itemID] = item.id
        }
        if let c = currentID, let n = renamedIDs[c] { currentID = n }
        selection = Set(selection.map { renamedIDs[$0] ?? $0 })
        compare.slots = compare.slots.map { $0.map { renamedIDs[$0] ?? $0 } }
        compare.candidates = compare.candidates.map { renamedIDs[$0] ?? $0 }
        rebuildStacks()
        rebuildDisplay()
        scheduleRefresh(delay: .milliseconds(300))
    }

    // MARK: Move / copy

    func executeTransfer(_ plans: [ItemPlan], mode: TransferMode, destination: URL) async -> FileOperations.TransferResult {
        await app.writeQueue.flush()
        let cancel = CancelToken()
        fileOperation = FileOperationProgress(title: mode == .move ? "Moving…" : "Copying…", done: 0, total: plans.count, cancellable: true)
        currentCancel = cancel
        let result = await Task.detached(priority: .userInitiated) {
            FileOperations.executeTransfer(plans, mode: mode, isCancelled: { cancel.isCancelled }) { done, total in
                Task { @MainActor in AppModel.shared.session?.fileOperation?.done = done }
            }
        }.value
        fileOperation = nil
        currentCancel = nil

        if !result.completed.isEmpty {
            let bookmarks = [Bookmarks.make(for: folder), Bookmarks.make(for: destination)].compactMap { $0 }
            let record = OperationRecord.make(kind: mode == .move ? .move : .copy, plans: result.completed, folderBookmarks: bookmarks)
            app.operationLog.record(record)
            app.historyChanged()
            pushUndo(.fileOperation(record.id))
            if mode == .move, !isInsideFolder(destination) {
                let gone = Set(result.completed.map(\.itemID))
                let oldIndex = currentIndex
                for id in gone { items[id] = nil }
                selection.subtract(gone)
                compare.slots = compare.slots.map { $0.flatMap { gone.contains($0) ? nil : $0 } }
                compare.candidates.removeAll { gone.contains($0) }
                if let c = currentID, gone.contains(c) { currentID = nil }
                rebuildStacks()
                rebuildDisplay()
                if currentID == nil || gone.contains(currentID ?? ""), let oldIndex, !display.isEmpty {
                    currentID = display[min(oldIndex, display.count - 1)].itemID
                    selection = [currentID!]
                }
            }
            scheduleRefresh(delay: .milliseconds(300))
        }
        return result
    }

    func cancelFileOperation() { currentCancel?.cancel() }

    private func isInsideFolder(_ url: URL) -> Bool {
        let a = url.standardizedFileURL.path, f = folder.standardizedFileURL.path
        return includeSubfolders ? (a == f || a.hasPrefix(f + "/")) : a == f
    }

    // MARK: Undo of file operations

    /// Undoes a logged operation. Shows the refusal reason when files changed since (never guesses).
    @discardableResult
    func undoFileOperation(_ id: UUID) -> Bool {
        guard let rec = app.operationLog.all.first(where: { $0.id == id }) else { return false }
        return Self.perform(rec, undo: true, log: app.operationLog) { [weak self] in
            self?.app.historyChanged()
            self?.scheduleRefresh(delay: .milliseconds(200))
        }
    }

    @discardableResult
    func redoFileOperation(_ id: UUID) -> Bool {
        guard let rec = app.operationLog.all.first(where: { $0.id == id }) else { return false }
        return Self.perform(rec, undo: false, log: app.operationLog) { [weak self] in
            self?.app.historyChanged()
            self?.scheduleRefresh(delay: .milliseconds(200))
        }
    }

    /// Shared by ⌘Z and the History window. Resolves the record's folder bookmarks for sandbox access.
    @discardableResult
    static func perform(_ rec: OperationRecord, undo: Bool, log: OperationLog, completion: () -> Void) -> Bool {
        let scoped = rec.folderBookmarks.compactMap { Bookmarks.resolve($0)?.url }
        let started = scoped.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer { for (u, ok) in started where ok { u.stopAccessingSecurityScopedResource() } }
        do {
            if undo { try log.undo(rec) } else { try log.redo(rec) }
            completion()
            return true
        } catch {
            let a = NSAlert()
            a.messageText = undo ? "Can’t undo “\(rec.summary)”" : "Can’t redo “\(rec.summary)”"
            a.informativeText = error.localizedDescription
            a.runModal()
            return false
        }
    }
}

nonisolated final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.withLock { flag = true } }
    var isCancelled: Bool { lock.withLock { flag } }
}
