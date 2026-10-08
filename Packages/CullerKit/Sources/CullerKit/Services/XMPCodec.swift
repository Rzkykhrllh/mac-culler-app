import Foundation
import ImageIO

/// The owned fields as found in one XMP source. `nil` = the property is absent from that source.
public struct PartialMetadata: Equatable, Sendable {
    public var flag: Flag?
    public var rating: Int?
    public var label: ColorLabel?
    public var note: String?

    public init(flag: Flag? = nil, rating: Int? = nil, label: ColorLabel? = nil, note: String? = nil) {
        self.flag = flag
        self.rating = rating
        self.label = label
        self.note = note
    }

    public var isEmpty: Bool { flag == nil && rating == nil && label == nil && note == nil }

    /// Field-wise merge: values present in `self` win over `other`.
    public func overlaying(_ other: PartialMetadata) -> PartialMetadata {
        PartialMetadata(flag: flag ?? other.flag, rating: rating ?? other.rating,
                        label: label ?? other.label, note: note ?? other.note)
    }

    public var resolved: PhotoMetadata {
        PhotoMetadata(flag: flag ?? .none, rating: rating ?? 0, label: label ?? .none, note: note ?? "")
    }
}

public enum XMPError: Error, LocalizedError {
    case unreadableImage(URL)
    case cannotCreateDestination(URL)
    case copyFailed(URL, String)
    case invalidSidecar(URL)
    case serializationFailed

    public var errorDescription: String? {
        switch self {
        case .unreadableImage(let u): return "Cannot read \(u.lastPathComponent)"
        case .cannotCreateDestination(let u): return "Cannot write metadata to \(u.lastPathComponent)"
        case .copyFailed(let u, let s): return "Metadata update failed for \(u.lastPathComponent): \(s)"
        case .invalidSidecar(let u): return "\(u.lastPathComponent) is not valid XMP"
        case .serializationFailed: return "Could not serialize XMP"
        }
    }
}

/// XMP read / merge / write. Only `xmp:Rating`, `xmp:Label`, `culler:Flag` and `culler:Note` are ever changed;
/// everything else in the packet is preserved (spec §5.3).
public enum XMPCodec {
    static let xmpNS = "http://ns.adobe.com/xap/1.0/"
    static var cullerNS: String { AppConstants.xmpNamespaceURI }
    static var cullerPrefix: String { AppConstants.xmpNamespacePrefix }

    // MARK: Reading

    /// Extracts owned fields by namespace URI + name (independent of the prefix another tool may have used).
    public static func read(_ metadata: CGImageMetadata) -> PartialMetadata {
        var out = PartialMetadata()
        guard let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return out }
        for tag in tags {
            guard let ns = CGImageMetadataTagCopyNamespace(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
            let value = (CGImageMetadataTagCopyValue(tag) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (ns, name) {
            case (xmpNS, "Rating"):
                if let v = value, !v.isEmpty, let r = Double(v) { out.rating = max(0, min(5, Int(r.rounded()))) }
            case (xmpNS, "Label"):
                if let v = value, !v.isEmpty { out.label = ColorLabel(xmpValue: v) }
            case (cullerNS, "Flag"):
                if let v = value, !v.isEmpty { out.flag = Flag(xmpValue: v) }
            case (cullerNS, "Note"):
                if let v = value, !v.isEmpty { out.note = v }
            default: break
            }
        }
        return out
    }

    public static func readEmbedded(_ url: URL) -> PartialMetadata? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) else { return nil }
        return read(meta)
    }

    public static func readSidecar(_ url: URL) -> PartialMetadata? {
        guard let data = try? Data(contentsOf: url), let meta = CGImageMetadataCreateFromXMPData(data as CFData) else { return nil }
        return read(meta)
    }

    // MARK: Merging

    /// Returns a mutable copy of `base` with the owned fields set to `m` (clears remove the property).
    static func merged(_ base: CGImageMetadata?, with m: PhotoMetadata) -> CGMutableImageMetadata {
        let mm = base.flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        let prefix = ensureNamespace(mm)
        func put(_ path: String, _ value: String?) {
            if let value, !value.isEmpty {
                CGImageMetadataSetValueWithPath(mm, nil, path as CFString, value as CFString)
            } else {
                CGImageMetadataRemoveTagWithPath(mm, nil, path as CFString)
            }
        }
        put("xmp:Rating", m.rating > 0 ? String(m.rating) : nil)
        put("xmp:Label", m.label.xmpValue)
        put("\(prefix):Flag", m.flag.xmpValue)
        put("\(prefix):Note", m.hasNote ? m.note : nil)
        return mm
    }

    /// Registers the culler namespace, reusing a prefix already bound to its URI in the packet.
    @discardableResult
    static func ensureNamespace(_ mm: CGMutableImageMetadata) -> String {
        if let tags = CGImageMetadataCopyTags(mm) as? [CGImageMetadataTag] {
            for tag in tags where (CGImageMetadataTagCopyNamespace(tag) as String?) == cullerNS {
                if let p = CGImageMetadataTagCopyPrefix(tag) as String? { return p }
            }
        }
        var err: Unmanaged<CFError>?
        CGImageMetadataRegisterNamespaceForPrefix(mm, cullerNS as CFString, cullerPrefix as CFString, &err)
        err?.release()
        return cullerPrefix
    }

    /// Sidecar content after merging `m` into `existing` (nil = new sidecar).
    public static func mergedSidecarData(existing: Data?, metadata m: PhotoMetadata, url: URL) throws -> Data {
        var base: CGImageMetadata?
        if let existing, !existing.isEmpty {
            guard let parsed = CGImageMetadataCreateFromXMPData(existing as CFData) else { throw XMPError.invalidSidecar(url) }
            base = parsed
        }
        let mm = merged(base, with: m)
        guard let data = CGImageMetadataCreateXMPData(mm, nil) as Data? else { throw XMPError.serializationFailed }
        return data
    }

    // MARK: Writing

    /// Merges `m` into the sidecar at `url` (created when missing). Atomic.
    public static func writeSidecar(_ m: PhotoMetadata, to url: URL, beforeReplace: AtomicFile.BeforeReplaceHook? = nil) throws {
        let existing = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        let data = try mergedSidecarData(existing: existing, metadata: m, url: url)
        try AtomicFile.write(data, to: url, beforeReplace: beforeReplace)
    }

    /// Lossless embedded update (JPEG / HEIC / TIFF) via `CGImageDestinationCopyImageSource` — pixels are never
    /// re-encoded. Only fields whose value differs from the file are touched; clears are written as empty
    /// values because ImageIO ignores `kCFNull` removal for HEIC/TIFF in merge mode. Atomic.
    public static func writeEmbedded(_ m: PhotoMetadata, to url: URL, beforeReplace: AtomicFile.BeforeReplaceHook? = nil) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(src) else { throw XMPError.unreadableImage(url) }
        let current = CGImageSourceCopyMetadataAtIndex(src, 0, nil).map(read) ?? PartialMetadata()

        let patch = CGImageMetadataCreateMutable()
        let prefix = ensureNamespace(patch)
        var changed = false
        func put(_ path: String, _ new: String?, _ old: String?) {
            guard (new ?? "") != (old ?? "") else { return }
            CGImageMetadataSetValueWithPath(patch, nil, path as CFString, (new ?? "") as CFString)
            changed = true
        }
        put("xmp:Rating", m.rating > 0 ? String(m.rating) : nil, (current.rating ?? 0) > 0 ? String(current.rating!) : nil)
        put("xmp:Label", m.label.xmpValue, current.label?.xmpValue)
        put("\(prefix):Flag", m.flag.xmpValue, current.flag?.xmpValue)
        put("\(prefix):Note", m.hasNote ? m.note : nil, current.note)
        guard changed else { return }

        try AtomicFile.replace(url, beforeReplace: beforeReplace) { tmp in
            guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, CGImageSourceGetCount(src), nil) else {
                throw XMPError.cannotCreateDestination(url)
            }
            let opts = [kCGImageDestinationMetadata: patch, kCGImageDestinationMergeMetadata: true] as CFDictionary
            var err: Unmanaged<CFError>?
            guard CGImageDestinationCopyImageSource(dest, src, opts, &err) else {
                let msg = err.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? "unknown error"
                throw XMPError.copyFailed(url, msg)
            }
        }
    }
}
