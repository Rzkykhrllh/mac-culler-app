import AppKit
import SwiftUI
import Observation
import CullerKit

/// App-wide services and the currently open folder session.
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

    func toggleSidebar() {
        sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
    }
    @ObservationIgnored private(set) var writeQueue: MetadataWriteQueue!

    private(set) var session: FolderSession?
    /// Incremented whenever the operation log changes so the History window refreshes.
    private(set) var historyRevision = 0
    var alert: AppAlert?
    /// Caps Lock = auto-advance after marking (spec §9).
    var capsLockOn = NSEvent.modifierFlags.contains(.capsLock)

    private init() {
        let disk = (try? ThumbnailDiskCache.defaultDirectory()).flatMap { try? ThumbnailDiskCache(directory: $0, limitBytes: AppSettings().cacheLimitBytes) }
        pipeline = ImagePipeline(diskCache: disk)
        index = (try? IndexStore.defaultURL()).flatMap { try? IndexStore(url: $0) } ?? (try! IndexStore())
        operationLog = OperationLog(url: (try? OperationLog.defaultURL()) ?? FileManager.default.temporaryDirectory.appendingPathComponent("operations.jsonl"))
        writeQueue = MetadataWriteQueue(options: .init(syncFinderTags: settings.syncFinderTags)) { event in
            Task { @MainActor in AppModel.shared.session?.handleWriteEvent(event) }
        }
        Task.detached(priority: .background) { disk?.trim() }
    }

    func applyWriteOptions() {
        let opts = MetadataStore.WriteOptions(syncFinderTags: settings.syncFinderTags)
        Task { await writeQueue.setOptions(opts) }
    }

    // MARK: Folder lifecycle

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder of photos to cull"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recentFolders.add(url)
        sidebar.add(url)
        open(folder: url, securityScoped: false)
    }

    /// Opens a folder from the sidebar tree (its root keeps the sandbox access open).
    func openFromSidebar(_ url: URL) {
        guard url.standardizedFileURL != session?.folder.standardizedFileURL else { return }
        recentFolders.add(url)
        open(folder: url, securityScoped: false)
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
        recentFolders.add(url)
        // Pin it in the sidebar; the scope stays open for the app's lifetime like other sidebar roots.
        if sidebar.root(containing: url) == nil, url.startAccessingSecurityScopedResource() {
            sidebar.add(url)
        }
        open(folder: url, securityScoped: true)
    }

    func open(folder url: URL, securityScoped: Bool, includeSubfolders: Bool? = nil) {
        Task {
            await closeSession()
            let subfolders = includeSubfolders ?? settings.includeSubfoldersByDefault
            if subfolders {
                let limit = settings.subfolderWarningThreshold
                let count = await Task.detached { FolderScanner.countImages(folder: url, includeSubfolders: true, stopAfter: limit) }.value
                if count > limit, !confirmLargeScan(url: url, limit: limit) {
                    return
                }
            }
            Log.session.info("Opening \(url.path, privacy: .public) (subfolders: \(subfolders))")
            let accessing = securityScoped && sidebar.root(containing: url) == nil ? url.startAccessingSecurityScopedResource() : false
            let s = FolderSession(folder: url, includeSubfolders: subfolders, app: self, stopAccessingOnClose: accessing)
            session = s
            Task { await sidebar.reveal(url) }
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

    func closeSession() async {
        guard let s = session else { return }
        await s.close()
        session = nil
    }

    func reopenCurrent(includeSubfolders: Bool? = nil) {
        guard let s = session else { return }
        open(folder: s.folder, securityScoped: false, includeSubfolders: includeSubfolders ?? s.includeSubfolders)
    }

    /// Called from `applicationShouldTerminate`: writes everything still pending.
    func flushBeforeQuit() async {
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
