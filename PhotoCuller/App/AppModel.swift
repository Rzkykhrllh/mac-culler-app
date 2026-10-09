import AppKit
import SwiftUI
import Observation
import CullerKit

/// App-wide services, the browser-like tabs and their folder sessions.
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings()
    let pipeline: ImagePipeline
    let index: IndexStore
    let operationLog: OperationLog
    let recentFolders = RecentFolders(key: "recentFolders")
    let recentDestinations = RecentFolders(key: "recentDestinations", limit: 8)
    let sidebar = FolderSidebar()
    var sidebarVisibility: NavigationSplitViewVisibility = .all
    @ObservationIgnored private(set) var writeQueue: MetadataWriteQueue!

    // Tabs
    private(set) var tabs: [WorkspaceTab] = []
    private(set) var activeTabID: UUID {
        didSet {
            guard oldValue != activeTabID else { return }
            // Only the visible tab indexes / analyzes; the others pick up where they left off when shown.
            tabs.first { $0.id == oldValue }?.session?.pauseBackgroundWork()
            activeTab.session?.resumeBackgroundWork()
        }
    }
    @ObservationIgnored private var closedFolders: [URL] = []
    /// Off for DEBUG launches with `-openFolder`, so development runs never replace the user's saved tabs.
    @ObservationIgnored var persistsTabs = true

    /// Incremented whenever the operation log changes so the History window refreshes.
    private(set) var historyRevision = 0
    var alert: AppAlert?
    /// Getting Started guide (shown automatically on first launch).
    var showGuide = !UserDefaults.standard.bool(forKey: "hasSeenGuide")
    func guideClosed() { UserDefaults.standard.set(true, forKey: "hasSeenGuide") }
    /// Caps Lock = auto-advance after marking (spec §9).
    var capsLockOn = NSEvent.modifierFlags.contains(.capsLock)

    private init() {
        let disk = (try? ThumbnailDiskCache.defaultDirectory()).flatMap { try? ThumbnailDiskCache(directory: $0, limitBytes: AppSettings().cacheLimitBytes) }
        pipeline = ImagePipeline(diskCache: disk)
        pipeline.rawRendering = settings.rawRendering
        index = (try? IndexStore.defaultURL()).flatMap { try? IndexStore(url: $0) } ?? (try! IndexStore())
        operationLog = OperationLog(url: (try? OperationLog.defaultURL()) ?? FileManager.default.temporaryDirectory.appendingPathComponent("operations.jsonl"))

        // Restore the tabs of the last launch (folders open lazily when their tab is shown).
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-openFolder") { persistsTabs = false; showGuide = ProcessInfo.processInfo.arguments.contains("-showGuide") }
        #endif
        let paths = persistsTabs ? (UserDefaults.standard.stringArray(forKey: Keys.tabs) ?? []) : []
        var restored = paths.map { WorkspaceTab(pendingFolder: URL(fileURLWithPath: $0)) }
        if restored.isEmpty { restored = [WorkspaceTab()] }
        tabs = restored
        let active = min(max(0, UserDefaults.standard.integer(forKey: Keys.activeTab)), restored.count - 1)
        activeTabID = restored[active].id

        writeQueue = MetadataWriteQueue(options: .init(syncFinderTags: settings.syncFinderTags)) { event in
            Task { @MainActor in
                // Any tab may own the item (the same folder can be open in two tabs).
                for t in AppModel.shared.tabs { t.session?.handleWriteEvent(event) }
            }
        }
        Task.detached(priority: .background) { disk?.trim() }
    }

    private enum Keys {
        static let tabs = "openTabs"
        static let activeTab = "activeTab"
    }

    var activeTab: WorkspaceTab { tabs.first { $0.id == activeTabID } ?? tabs[0] }
    /// The session of the active tab.
    var session: FolderSession? { activeTab.session }

    func applyWriteOptions() {
        let opts = MetadataStore.WriteOptions(syncFinderTags: settings.syncFinderTags)
        Task { await writeQueue.setOptions(opts) }
    }

    /// Switches how RAW files look; the grid / loupe reload their images.
    func setRawRendering(_ r: RawRendering) {
        guard r != settings.rawRendering else { return }
        settings.rawRendering = r
        pipeline.rawRendering = r
        for t in tabs { t.session?.imagesChanged() }
    }

    /// ⇧S: stacks on / off (all tabs).
    func setStackBursts(_ on: Bool) {
        settings.stackBursts = on
        regroupAllTabs()
    }

    var stackChoice: StackChoice {
        guard settings.stackBursts else { return .off }
        return settings.groupingMode == .time ? .bursts : .similar
    }

    func setStackChoice(_ c: StackChoice) {
        settings.stackBursts = c != .off
        if c != .off { settings.groupingMode = c == .bursts ? .time : .similarity }
        regroupAllTabs()
    }

    /// ⌥[ / ⌥]: tighter / looser similarity (smaller / larger distance threshold).
    func adjustSimilarity(_ delta: Double) {
        setSimilarityThreshold(settings.similarityThreshold + delta)
    }

    func setSimilarityThreshold(_ t: Double) {
        settings.similarityThreshold = min(1.0, max(0.1, (t * 100).rounded() / 100))
        for t in tabs where settings.groupingMode == .similarity { t.session?.regroup() }
    }

    private func regroupAllTabs() {
        for t in tabs {
            t.session?.regroup()
            t.session?.ensureFeaturePrints()
        }
    }

    func toggleSidebar() {
        sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
    }

    // MARK: Tabs

    /// Opens the folder of a restored tab the first time it is shown.
    func activateRestoredTabIfNeeded() {
        let tab = activeTab
        if tab.session == nil, let f = tab.pendingFolder {
            open(folder: f, in: tab)
        }
    }

    func selectTab(_ tab: WorkspaceTab) {
        guard tab.id != activeTabID else { return }
        activeTabID = tab.id
        saveTabs()
        activateRestoredTabIfNeeded()
        if let f = tab.folder { Task { await sidebar.reveal(f) } } else { sidebar.selectedURL = nil }
    }

    /// ⌘1…⌘9 (⌘9 = last tab, like browsers).
    func selectTab(number n: Int) {
        guard !tabs.isEmpty else { return }
        let i = n == 9 ? tabs.count - 1 : n - 1
        guard tabs.indices.contains(i) else { NSSound.beep(); return }
        selectTab(tabs[i])
    }

    /// ⌃Tab / ⌃⇧Tab.
    func cycleTab(_ offset: Int) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        selectTab(tabs[(i + offset + tabs.count) % tabs.count])
    }

    /// ⌘T: new tab, optionally showing a folder.
    @discardableResult
    func newTab(folder: URL? = nil) -> WorkspaceTab {
        let tab = WorkspaceTab()
        let i = tabs.firstIndex(where: { $0.id == activeTabID }).map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: i)
        activeTabID = tab.id
        sidebar.selectedURL = nil
        if let folder { open(folder: folder, in: tab) }
        saveTabs()
        return tab
    }

    /// ⌘W: close a tab (the last one turns into an empty tab).
    func closeTab(_ tab: WorkspaceTab? = nil) {
        let tab = tab ?? activeTab
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if let f = tab.folder { closedFolders.append(f) }
        let s = tab.session
        tab.session = nil
        Task { await s?.close() }
        if tabs.count == 1 {
            tabs[0] = WorkspaceTab()
            activeTabID = tabs[0].id
            sidebar.selectedURL = nil
        } else {
            tabs.remove(at: i)
            if tab.id == activeTabID {
                activeTabID = tabs[min(i, tabs.count - 1)].id
                activateRestoredTabIfNeeded()
                if let f = activeTab.folder { Task { await sidebar.reveal(f) } }
            }
        }
        saveTabs()
    }

    /// ⇧⌘T: reopen the last closed tab.
    func reopenClosedTab() {
        guard let f = closedFolders.popLast() else { NSSound.beep(); return }
        newTab(folder: f)
    }

    func moveTab(_ tab: WorkspaceTab, before target: WorkspaceTab) {
        guard tab.id != target.id, let from = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let t = tabs.remove(at: from)
        let to = tabs.firstIndex(where: { $0.id == target.id }) ?? tabs.count
        tabs.insert(t, at: to)
        saveTabs()
    }

    private func saveTabs() {
        guard persistsTabs else { return }
        UserDefaults.standard.set(tabs.compactMap { $0.folder?.path }, forKey: Keys.tabs)
        let withFolder = tabs.filter { $0.folder != nil }
        UserDefaults.standard.set(withFolder.firstIndex { $0.id == activeTabID } ?? 0, forKey: Keys.activeTab)
    }

    // MARK: Folder lifecycle

    func showOpenPanel(newTab: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of photos to cull"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sidebar.adopt(url)
        if newTab { self.newTab(folder: url) } else { open(folder: url) }
    }

    /// Opens a folder from the sidebar / path bar in the active tab (or a new one).
    func openFromSidebar(_ url: URL, newTab: Bool = false) {
        if newTab { self.newTab(folder: url); return }
        guard url.standardizedFileURL != session?.folder.standardizedFileURL else { return }
        open(folder: url)
    }

    /// ⌥⌘↓ / ⌥⌘↑: next / previous folder in the sidebar tree.
    func openNeighbourFolder(_ offset: Int) {
        guard let cur = session?.folder, let next = sidebar.neighbour(of: cur, offset: offset) else { NSSound.beep(); return }
        openFromSidebar(next)
    }

    /// ⌘↑: enclosing folder.
    func openParentFolder() {
        guard let cur = session?.folder, let p = sidebar.parentURL(of: cur) else { NSSound.beep(); return }
        openFromSidebar(p)
    }

    func open(recent entry: RecentFolders.Entry) {
        guard let url = recentFolders.resolve(entry) else {
            alert = AppAlert(title: "Folder unavailable",
                             message: "“\(entry.name)” can no longer be opened. It may have been moved, renamed or its disk is not connected. Please choose it again.")
            return
        }
        // Keep the bookmark's scope open for the app's lifetime and remember it as a grant.
        if !sidebar.grants.covers(url), url.startAccessingSecurityScopedResource() { sidebar.adopt(url) }
        open(folder: url)
    }

    /// Opens `url` in the active tab.
    func open(folder url: URL, securityScoped: Bool = false, includeSubfolders: Bool? = nil) {
        open(folder: url, in: activeTab, includeSubfolders: includeSubfolders)
    }

    func open(folder url: URL, in tab: WorkspaceTab, includeSubfolders: Bool? = nil) {
        Task {
            // Inside the sandbox a folder must be granted once; ask right away if needed.
            guard sidebar.ensureAccess(url) else { return }
            let subfolders = includeSubfolders ?? settings.includeSubfoldersByDefault
            if subfolders {
                let limit = settings.subfolderWarningThreshold
                let count = await Task.detached { FolderScanner.countImages(folder: url, includeSubfolders: true, stopAfter: limit) }.value
                #if DEBUG
                let skipConfirm = ProcessInfo.processInfo.arguments.contains("-subfolders")
                #else
                let skipConfirm = false
                #endif
                if count > limit, !skipConfirm, !confirmLargeScan(url: url, limit: limit) { return }
            }
            if let old = tab.session {
                tab.session = nil
                await old.close()
            }
            tab.pendingFolder = nil
            Log.session.info("Opening \(url.path, privacy: .public) (subfolders: \(subfolders))")
            recentFolders.add(url)
            let s = FolderSession(folder: url, includeSubfolders: subfolders, app: self, stopAccessingOnClose: false)
            tab.session = s
            saveTabs()
            if tab.id == activeTabID { Task { await sidebar.reveal(url) } }
            await s.load()
        }
    }

    private func confirmLargeScan(url: URL, limit: Int) -> Bool {
        let a = NSAlert()
        a.messageText = "This folder tree contains more than \(limit.formatted()) photos"
        a.informativeText = "Scanning “\(url.lastPathComponent)” with subfolders may take a while and use more memory. Continue?"
        a.addButton(withTitle: "Continue")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Closes the folder of the active tab (the tab stays, empty).
    func closeSession() async {
        let tab = activeTab
        guard let s = tab.session else { return }
        tab.session = nil
        await s.close()
        saveTabs()
    }

    func reopenCurrent(includeSubfolders: Bool? = nil) {
        guard let s = session else { return }
        open(folder: s.folder, includeSubfolders: includeSubfolders ?? s.includeSubfolders)
    }

    /// Called from `applicationShouldTerminate`: writes everything still pending.
    func flushBeforeQuit() async {
        saveTabs()
        await writeQueue.flush()
    }

    func historyChanged() { historyRevision += 1 }

    func clearCaches() {
        pipeline.clearMemory()
        pipeline.diskCache?.clear()
        index.removeAll()
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}
