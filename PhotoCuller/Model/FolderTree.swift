import AppKit
import Observation
import CullerKit

/// One folder in the sidebar tree. Children and photo counts load lazily in the background.
@Observable
final class FolderNode: Identifiable, Hashable {
    let url: URL
    let name: String
    let symbol: String
    @ObservationIgnored weak var parent: FolderNode?
    /// nil = not loaded yet.
    private(set) var children: [FolderNode]?
    /// Photos directly inside (RAW+JPEG with the same name count once). nil = not counted yet.
    private(set) var photoCount: Int?
    /// The sandbox does not allow reading this folder yet (click to grant access).
    private(set) var needsAccess = false
    var isExpanded = false
    @ObservationIgnored private var loading = false

    var id: URL { url }

    init(url: URL, name: String? = nil, symbol: String = "folder", parent: FolderNode? = nil) {
        self.url = url.standardizedFileURL
        self.name = name ?? url.lastPathComponent
        self.symbol = symbol
        self.parent = parent
    }

    static func == (a: FolderNode, b: FolderNode) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }

    var hasChildren: Bool { needsAccess || (children.map { !$0.isEmpty } ?? true) }

    /// Lists subfolders + counts photos off the main thread.
    func load(force: Bool = false) async {
        guard !loading, force || children == nil else { return }
        loading = true
        defer { loading = false }
        let url = url
        let isHome = url == AccessGrants.realHome.standardizedFileURL
        let result = await Task.detached(priority: .utility) { () -> ([URL], Int)? in
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey],
                                                            options: [.skipsHiddenFiles]) else { return nil }
            var dirs: [URL] = []
            var bases = Set<String>()
            for e in entries {
                let v = try? e.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey])
                if v?.isDirectory == true, v?.isPackage != true, v?.isHidden != true {
                    if isHome && e.lastPathComponent == "Library" { continue }   // hidden in Finder too
                    dirs.append(e)
                } else if FileKind(pathExtension: e.pathExtension) != nil {
                    bases.insert(e.deletingPathExtension().lastPathComponent)
                }
            }
            dirs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            return (dirs, bases.count)
        }.value
        guard let (dirs, count) = result else {
            needsAccess = true
            children = []
            photoCount = nil
            return
        }
        needsAccess = false
        let old = Dictionary((children ?? []).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        children = dirs.map { old[$0.standardizedFileURL] ?? FolderNode(url: $0, parent: self) }
        photoCount = count
    }

    func reset() {
        children = nil
        needsAccess = false
    }

    /// Depth-first list of this node and its expanded descendants.
    func visibleNodes() -> [FolderNode] {
        [self] + (isExpanded ? (children ?? []).flatMap { $0.visibleNodes() } : [])
    }
}

/// Finder-like sidebar: Favorites (standard folders + pinned), Locations (volumes).
@Observable
final class FolderSidebar {
    private(set) var favorites: [FolderNode] = []
    private(set) var pinned: [FolderNode] = []
    private(set) var locations: [FolderNode] = []
    /// Folder of the active tab, highlighted in the tree.
    var selectedURL: URL?
    @ObservationIgnored let grants = AccessGrants()
    @ObservationIgnored private let pinnedKey = "pinnedFolders"
    @ObservationIgnored private var observers: [Any] = []

    init() {
        let home = AccessGrants.realHome
        favorites = [
            FolderNode(url: home, name: home.lastPathComponent, symbol: "house"),
            FolderNode(url: home.appendingPathComponent("Desktop"), symbol: "menubar.dock.rectangle"),
            FolderNode(url: home.appendingPathComponent("Documents"), symbol: "doc"),
            FolderNode(url: home.appendingPathComponent("Downloads"), symbol: "arrow.down.circle"),
            FolderNode(url: home.appendingPathComponent("Pictures"), symbol: "photo.on.rectangle"),
        ]
        var paths = UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []
        if paths.isEmpty { paths = grants.grantedPaths.filter { p in !favorites.contains { $0.url.path == p } } }
        pinned = paths.map { FolderNode(url: URL(fileURLWithPath: $0), symbol: "star") }
        refreshVolumes()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            })
        }
    }

    var allRoots: [FolderNode] { pinned + favorites + locations }

    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let old = Dictionary(locations.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        locations = urls.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            guard v?.volumeIsBrowsable != false else { return nil }
            let symbol = v?.volumeIsRemovable == true ? "sdcard" : (v?.volumeIsInternal == true ? "internaldrive" : "externaldrive")
            return old[u.standardizedFileURL] ?? FolderNode(url: u, name: v?.volumeLocalizedName ?? u.lastPathComponent, symbol: symbol)
        }
    }

    // MARK: Access

    /// Grants access to a locked node (open panel pointed at it), then reloads it.
    @discardableResult
    func requestAccess(_ node: FolderNode) async -> Bool {
        guard grants.request(node.url) != nil else { return false }
        node.reset()
        await node.load(force: true)
        node.isExpanded = true
        return !node.needsAccess
    }

    /// Makes sure `url` is readable, asking once if needed. Returns false if the user declined.
    func ensureAccess(_ url: URL) -> Bool {
        if AccessGrants.canRead(url) { return true }
        return grants.request(url) != nil && AccessGrants.canRead(url)
    }

    /// A folder picked in an open panel: grant + pin it unless a favorite already covers it.
    func adopt(_ url: URL) {
        grants.add(url)
        guard root(containing: url) == nil else { return }
        pin(url)
    }

    func pin(_ url: URL) {
        let u = url.standardizedFileURL
        guard !pinned.contains(where: { $0.url == u }), !favorites.contains(where: { $0.url == u }) else { return }
        pinned.append(FolderNode(url: u, symbol: "star"))
        savePinned()
    }

    func unpin(_ node: FolderNode) {
        pinned.removeAll { $0 === node }
        savePinned()
    }

    func isPinned(_ url: URL) -> Bool { pinned.contains { $0.url == url.standardizedFileURL } }

    private func savePinned() { UserDefaults.standard.set(pinned.map(\.url.path), forKey: pinnedKey) }

    // MARK: Navigation

    /// The deepest sidebar root containing `url`.
    func root(containing url: URL) -> FolderNode? {
        let p = url.standardizedFileURL.path
        return allRoots
            .filter { p == $0.url.path || p.hasPrefix($0.url.path == "/" ? "/" : $0.url.path + "/") }
            .max { $0.url.path.count < $1.url.path.count }
    }

    /// Expands the tree down to `url` (loading levels as needed) and selects it.
    @discardableResult
    func reveal(_ url: URL) async -> FolderNode? {
        let target = url.standardizedFileURL
        guard var node = root(containing: target) else { selectedURL = target; return nil }
        while node.url != target {
            await node.load()
            node.isExpanded = true
            let prefix = { (n: FolderNode) in target.path == n.url.path || target.path.hasPrefix(n.url.path + "/") }
            guard let next = node.children?.first(where: prefix) else { break }
            node = next
        }
        selectedURL = node.url
        return node
    }

    /// Next / previous folder in the visible tree order (⌥⌘↓ / ⌥⌘↑).
    func neighbour(of url: URL, offset: Int) -> URL? {
        let all = allRoots.flatMap { $0.visibleNodes() }
        guard let i = all.lastIndex(where: { $0.url == url.standardizedFileURL }) else { return nil }
        let j = i + offset
        return all.indices.contains(j) ? all[j].url : nil
    }

    /// Enclosing folder (⌘↑), if it can be read.
    func parentURL(of url: URL) -> URL? {
        let p = url.standardizedFileURL.deletingLastPathComponent()
        guard p.path != url.standardizedFileURL.path else { return nil }
        return p
    }
}
