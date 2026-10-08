import AppKit
import Darwin
import CullerKit

/// Folders the user has granted the sandboxed app access to (security-scoped bookmarks, spec §11).
/// Every grant stays open for the app's lifetime, so everything below it can be browsed freely.
final class AccessGrants {
    private let store = RecentFolders(key: "accessGrants", limit: 500)
    private var active: [URL] = []

    /// The user's real home folder (FileManager's home is the container inside the sandbox).
    static let realHome: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }()

    init() {
        // One-time migration of folders pinned by earlier builds.
        let legacy = RecentFolders(key: "sidebarRoots", limit: 100)
        for e in legacy.entries where !store.entries.contains(where: { $0.path == e.path }) {
            if let url = legacy.resolve(e), url.startAccessingSecurityScopedResource() {
                active.append(url)
                store.add(url)
            }
        }
        for e in store.entries {
            guard let url = store.resolve(e) else { continue }
            if url.startAccessingSecurityScopedResource() { active.append(url) }
        }
    }

    var grantedPaths: [String] { store.entries.map(\.path) }

    /// Records a folder the user just picked in an open panel (its access is live right now).
    func add(_ url: URL) {
        guard !covers(url) else { return }
        store.add(url)
        if url.startAccessingSecurityScopedResource() { active.append(url) }
    }

    func covers(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return store.entries.contains { p == $0.path || p.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
    }

    /// Whether the sandbox lets us list this folder right now (grant, entitlement or user selection).
    static func canRead(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// Asks the user to grant access to `url` with an open panel pointed at it. Returns the granted URL.
    @discardableResult
    func request(_ url: URL, reason: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        panel.prompt = "Grant Access"
        panel.message = reason ?? "\(AppConstants.appName) needs permission to browse “\(url.lastPathComponent)”. Click Grant Access — you only need to do this once."
        guard panel.runModal() == .OK, let picked = panel.url else { return nil }
        add(picked)
        return picked
    }
}
