import Foundation
import Observation

/// A browser-like tab: its own folder + complete browsing state (selection, filter, view mode, compare…).
/// Inactive tabs keep their session in memory, so switching back is instant.
@Observable
final class WorkspaceTab: Identifiable {
    let id = UUID()
    var session: FolderSession?
    /// Folder restored from the last launch, opened when the tab is first shown.
    var pendingFolder: URL?

    init(pendingFolder: URL? = nil) {
        self.pendingFolder = pendingFolder
    }

    var folder: URL? { session?.folder ?? pendingFolder }
    var title: String { folder?.lastPathComponent ?? "New Tab" }
}
