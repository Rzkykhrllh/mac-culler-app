import Foundation
import Observation
import CullerKit

typealias ItemID = String

/// One logical photo in the open folder. Observable per item, so a marking key only invalidates views showing it.
@Observable
final class PhotoItem: Identifiable {
    enum WriteState: Equatable {
        case saved
        case pending
        case failed(String)
    }

    /// The primary file's path. Changes when the item is renamed or moved (the session re-keys it).
    private(set) var id: ItemID
    var files: ItemFiles {
        didSet { id = files.primary.path; partnerKey = Self.partnerKey(files) }
    }
    /// Folder + base name without extension: a RAW and a JPEG of the same shot share it.
    @ObservationIgnored private(set) var partnerKey: String

    private static func partnerKey(_ f: ItemFiles) -> String { (f.primary.path as NSString).deletingPathExtension }
    var metadata: PhotoMetadata
    var exif: ExifInfo?
    /// True once the metadata has been read from disk (or the index).
    var metadataLoaded: Bool
    var writeState: WriteState = .saved
    /// Set when the image could not be decoded (e.g. a RAW from a camera newer than this macOS).
    var decodeFailed = false
    /// Faces / animals + subject sharpness (background analysis).
    var analysis: PhotoAnalysis?
    /// The sharpest frame of its stack (a hint; the user decides).
    var isSharpestInStack = false

    init(files: ItemFiles, metadata: PhotoMetadata = .empty, exif: ExifInfo? = nil, metadataLoaded: Bool = false) {
        id = files.primary.path
        partnerKey = Self.partnerKey(files)
        self.files = files
        self.metadata = metadata
        self.exif = exif
        self.metadataLoaded = metadataLoaded
    }

    var fileName: String { files.primary.fileName }
    var captureDate: Date { exif?.captureDate ?? files.primary.modificationDate }
    var totalSize: Int64 { files.files.reduce(0) { $0 + $1.size } + sidecarSize }
    private var sidecarSize: Int64 {
        guard let sc = files.sidecarURL, let v = try? sc.resourceValues(forKeys: [.fileSizeKey]) else { return 0 }
        return Int64(v.fileSize ?? 0)
    }
}

/// A row in the grid / filmstrip: a single item, a collapsed stack (its cover), or a member of an expanded stack.
struct DisplayEntry: Hashable, Identifiable {
    enum Kind: Hashable {
        case single
        case collapsedStack(matching: Int, total: Int)
        case stackMember(position: Int, count: Int)
    }

    var itemID: ItemID
    var stackID: String?
    var kind: Kind

    var id: String { itemID }

    var isStack: Bool { stackID != nil }
    var isCollapsedStack: Bool { if case .collapsedStack = kind { return true } else { return false } }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case grid, loupe, compare
    var id: String { rawValue }
    var title: String {
        switch self {
        case .grid: return "Grid"
        case .loupe: return "Loupe"
        case .compare: return "Compare"
        }
    }
    var symbol: String {
        switch self {
        case .grid: return "square.grid.3x3"
        case .loupe: return "photo"
        case .compare: return "rectangle.split.2x1"
        }
    }
}
