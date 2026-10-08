import Foundation

/// All filters, combined with AND (spec §7).
public struct FilterState: Equatable, Sendable, Codable {
    public enum RatingOperator: String, CaseIterable, Sendable, Codable {
        case atLeast = "≥"
        case equal = "="
        case atMost = "≤"
    }

    public enum FileTypeFilter: String, CaseIterable, Sendable, Codable {
        case raw = "RAW", jpeg = "JPEG", heic = "HEIC", tiff = "TIFF", png = "PNG", paired = "Paired"
    }

    public var flags: Set<Flag> = []                // empty = any
    public var ratingOperator: RatingOperator = .atLeast
    public var rating: Int? = nil                   // nil = any
    public var labels: Set<ColorLabel> = []         // empty = any; includes .none for "no label"
    public var fileTypes: Set<FileTypeFilter> = []  // empty = any (OR within the set)
    public var hasNote = false
    public var cameras: Set<String> = []
    public var lenses: Set<String> = []
    public var isoRange: ClosedRange<Int>? = nil
    public var focalRange: ClosedRange<Double>? = nil
    public var apertureRange: ClosedRange<Double>? = nil
    public var dateRange: ClosedRange<Date>? = nil

    public init() {}

    public var isActive: Bool { self != FilterState() }

    public var usesExif: Bool {
        !cameras.isEmpty || !lenses.isEmpty || isoRange != nil || focalRange != nil || apertureRange != nil || dateRange != nil
    }

    public func matches(metadata m: PhotoMetadata, exif: ExifInfo?, files: ItemFiles) -> Bool {
        if !flags.isEmpty, !flags.contains(m.flag) { return false }
        if let r = rating {
            switch ratingOperator {
            case .atLeast: if m.rating < r { return false }
            case .equal: if m.rating != r { return false }
            case .atMost: if m.rating > r { return false }
            }
        }
        if !labels.isEmpty, !labels.contains(m.label) { return false }
        if hasNote, !m.hasNote { return false }
        if !fileTypes.isEmpty {
            let kinds = Set(files.files.map(\.kind))
            let ok = fileTypes.contains { t in
                switch t {
                case .raw: return kinds.contains(.raw) || kinds.contains(.dng)
                case .jpeg: return kinds.contains(.jpeg)
                case .heic: return kinds.contains(.heic)
                case .tiff: return kinds.contains(.tiff)
                case .png: return kinds.contains(.png)
                case .paired: return files.isPair
                }
            }
            if !ok { return false }
        }
        if usesExif {
            // Not yet indexed → excluded from EXIF filters until its EXIF is known.
            guard let e = exif else { return false }
            if !cameras.isEmpty, !cameras.contains(e.cameraName ?? "Unknown") { return false }
            if !lenses.isEmpty, !lenses.contains(e.lens ?? "Unknown") { return false }
            if let r = isoRange { guard let v = e.iso, r.contains(v) else { return false } }
            if let r = focalRange { guard let v = e.focalLength, r.contains(v) else { return false } }
            if let r = apertureRange { guard let v = e.aperture, r.contains(v) else { return false } }
            if let r = dateRange { guard let v = e.captureDate, r.contains(v) else { return false } }
        }
        return true
    }
}

public enum SortKey: String, CaseIterable, Sendable, Codable {
    case captureTime = "Capture Time"
    case fileName = "File Name"
    case rating = "Rating"
    case modificationDate = "Modification Date"
    case fileSize = "File Size"
}

public struct SortOrder: Equatable, Sendable, Codable {
    public var key: SortKey
    public var ascending: Bool
    public init(key: SortKey = .captureTime, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    /// Strict ordering; ties fall back to file name so the order is stable.
    public func areInIncreasingOrder(_ a: (files: ItemFiles, exif: ExifInfo?, metadata: PhotoMetadata),
                                     _ b: (files: ItemFiles, exif: ExifInfo?, metadata: PhotoMetadata)) -> Bool {
        func name(_ x: ItemFiles) -> String { x.primary.fileName }
        let nameOrder = name(a.files).localizedStandardCompare(name(b.files))
        let tie: Bool = nameOrder == .orderedSame ? a.files.primary.path < b.files.primary.path : nameOrder == .orderedAscending
        var result: ComparisonResult = .orderedSame
        switch key {
        case .captureTime:
            let da = a.exif?.captureDate ?? a.files.primary.modificationDate
            let db = b.exif?.captureDate ?? b.files.primary.modificationDate
            result = da == db ? .orderedSame : (da < db ? .orderedAscending : .orderedDescending)
        case .fileName:
            result = nameOrder
        case .rating:
            result = a.metadata.rating == b.metadata.rating ? .orderedSame : (a.metadata.rating < b.metadata.rating ? .orderedAscending : .orderedDescending)
        case .modificationDate:
            let da = a.files.primary.modificationDate, db = b.files.primary.modificationDate
            result = da == db ? .orderedSame : (da < db ? .orderedAscending : .orderedDescending)
        case .fileSize:
            let sa = a.files.files.reduce(0) { $0 + $1.size }, sb = b.files.files.reduce(0) { $0 + $1.size }
            result = sa == sb ? .orderedSame : (sa < sb ? .orderedAscending : .orderedDescending)
        }
        if result == .orderedSame { return ascending ? tie : !tie }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }
}
