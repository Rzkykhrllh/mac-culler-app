import AppKit
import Observation
import Vision
import CullerKit

/// Everything about the currently open folder: items, stacks, filter/sort, display list, selection, view mode.
@Observable
final class FolderSession {
    enum Phase: Equatable {
        case scanning
        case ready
        case failed(String)
    }

    let folder: URL
    let includeSubfolders: Bool
    @ObservationIgnored unowned let app: AppModel
    @ObservationIgnored private let stopAccessingOnClose: Bool
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var indexTask: Task<Void, Never>?

    var phase: Phase = .scanning
    /// (done, total) while EXIF/XMP is being indexed in the background.
    var indexing: (done: Int, total: Int)?

    // Items
    @ObservationIgnored var items: [ItemID: PhotoItem] = [:] { didSet { partnerIndexValid = false } }
    /// The RAW/JPEG partner index only changes when photos are added, removed or renamed.
    @ObservationIgnored var partnerIndexValid = false
    @ObservationIgnored var partnerIndexMode: FileViewMode?
    @ObservationIgnored var nearbyAnalysisTask: Task<Void, Never>?
    /// True while this session's tab is not the active one: no indexing / analysis in the background.
    @ObservationIgnored var backgroundPaused = false
    /// Photos whose analysis failed (undecodable): not retried in this session.
    @ObservationIgnored var analysisFailed: Set<ItemID> = []
    /// Photos currently marked sharpest-in-stack, so updates only touch the ones that change.
    @ObservationIgnored var sharpestIDs: Set<ItemID> = []
    /// Last time each progress value was published (see `shouldPublishProgress`).
    @ObservationIgnored var progressPublished: [String: Date] = [:]
    /// Bumped whenever the set of items or their order changes (views observing the display list use this).
    var itemsRevision = 0

    // Stacks (display-only grouping)
    @ObservationIgnored var stackMembers: [String: [ItemID]] = [:]
    @ObservationIgnored var stackOf: [ItemID: String] = [:]
    /// folder/basename → items (separate RAW/JPEG modes), for the linked-pair cue.
    @ObservationIgnored var partnerIndex: [String: [ItemID]] = [:]
    var expandedStacks: Set<String> = []

    // Similarity grouping (Vision feature prints)
    @ObservationIgnored var featurePrints: [ItemID: VNFeaturePrintObservation] = [:]
    /// Distances between consecutive photos; reused while only the threshold changes.
    @ObservationIgnored var similarityPrepared: SimilarityGrouper.Prepared?
    @ObservationIgnored var similarityTask: Task<Void, Never>?
    /// (done, total) while feature prints are being computed.
    var similarityProgress: (done: Int, total: Int)?

    // Focus analysis
    @ObservationIgnored var analysisTask: Task<Void, Never>?
    var analysisProgress: (done: Int, total: Int)?
    var showPeaking = false
    var showClipping = false
    /// Short message shown over the photos (e.g. "No face found").
    var toast: String?
    /// Large transient confirmation of a mark (e.g. "★★★", "Pick · 5 photos").
    var hud: MarkHUD?
    /// In-window shortcut sheet (?).
    var showShortcuts = false
    @ObservationIgnored var hudTask: Task<Void, Never>?
    @ObservationIgnored var toastTask: Task<Void, Never>?
    /// Which subject Y zoomed to last, per item (pressing Y again cycles).
    @ObservationIgnored var subjectCycle: [ItemID: Int] = [:]

    // Filter / sort / display
    var filter = FilterState() { didSet { if filter != oldValue { rebuildDisplay() } } }
    var sort = CullerKit.SortOrder() { didSet { if sort != oldValue { rebuildDisplay() } } }
    var display: [DisplayEntry] = []
    @ObservationIgnored var displayIndex: [ItemID: Int] = [:]
    /// Number of items (not entries) that pass the filter.
    var matchingCount = 0
    /// Bumped on every display rebuild — AppKit collection views reload on change.
    var displayRevision = 0
    /// Bumped when cached images become stale (RAW look switched).
    var imageRevision = 0

    // Selection & navigation
    var viewMode: ViewMode = .grid
    var currentID: ItemID? {
        didSet { if oldValue != currentID, isLargeFolder { scheduleNearbyAnalysis() } }
    }
    var selection: Set<ItemID> = []
    /// Direction of the last navigation step, used for prefetching (+1 / -1).
    @ObservationIgnored var lastDirection = 1
    /// Fixed end of a ⇧-extended range selection.
    @ObservationIgnored var selectionAnchor: ItemID?

    // UI state
    var showInfoPanel = false
    var showHistogram = false
    var showFilterBar = false
    /// Filmstrip under loupe / compare (stays visible in full screen unless hidden with ⌥⌘B).
    var showFilmstrip = true
    var editingNote: ItemID?
    var isFullScreen: Bool { app.isFullScreen }
    var compare = CompareState()
    var writeFailures = 0
    var fileOperation: FileOperationProgress?
    @ObservationIgnored var currentCancel: CancelToken?
    var activeSheet: SessionSheet?
    /// Zoom controllers of the visible image views (loupe = slot 0).
    @ObservationIgnored let viewports = ViewportHub()
    /// Columns currently laid out in the grid (for ↑/↓).
    @ObservationIgnored var gridColumns = 1

    /// Picks / rejects in the folder, for the status bar. Kept up to date here so views never have to read
    /// (and observe) every photo — with tens of thousands of photos that alone made the UI stutter.
    var pickCount = 0
    var rejectCount = 0
    @ObservationIgnored private var livePicks = 0
    @ObservationIgnored private var liveRejects = 0

    // Undo
    @ObservationIgnored var undoStack: [UndoAction] = []
    @ObservationIgnored var redoStack: [UndoAction] = []
    var undoRevision = 0

    init(folder: URL, includeSubfolders: Bool, app: AppModel, stopAccessingOnClose: Bool) {
        self.folder = folder
        self.includeSubfolders = includeSubfolders
        self.app = app
        self.stopAccessingOnClose = stopAccessingOnClose
    }

    var settings: AppSettings { app.settings }
    var scanOptions: ScanOptions { ScanOptions(includeSubfolders: includeSubfolders, pairRawWithRaster: fileView.pairs) }
    var fileView: FileViewMode { settings.fileViewMode }

    /// Switches the RAW/JPEG display mode, re-grouping files in place when pairing changes.
    func setFileView(_ mode: FileViewMode) {
        let old = settings.fileViewMode
        guard mode != old else { return }
        settings.fileViewMode = mode
        if mode.pairs != old.pairs {
            Task {
                // Pending marks target the old grouping: write them first.
                await app.writeQueue.flush()
                await refresh()
            }
        } else {
            rebuildStacks()
            rebuildDisplay()
        }
    }

    var currentItem: PhotoItem? { currentID.flatMap { items[$0] } }
    var currentIndex: Int? { currentID.flatMap { displayIndex[$0] } }

    // MARK: Loading

    func load() async {
        phase = .scanning
        let folder = folder, options = scanOptions, index = app.index
        let result = await Task.detached(priority: .userInitiated) { () -> Result<([ItemFiles], [String: ExifInfo], [String: PhotoMetadata]), Error> in
            do {
                let files = try FolderScanner.scan(folder: folder, options: options)
                let exif = index.cachedExif(for: files.map(\.primary))
                let meta = index.cachedMetadata(for: files.map { (id: $0.primary.path, signature: IndexStore.signature(of: $0)) })
                return .success((files, exif, meta))
            } catch {
                return .failure(error)
            }
        }.value

        guard case .success(let (files, exif, meta)) = result else {
            if case .failure(let e) = result {
                Log.session.error("Scan failed for \(folder.path, privacy: .public): \(e.localizedDescription, privacy: .public)")
                phase = .failed(e.localizedDescription)
            }
            return
        }
        Log.session.info("Scanned \(folder.path, privacy: .public): \(files.count) items, \(exif.count) EXIF + \(meta.count) marks from index")
        // Pay the one-time RAW engine start-up now, in the background, not when the first photo is shown.
        if let raw = files.lazy.compactMap(\.raw).first { ImagePipeline.warmUpRaw(with: raw) }
        for f in files {
            let id = f.primary.path
            items[id] = PhotoItem(files: f, metadata: meta[id] ?? .empty, exif: exif[f.primary.path], metadataLoaded: meta[id] != nil)
        }
        restorePendingWrites()
        rebuildStacks()
        rebuildDisplay()
        currentID = display.first?.itemID
        selection = currentID.map { [$0] } ?? []
        phase = .ready
        startWatching()
        backgroundPaused = app.activeTab.session !== self
        indexMissing()
        ensureFeaturePrints()
        ensureAnalysis()
    }

    /// Re-applies metadata whose write never reached disk (e.g. failed on a read-only volume last time).
    private func restorePendingWrites() {
        for p in app.index.pendingWrites(inFolder: folder) {
            guard let item = items[p.itemID] else { continue }
            setMarks(item, p.metadata)
            item.metadataLoaded = true
            enqueueWrite(item)
        }
    }

    /// Background pass reading XMP + EXIF for items the index did not have (spec §7: progressive EXIF filters).
    /// The tab went to the background: stop indexing / analysis so the visible tab gets the machine.
    func pauseBackgroundWork() {
        guard !backgroundPaused else { return }
        backgroundPaused = true
        indexTask?.cancel()
        analysisTask?.cancel()
        similarityTask?.cancel()
        nearbyAnalysisTask?.cancel()
        indexing = nil
    }

    func resumeBackgroundWork() {
        guard backgroundPaused else { return }
        backgroundPaused = false
        guard phase == .ready else { return }
        indexMissing()
        ensureFeaturePrints()
        ensureAnalysis()
    }

    func indexMissing(_ only: [PhotoItem]? = nil) {
        guard !backgroundPaused else { return }
        let todo = (only ?? Array(items.values)).filter { !$0.metadataLoaded || $0.exif == nil }
            .map { (id: $0.id, files: $0.files, needMeta: !$0.metadataLoaded, needExif: $0.exif == nil) }
        guard !todo.isEmpty else { return }
        indexing = (0, todo.count)
        let index = app.index
        let previous = indexTask
        indexTask = Task { [weak self] in
            await previous?.value
            typealias Row = (id: ItemID, files: ItemFiles, meta: MetadataStore.ReadResult?, exif: ExifInfo?, triedExif: Bool)
            var done = 0
            var lastRebuild = Date()
            // Rebuilding the grid while EXIF arrives keeps the order right, but for a huge tree one rebuild is
            // expensive: wait at least 30× its cost between rebuilds so the UI always gets most of the time.
            var rebuildInterval: TimeInterval = 1.5
            let chunk = 64
            var start = 0
            while start < todo.count {
                if Task.isCancelled { return }
                let slice = Array(todo[start..<min(start + chunk, todo.count)])
                start += chunk
                let rows: [Row] = await Task.detached(priority: .utility) {
                    await withTaskGroup(of: Row.self) { g in
                        for t in slice {
                            g.addTask {
                                let m = t.needMeta ? MetadataStore.read(t.files) : nil
                                let e = t.needExif ? ExifReader.read(t.files.primary.url) : nil
                                return (t.id, t.files, m, e, t.needExif)
                            }
                        }
                        var out: [Row] = []
                        for await r in g { out.append(r) }
                        return out
                    }
                }.value
                guard let self else { return }
                var exifRows: [(FileRef, ExifInfo)] = []
                var metaRows: [(id: String, signature: String, metadata: PhotoMetadata)] = []
                for r in rows {
                    guard let item = self.items[r.id] else { continue }
                    if let e = r.exif {
                        item.exif = e
                        exifRows.append((r.files.primary, e))
                    } else if r.triedExif, item.exif == nil {
                        item.exif = ExifInfo()   // unreadable: don't retry forever
                    }
                    if let m = r.meta, !item.metadataLoaded {
                        self.setMarks(item, m.metadata, publish: false)
                        item.metadataLoaded = true
                        if let sc = m.recoveredSidecar { item.files.sidecarURL = sc }
                        metaRows.append((item.id, IndexStore.signature(of: item.files), m.metadata))
                    }
                }
                index.enqueue { [exifRows, metaRows] in
                    $0.storeExif(exifRows)
                    $0.storeMetadata(metaRows)
                }
                done += rows.count
                if self.shouldPublishProgress("index") {
                    self.indexing = (done, todo.count)
                    self.publishFlagCounts()
                }
                if Date().timeIntervalSince(lastRebuild) > rebuildInterval {
                    let t0 = Date()
                    self.rebuildStacks()
                    let t1 = Date()
                    self.rebuildDisplay()
                    lastRebuild = Date()
                    rebuildInterval = max(1.5, lastRebuild.timeIntervalSince(t0) * 30)
                    Log.session.info("PERF rebuild during indexing: stacks \(Int(t1.timeIntervalSince(t0) * 1000)) ms, display \(Int(lastRebuild.timeIntervalSince(t1) * 1000)) ms, \(self.items.count) items, next in \(Int(rebuildInterval)) s")
                }
            }
            self?.indexing = nil
            self?.publishFlagCounts()
            self?.rebuildStacks()
            self?.rebuildDisplay()
        }
    }

    /// Marks need the on-disk values first, otherwise a merge would clear fields that were never loaded.
    func ensureLoaded(_ item: PhotoItem) {
        guard !item.metadataLoaded else { return }
        let r = MetadataStore.read(item.files)
        setMarks(item, r.metadata)
        if let sc = r.recoveredSidecar { item.files.sidecarURL = sc }
        item.metadataLoaded = true
    }

    /// Progress bars update at most twice a second: every published change re-lays out the window, and
    /// a background pass over a big folder produces dozens per second.
    func shouldPublishProgress(_ key: String) -> Bool {
        let now = Date()
        if let last = progressPublished[key], now.timeIntervalSince(last) < 0.5 { return false }
        progressPublished[key] = now
        return true
    }

    /// Every metadata change goes through here so the pick / reject counts stay right.
    /// `publish: false` (background indexing) defers the visible counts to the next `publishFlagCounts()`.
    func setMarks(_ item: PhotoItem, _ m: PhotoMetadata, publish: Bool = true) {
        let old = item.metadata.flag
        item.metadata = m
        guard old != m.flag else { return }
        if old == .pick { livePicks -= 1 } else if old == .reject { liveRejects -= 1 }
        if m.flag == .pick { livePicks += 1 } else if m.flag == .reject { liveRejects += 1 }
        if publish { publishFlagCounts() }
    }

    func publishFlagCounts() {
        if pickCount != livePicks { pickCount = livePicks }
        if rejectCount != liveRejects { rejectCount = liveRejects }
    }

    func recountFlags() {
        var p = 0, r = 0
        for item in items.values {
            switch item.metadata.flag {
            case .pick: p += 1
            case .reject: r += 1
            default: break
            }
        }
        livePicks = p
        liveRejects = r
        publishFlagCounts()
    }

    // MARK: Watching / refresh

    private func startWatching() {
        watcher = FolderWatcher(url: folder) { [weak self] paths in
            let relevant = paths.contains { p in
                let name = (p as NSString).lastPathComponent
                return !name.contains("culler-tmp") && !name.hasPrefix(".culler-rename") && !name.hasPrefix(".")
            }
            guard relevant else { return }
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    func scheduleRefresh(delay: Duration = .milliseconds(800)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Incremental rescan: keeps unchanged items (and their state), re-reads changed files, adds/removes others.
    func refresh() async {
        let folder = folder, options = scanOptions
        guard let scanned = try? await Task.detached(priority: .utility, operation: { try FolderScanner.scan(folder: folder, options: options) }).value else { return }
        let pendingIDs = Set(items.values.filter { $0.writeState == .pending }.map(\.id))
        var next: [ItemID: PhotoItem] = [:]
        var changed: [PhotoItem] = []
        for f in scanned {
            let id = f.primary.path
            if let existing = items[id] {
                if existing.files != f {
                    existing.files = f
                    featurePrints[id] = nil
                    if !pendingIDs.contains(id) {
                        existing.metadataLoaded = false
                        existing.exif = nil
                        changed.append(existing)
                    }
                }
                next[id] = existing
            } else {
                let item = PhotoItem(files: f)
                next[id] = item
                changed.append(item)
            }
        }
        let structureChanged = Set(next.keys) != Set(items.keys)
        items = next
        if let c = currentID, items[c] == nil { currentID = nil }
        selection = selection.filter { items[$0] != nil }
        if structureChanged || !changed.isEmpty {
            rebuildStacks()
            rebuildDisplay()
            if currentID == nil { currentID = display.first?.itemID }
        }
        if !changed.isEmpty { indexMissing(changed) }
        for item in changed { item.analysis = nil }
        ensureFeaturePrints()
        ensureAnalysis()
    }

    // MARK: Writes

    func enqueueWrite(_ item: PhotoItem) {
        item.writeState = .pending
        let id = item.id, files = item.files, m = item.metadata
        app.index.setPending(itemID: id, files: files, metadata: m, error: nil)
        let q = app.writeQueue!
        Task { await q.enqueue(itemID: id, files: files, metadata: m) }
    }

    func handleWriteEvent(_ e: MetadataWriteQueue.Event) {
        switch e {
        case .written(let id, let files, let m):
            app.index.clearPending(itemID: id)
            guard let item = items[id] else { return }
            item.files = files
            if item.metadata == m {
                item.writeState = .saved
                app.index.storeMetadata([(id, IndexStore.signature(of: files), m)])
            }
            writeFailures = items.values.filter { if case .failed = $0.writeState { return true } else { return false } }.count
        case .failed(let id, let m, let msg):
            Log.writes.error("Write failed for \(id, privacy: .public): \(msg, privacy: .public)")
            guard let item = items[id] else { return }
            app.index.setPending(itemID: id, files: item.files, metadata: m, error: msg)
            if item.metadata == m { item.writeState = .failed(msg) }
            writeFailures = items.values.filter { if case .failed = $0.writeState { return true } else { return false } }.count
        }
    }

    func retryFailedWrites() {
        for item in items.values {
            if case .failed = item.writeState { enqueueWrite(item) }
        }
    }

    // MARK: Close

    func close() async {
        similarityTask?.cancel()
        analysisTask?.cancel()
        indexTask?.cancel()
        refreshTask?.cancel()
        watcher?.stop()
        watcher = nil
        await app.writeQueue.flush()
        if stopAccessingOnClose { folder.stopAccessingSecurityScopedResource() }
    }
}

struct FileOperationProgress: Equatable {
    var title: String
    var done: Int
    var total: Int
    var cancellable: Bool
}
