import Foundation

/// One file on disk, with the attributes used to key caches (path + size + mtime).
public struct FileRef: Hashable, Sendable, Codable {
    public var url: URL
    public var kind: FileKind
    public var size: Int64
    public var modificationDate: Date

    public init(url: URL, kind: FileKind, size: Int64, modificationDate: Date) {
        self.url = url
        self.kind = kind
        self.size = size
        self.modificationDate = modificationDate
    }

    public var path: String { url.path }
    public var fileName: String { url.lastPathComponent }

    /// Stable cache key for derived data (thumbnails, index rows).
    public var cacheKey: String {
        "\(url.path)|\(size)|\(Int64(modificationDate.timeIntervalSince1970 * 1000))"
    }

    /// Reads size + mtime from disk. Returns nil when the file is missing or unsupported.
    public static func load(_ url: URL) -> FileRef? {
        guard let kind = FileKind(pathExtension: url.pathExtension) else { return nil }
        guard let values = try? url.freshResourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return FileRef(url: url, kind: kind, size: Int64(values.fileSize ?? 0),
                       modificationDate: values.contentModificationDate ?? .distantPast)
    }
}

/// The files that make up one logical photo: a single file, or a RAW+raster pair, plus an optional sidecar.
public struct ItemFiles: Hashable, Sendable, Codable {
    /// All image files of the item. The first one is the display (primary) file.
    public var files: [FileRef]
    /// Existing `.xmp` sidecar, if one is on disk.
    public var sidecarURL: URL?

    public init(files: [FileRef], sidecarURL: URL? = nil) {
        precondition(!files.isEmpty)
        // Display file first: raster before RAW (spec §4.3: display uses the JPEG for speed).
        self.files = files.sorted { a, b in
            if a.kind.isRaw != b.kind.isRaw { return !a.kind.isRaw }
            return a.fileName < b.fileName
        }
        self.sidecarURL = sidecarURL
    }

    /// The file used for display (thumbnail / screen preview).
    public var primary: FileRef { files[0] }
    /// The RAW file of the item, if any (used for 100% zoom).
    public var raw: FileRef? { files.first { $0.kind.isRaw } }
    /// The file decoded for 100% zoom: RAW when present, else the primary.
    public var fullResolutionSource: FileRef { raw ?? primary }
    public var isPair: Bool { files.count > 1 }

    public var folder: URL { primary.url.deletingLastPathComponent() }
    public var baseName: String { primary.url.deletingPathExtension().lastPathComponent }

    /// Where a sidecar for this item lives (or would live): `<basename>.xmp` next to the files.
    public var sidecarWriteURL: URL {
        sidecarURL ?? folder.appendingPathComponent(baseName).appendingPathExtension("xmp")
    }

    /// Whether any file of this item stores metadata in a sidecar.
    public var needsSidecar: Bool { files.contains { $0.kind.metadataStorage == .sidecar } }

    /// Every URL that belongs to this item (image files + sidecar if present). Used by file operations.
    public var allURLs: [URL] {
        files.map(\.url) + (sidecarURL.map { [$0] } ?? [])
    }

    /// Short badge, e.g. "RAW+JPG".
    public var badge: String {
        if isPair { return files.sorted { $0.kind.isRaw && !$1.kind.isRaw }.map(\.kind.badge).joined(separator: "+") }
        return primary.kind.badge
    }
}
