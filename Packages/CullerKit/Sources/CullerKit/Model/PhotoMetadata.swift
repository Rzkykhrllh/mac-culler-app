import Foundation

public enum Flag: String, Codable, Sendable, CaseIterable {
    case none
    case pick
    case reject

    /// Value stored in `culler:Flag` (nil = tag absent).
    public var xmpValue: String? {
        switch self {
        case .none: return nil
        case .pick: return "pick"
        case .reject: return "reject"
        }
    }

    public init(xmpValue: String?) {
        switch xmpValue?.lowercased() {
        case "pick": self = .pick
        case "reject": self = .reject
        default: self = .none
        }
    }
}

public enum ColorLabel: String, Codable, Sendable, CaseIterable {
    case none, red, yellow, green, blue, purple

    /// Value stored in `xmp:Label` — Lightroom's default label set names.
    public var xmpValue: String? {
        self == .none ? nil : rawValue.capitalized
    }

    public init(xmpValue: String?) {
        guard let v = xmpValue?.trimmingCharacters(in: .whitespaces).lowercased(), !v.isEmpty else {
            self = .none
            return
        }
        self = ColorLabel(rawValue: v) ?? .none
    }

    public var displayName: String { self == .none ? "None" : rawValue.capitalized }

    /// Finder tag name of the same color (spec §5.5).
    public var finderTagName: String? { xmpValue }
}

/// The culling marks of one photo. These are the only fields this app writes.
public struct PhotoMetadata: Codable, Equatable, Hashable, Sendable {
    public var flag: Flag
    public var rating: Int
    public var label: ColorLabel
    public var note: String

    public init(flag: Flag = .none, rating: Int = 0, label: ColorLabel = .none, note: String = "") {
        self.flag = flag
        self.rating = max(0, min(5, rating))
        self.label = label
        self.note = note
    }

    public static let empty = PhotoMetadata()
    public var isEmpty: Bool { self == .empty }
    public var hasNote: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Compact JSON stored in the xattr backup (spec §5.4).
public struct MetadataBackup: Codable, Equatable, Sendable {
    public var rating: Int
    public var label: String
    public var flag: String
    public var note: String
    public var updatedAt: Date

    public init(_ m: PhotoMetadata, updatedAt: Date = Date()) {
        rating = m.rating
        label = m.label.rawValue
        flag = m.flag.rawValue
        note = m.note
        self.updatedAt = updatedAt
    }

    public var metadata: PhotoMetadata {
        PhotoMetadata(flag: Flag(rawValue: flag) ?? .none, rating: rating,
                      label: ColorLabel(rawValue: label) ?? .none, note: note)
    }
}
