import Foundation

/// The kind of image file, derived from its extension.
public enum FileKind: String, Codable, Sendable, CaseIterable {
    case raw
    case dng
    case jpeg
    case heic
    case tiff
    case png

    /// Proprietary camera RAW extensions recognised by ImageIO / Core Image.
    public static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "rwl",
        "pef", "srw", "3fr", "fff", "iiq", "erf", "mos", "mrw", "x3f", "dcr", "kdc", "raw",
    ]

    public init?(pathExtension ext: String) {
        let e = ext.lowercased()
        switch e {
        case "jpg", "jpeg", "jpe": self = .jpeg
        case "heic", "heif", "hif": self = .heic
        case "tif", "tiff": self = .tiff
        case "png": self = .png
        case "dng": self = .dng
        default:
            if Self.rawExtensions.contains(e) { self = .raw } else { return nil }
        }
    }

    /// RAW in the broad sense (needs `CIRAWFilter` for full decode).
    public var isRaw: Bool { self == .raw || self == .dng }
    public var isRaster: Bool { !isRaw }

    /// Where this app stores XMP for a file of this kind (spec §5.2).
    /// DNG: ImageIO cannot write DNG (not in `CGImageDestinationCopyTypeIdentifiers`), so it uses a sidecar.
    public var metadataStorage: MetadataStorage {
        switch self {
        case .jpeg, .heic, .tiff: return .embedded
        case .raw, .dng, .png: return .sidecar
        }
    }

    /// Short label for badges ("RAW", "JPG", …).
    public var badge: String {
        switch self {
        case .raw: return "RAW"
        case .dng: return "DNG"
        case .jpeg: return "JPG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .png: return "PNG"
        }
    }
}

public enum MetadataStorage: Sendable {
    case embedded
    case sidecar
}
