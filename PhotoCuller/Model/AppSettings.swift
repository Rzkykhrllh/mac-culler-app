import Foundation
import Observation
import CullerKit

/// User preferences (spec §12), persisted in UserDefaults.
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    /// How RAW+JPEG pairs are shown (spec §4.3 "Treat RAW+JPEG as one photo", extended with separate modes).
    var fileViewMode: FileViewMode { didSet { defaults.set(fileViewMode.rawValue, forKey: Keys.fileView) } }
    var pairRawWithRaster: Bool { fileViewMode == .combined }
    var burstThreshold: Double { didSet { defaults.set(burstThreshold, forKey: Keys.burst) } }
    var includeSubfoldersByDefault: Bool { didSet { defaults.set(includeSubfoldersByDefault, forKey: Keys.subfolders) } }
    var subfolderWarningThreshold: Int { didSet { defaults.set(subfolderWarningThreshold, forKey: Keys.subfolderWarn) } }
    var compareSlotCount: Int { didSet { defaults.set(compareSlotCount, forKey: Keys.slots) } }
    var comparePinBest: Bool { didSet { defaults.set(comparePinBest, forKey: Keys.pin) } }
    var compareSyncDefault: Bool { didSet { defaults.set(compareSyncDefault, forKey: Keys.sync) } }
    var syncFinderTags: Bool { didSet { defaults.set(syncFinderTags, forKey: Keys.finderTags) } }
    var cacheLimitGB: Double { didSet { defaults.set(cacheLimitGB, forKey: Keys.cacheLimit) } }
    var thumbnailSize: Double { didSet { defaults.set(thumbnailSize, forKey: Keys.thumbSize) } }
    var renamePresets: [RenamePreset] {
        didSet { defaults.set(try? JSONEncoder().encode(renamePresets), forKey: Keys.presets) }
    }
    var showDebugOverlay: Bool { didSet { defaults.set(showDebugOverlay, forKey: Keys.debug) } }
    /// RAW look: neutral render from sensor data (default) or the camera's embedded JPEG (film simulation, faster).
    var rawRendering: RawRendering { didSet { defaults.set(rawRendering.rawValue, forKey: Keys.rawRendering) } }

    var cacheLimitBytes: Int64 { Int64(cacheLimitGB * 1_000_000_000) }

    private enum Keys {
        static let pair = "pairRawWithRaster"
        static let fileView = "fileViewMode"
        static let burst = "burstThreshold"
        static let subfolders = "includeSubfoldersByDefault"
        static let subfolderWarn = "subfolderWarningThreshold"
        static let slots = "compareSlotCount"
        static let pin = "comparePinBest"
        static let sync = "compareSyncDefault"
        static let finderTags = "syncFinderTags"
        static let cacheLimit = "cacheLimitGB"
        static let thumbSize = "thumbnailSize"
        static let presets = "renamePresets"
        static let debug = "showDebugOverlay"
        static let rawRendering = "rawRendering"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.pair: true, Keys.burst: 1.0, Keys.subfolders: false, Keys.subfolderWarn: 5000,
            Keys.slots: 2, Keys.pin: false, Keys.sync: true, Keys.finderTags: false,
            Keys.cacheLimit: 5.0, Keys.thumbSize: 180.0, Keys.debug: false,
        ])
        fileViewMode = defaults.string(forKey: Keys.fileView).flatMap(FileViewMode.init(rawValue:))
            ?? (defaults.bool(forKey: Keys.pair) ? .combined : .both)
        burstThreshold = defaults.double(forKey: Keys.burst)
        includeSubfoldersByDefault = defaults.bool(forKey: Keys.subfolders)
        subfolderWarningThreshold = defaults.integer(forKey: Keys.subfolderWarn)
        compareSlotCount = defaults.integer(forKey: Keys.slots)
        comparePinBest = defaults.bool(forKey: Keys.pin)
        compareSyncDefault = defaults.bool(forKey: Keys.sync)
        syncFinderTags = defaults.bool(forKey: Keys.finderTags)
        cacheLimitGB = defaults.double(forKey: Keys.cacheLimit)
        thumbnailSize = defaults.double(forKey: Keys.thumbSize)
        showDebugOverlay = defaults.bool(forKey: Keys.debug)
        rawRendering = defaults.string(forKey: Keys.rawRendering).flatMap(RawRendering.init(rawValue:)) ?? .rendered
        if let d = defaults.data(forKey: Keys.presets), let p = try? JSONDecoder().decode([RenamePreset].self, from: d) {
            renamePresets = p
        } else {
            renamePresets = RenamePreset.defaults
        }
    }
}

/// RAW+JPEG display mode. "Combined" pairs them into one photo (marks apply to both files);
/// the other modes treat every file as its own photo so RAW and JPEG can be marked separately.
enum FileViewMode: String, CaseIterable, Identifiable {
    case combined, both, jpegOnly, rawOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .combined: return "RAW+JPEG as One Photo"
        case .both: return "RAW and JPEG Separately"
        case .jpegOnly: return "JPEG Only"
        case .rawOnly: return "RAW Only"
        }
    }

    var segmentTitle: String {
        switch self {
        case .combined: return "RAW+JPG"
        case .both: return "Separate"
        case .jpegOnly: return "JPG"
        case .rawOnly: return "RAW"
        }
    }

    var shortTitle: String {
        switch self {
        case .combined: return "RAW+JPEG"
        case .both: return "Separate"
        case .jpegOnly: return "JPEG"
        case .rawOnly: return "RAW"
        }
    }

    /// ⌥⌘1 … ⌥⌘4
    var shortcutKey: Character { ["1", "2", "3", "4"][Self.allCases.firstIndex(of: self)!] }

    var pairs: Bool { self == .combined }

    /// Whether an item is shown in this mode (only meaningful for unpaired items).
    func shows(_ files: ItemFiles) -> Bool {
        switch self {
        case .combined, .both: return true
        case .jpegOnly: return files.files.contains { $0.kind.isRaster }
        case .rawOnly: return files.files.contains { $0.kind.isRaw }
        }
    }
}
