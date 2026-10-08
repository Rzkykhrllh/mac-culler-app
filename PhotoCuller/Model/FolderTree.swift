import Foundation
import Observation
import CullerKit

/// One folder in the sidebar tree. Children and photo counts load lazily in the background.
@Observable
final class FolderNode: Identifiable, Hashable {
    let url: URL
    let name: String
    @ObservationIgnored weak var parent: FolderNode?
    /// nil = not loaded yet.
    private(set) var children: [FolderNode]?
    /// Photos directly inside (RAW+JPEG with the same name count once). nil = not counted yet.
    private(set) var photoCount: Int?
    var isExpanded = false
    @ObservationIgnored private var loading = false

    var id: URL { url }

    init(url: URL, parent: FolderNode? = nil) {
        self.url = url.standardizedFileURL
        name = url.lastPathComponent
        self.parent = parent
    }

    static func == (a: FolderNode, b: FolderNode) -> Bool { a === b }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }

    var hasChildren: Bool { children.map { !$0.isEmpty } ?? true }

    /// Lists subfolders + counts photos off the main thread.
    func load(force: Bool = false) async {
        guard !loading, force || children == nil || photoCount == nil else { return }
        loading = true
        defer { loading = false }
        let url = url
        let (dirs, count) = await Task.detached(priority: .utility) { () -> ([URL], Int) in
            let fm = FileManager.default
            let entries = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                       options: [.skipsHiddenFiles])) ?? []
            var dirs: [URL] = []
            var bases = Set<String>()
            for e in entries {
                let v = try? e.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                if v?.isDirectory == true, v?.isPackage != true {
                    dirs.append(e)
                } else if FileKind(pathExtension: e.pathExtension) != nil {
                    bases.insert(e.deletingPathExtension().lastPathComponent)
                }
            }
            dirs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            return (dirs, bases.count)
        }.value
        let old = Dictionary((children ?? []).map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        children = dirs.map { old[$0.standardizedFileURL] ?? FolderNode(url: $0, parent: self) }
        photoCount = count
    }

    /// Depth-first list of this node and its expanded descendants.
    func visibleNodes() -> [FolderNode] {
        [self] + (isExpanded ? (children ?? []).flatMap { $0.visibleNodes() } : [])
    }
}

/// Folders pinned in the sidebar. Their security scope stays open for the app's lifetime,
/// so any subfolder can be opened with one click inside the sandbox (spec §11).
@Observable
final class FolderSidebar {
    private(set) var roots: [FolderNode] = []
    /// Folder of the open session, highlighted in the tree.
    var selectedURL: URL?
    @ObservationIgnored private let store = RecentFolders(key: "sidebarRoots", limit: 100)
    @ObservationIgnored private var scoped: [URL] = []

    init() {
        for e in store.entries {
            guard let url = store.resolve(e) else { continue }
            if url.startAccessingSecurityScopedResource() { scoped.append(url) }
            roots.append(FolderNode(url: url))
        }
        roots.first?.isExpanded = true
    }

    func root(containing url: URL) -> FolderNode? {
        let p = url.standardizedFileURL.path
        return roots.first { p == $0.url.path || p.hasPrefix($0.url.path + "/") }
    }

    /// Adds a folder chosen in an open panel (its access grant is live right now). No-op if already covered.
    func add(_ url: URL) {
        guard root(containing: url) == nil else { return }
        store.add(url)
        roots.append(FolderNode(url: url))
        roots.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func remove(_ node: FolderNode) {
        store.remove(path: node.url.path)
        roots.removeAll { $0 === node }
        if let i = scoped.firstIndex(of: node.url) {
            scoped[i].stopAccessingSecurityScopedResource()
            scoped.remove(at: i)
        }
    }

    /// Expands the tree down to `url` (loading levels as needed) and returns its node.
    @discardableResult
    func reveal(_ url: URL) async -> FolderNode? {
        let target = url.standardizedFileURL
        guard var node = root(containing: target) else { return nil }
        while node.url != target {
            await node.load()
            node.isExpanded = true
            guard let next = node.children?.first(where: { target.path == $0.url.path || target.path.hasPrefix($0.url.path + "/") }) else { break }
            node = next
        }
        selectedURL = node.url
        return node
    }

    func node(for url: URL) -> FolderNode? {
        let target = url.standardizedFileURL
        return roots.flatMap { $0.visibleNodes() }.first { $0.url == target }
    }

    /// Next / previous folder in the visible tree order (⌥⌘↓ / ⌥⌘↑).
    func neighbour(of url: URL, offset: Int) -> URL? {
        let all = roots.flatMap { $0.visibleNodes() }
        guard let i = all.firstIndex(where: { $0.url == url.standardizedFileURL }) else { return nil }
        let j = i + offset
        return all.indices.contains(j) ? all[j].url : nil
    }

    /// Enclosing folder, if it is still inside a sidebar root (⌘↑).
    func parentURL(of url: URL) -> URL? {
        guard let r = root(containing: url), url.standardizedFileURL != r.url else { return nil }
        return url.standardizedFileURL.deletingLastPathComponent()
    }
}
