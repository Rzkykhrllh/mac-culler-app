import Foundation

/// Item-level metadata persistence: decides where each file's XMP lives, keeps RAW sidecar and JPEG embedded XMP
/// in sync, maintains the xattr backup and (optionally) Finder color tags.
public enum MetadataStore {
    public struct ReadResult: Sendable, Equatable {
        public var metadata: PhotoMetadata
        /// Set when the sidecar was regenerated from the xattr backup during the read.
        public var recoveredSidecar: URL?
    }

    // MARK: Read

    /// Reads the item's marks. Precedence per field: sidecar > embedded XMP of a raster file > xattr backup.
    /// If a sidecar-backed item has an xattr backup but no sidecar, the sidecar is regenerated (spec §5.4).
    public static func read(_ item: ItemFiles, recover: Bool = true) -> ReadResult {
        var combined = PartialMetadata()
        if let sc = item.sidecarURL, let p = XMPCodec.readSidecar(sc) {
            combined = p
        }
        for f in item.files where f.kind.metadataStorage == .embedded {
            if let p = XMPCodec.readEmbedded(f.url) { combined = combined.overlaying(p) }
        }

        let backup = readBackup(item)
        var recovered: URL?
        if recover, item.needsSidecar, item.sidecarURL == nil, let backup {
            // XMP (embedded) wins over the backup when both exist; fill only what XMP does not say.
            let m = combined.overlaying(partial(backup.metadata)).resolved
            let url = item.sidecarWriteURL
            if !FileManager.default.fileExists(atPath: url.path), (try? XMPCodec.writeSidecar(m, to: url)) != nil {
                recovered = url
            }
            return ReadResult(metadata: m, recoveredSidecar: recovered)
        }
        if combined.isEmpty, let backup, item.needsSidecar == false {
            // Embedded XMP missing entirely (e.g. stripped by another tool) — fall back to the backup.
            return ReadResult(metadata: backup.metadata, recoveredSidecar: nil)
        }
        return ReadResult(metadata: combined.resolved, recoveredSidecar: nil)
    }

    static func partial(_ m: PhotoMetadata) -> PartialMetadata {
        PartialMetadata(flag: m.flag, rating: m.rating, label: m.label, note: m.note)
    }

    public static func readBackup(_ item: ItemFiles) -> MetadataBackup? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        for f in item.files {
            if let d = XAttr.get(AppConstants.xattrName, at: f.url), let b = try? dec.decode(MetadataBackup.self, from: d) {
                return b
            }
        }
        return nil
    }

    // MARK: Write

    public struct WriteOptions: Sendable {
        public var syncFinderTags: Bool
        /// Test hook forwarded to every atomic replacement.
        public var beforeReplace: AtomicFile.BeforeReplaceHook?
        public init(syncFinderTags: Bool = false, beforeReplace: AtomicFile.BeforeReplaceHook? = nil) {
            self.syncFinderTags = syncFinderTags
            self.beforeReplace = beforeReplace
        }
    }

    /// Writes `m` to every file of the item. Returns the item with refreshed file attributes and sidecar URL.
    @discardableResult
    public static func write(_ m: PhotoMetadata, to item: ItemFiles, options: WriteOptions = .init()) throws -> ItemFiles {
        var updated = item
        if item.needsSidecar {
            let url = item.sidecarWriteURL
            try XMPCodec.writeSidecar(m, to: url, beforeReplace: options.beforeReplace)
            updated.sidecarURL = url
        }
        for f in item.files where f.kind.metadataStorage == .embedded {
            try XMPCodec.writeEmbedded(m, to: f.url, beforeReplace: options.beforeReplace)
        }
        writeBackup(m, to: item)
        if options.syncFinderTags {
            for f in item.files { FinderTags.apply(label: m.label, to: f.url) }
        }
        updated.files = item.files.map { FileRef.load($0.url) ?? $0 }
        return updated
    }

    public static func writeBackup(_ m: PhotoMetadata, to item: ItemFiles) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(MetadataBackup(m)) else { return }
        for f in item.files { XAttr.set(AppConstants.xattrName, data: data, at: f.url) }
    }
}

/// Finder color tags mirroring the color label (spec §5.5). Only this app's color tags are ever added/removed.
public enum FinderTags {
    static let ownTags: Set<String> = Set(ColorLabel.allCases.compactMap(\.finderTagName))

    public static func apply(label: ColorLabel, to url: URL) {
        let current = (try? url.freshResourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        var next = current.filter { !ownTags.contains($0) }
        if let t = label.finderTagName { next.append(t) }
        guard next != current else { return }
        try? (url as NSURL).setResourceValue(next, forKey: .tagNamesKey)
    }
}
