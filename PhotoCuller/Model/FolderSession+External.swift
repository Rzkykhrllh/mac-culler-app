import AppKit
import UniformTypeIdentifiers
import CullerKit

/// Handing photos to other apps: Lightroom import, "Open With" an editor.
enum ExternalApps {
    /// Lightroom Classic first, then Lightroom (App Store / Creative Cloud). Opening files with either one
    /// starts its import with those files (what Finder's Open With does).
    static let lightroomIDs = ["com.adobe.LightroomClassicCC7", "com.adobe.mas.lightroomCC", "com.adobe.lightroomCC"]

    static var lightroom: (url: URL, name: String)? {
        for id in lightroomIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return (url, name(of: url)) }
        }
        return nil
    }

    static func name(of app: URL) -> String {
        (FileManager.default.displayName(atPath: app.path) as NSString).deletingPathExtension
    }

    /// Photo apps worth listing (browsers, chat apps etc. also claim images; they are left out).
    private static let photoApps = ["lightroom", "photoshop", "bridge", "capture one", "raw studio", "pixelmator", "affinity",
                                    "darktable", "dxo", "luminar", "on1", "acdsee", "photos", "preview", "photomator",
                                    "rawpower", "raw power", "silkypix", "exposure", "gimp", "nik", "topaz", "camera raw"]

    /// Photo apps that can open `file`: the default one first (if it is a photo app), then the rest by name.
    static func editors(for file: URL) -> [URL] {
        let me = Bundle.main.bundleURL.standardizedFileURL
        func isPhotoApp(_ u: URL) -> Bool {
            let n = name(of: u).lowercased()
            return u.standardizedFileURL != me && photoApps.contains { n.contains($0) }
        }
        var out: [URL] = []
        if let d = NSWorkspace.shared.urlForApplication(toOpen: file), isPhotoApp(d) { out.append(d) }
        let rest = NSWorkspace.shared.urlsForApplications(toOpen: file)
            .filter { isPhotoApp($0) && !out.contains($0) }
            .sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
        return Array((out + rest).prefix(12))
    }

    /// "Other App…": pick any application.
    @MainActor
    static func chooseApp() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Open"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func icon(_ app: URL) -> NSImage {
        let img = NSWorkspace.shared.icon(forFile: app.path)
        img.size = NSSize(width: 16, height: 16)
        return img
    }
}

extension FolderSession {
    /// Picks of this folder in the current RAW/JPEG mode, in capture order.
    var picks: [PhotoItem] {
        items.values.filter { $0.metadata.flag == .pick && fileView.shows($0.files) }.sorted { $0.captureDate < $1.captureDate }
    }

    /// Opens the photos' image files (both of a RAW+JPG pair; not the .xmp, which Lightroom reads itself)
    /// in `application`, after pending marks have reached the files.
    func open(_ targets: [PhotoItem], in application: URL) {
        let urls = targets.flatMap { $0.files.files.map(\.url) }
        guard !urls.isEmpty else { return }
        let appName = ExternalApps.name(of: application)
        Task {
            await app.writeQueue.flush()
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            do {
                _ = try await NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: config)
                let n = targets.count
                showToast("Sent \(n) photo\(n == 1 ? "" : "s") to \(appName)")
            } catch {
                app.alert = AppAlert(title: "Couldn’t open in \(appName)", message: error.localizedDescription)
            }
        }
    }

    func importToLightroom(_ targets: [PhotoItem]) {
        guard let lr = ExternalApps.lightroom else { return showToast("Lightroom isn’t installed") }
        guard !targets.isEmpty else { return showToast("No photos to send") }
        open(targets, in: lr.url)
    }
}
