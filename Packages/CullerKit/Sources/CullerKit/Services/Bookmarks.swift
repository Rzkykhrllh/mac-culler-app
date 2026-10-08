import Foundation

/// Security-scoped bookmark handling for recent folders and move/copy destinations (spec §11).
public enum Bookmarks {
    public static func make(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public struct Resolved {
        public var url: URL
        /// The bookmark was stale and has been refreshed (callers should persist `refreshed`).
        public var refreshed: Data?
    }

    /// Resolves a bookmark. Returns nil when it can no longer be resolved (the user must reselect the folder).
    public static func resolve(_ data: Data) -> Resolved? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        var refreshed: Data?
        if stale {
            let ok = url.startAccessingSecurityScopedResource()
            refreshed = make(for: url)
            if ok { url.stopAccessingSecurityScopedResource() }
            if refreshed == nil { return nil }
        }
        return Resolved(url: url, refreshed: refreshed)
    }
}

/// A persisted, most-recent-first list of bookmarked folders (stored in UserDefaults).
public final class RecentFolders: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var id: String { path }
        public var path: String
        public var bookmark: Data
        public var name: String { (path as NSString).lastPathComponent }
    }

    private let key: String
    private let limit: Int
    private let defaults: UserDefaults

    public init(key: String, limit: Int = 10, defaults: UserDefaults = .standard) {
        self.key = key
        self.limit = limit
        self.defaults = defaults
    }

    public var entries: [Entry] {
        guard let d = defaults.data(forKey: key), let e = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return e
    }

    private func save(_ e: [Entry]) {
        defaults.set(try? JSONEncoder().encode(Array(e.prefix(limit))), forKey: key)
    }

    public func add(_ url: URL) {
        guard let b = Bookmarks.make(for: url) else { return }
        var e = entries.filter { $0.path != url.path }
        e.insert(Entry(path: url.path, bookmark: b), at: 0)
        save(e)
    }

    public func remove(path: String) { save(entries.filter { $0.path != path }) }

    /// Resolves an entry, refreshing stale bookmarks; removes it when unresolvable.
    public func resolve(_ entry: Entry) -> URL? {
        guard let r = Bookmarks.resolve(entry.bookmark) else {
            remove(path: entry.path)
            return nil
        }
        if let fresh = r.refreshed {
            save(entries.map { $0.path == entry.path ? Entry(path: r.url.path, bookmark: fresh) : $0 })
        }
        return r.url
    }

    public func clear() { save([]) }
}
