import Foundation
import Observation
import CullerKit

/// User preferences (spec §12), persisted in UserDefaults.
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var pairRawWithRaster: Bool { didSet { defaults.set(pairRawWithRaster, forKey: Keys.pair) } }
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

    var cacheLimitBytes: Int64 { Int64(cacheLimitGB * 1_000_000_000) }

    private enum Keys {
        static let pair = "pairRawWithRaster"
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
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.pair: true, Keys.burst: 1.0, Keys.subfolders: false, Keys.subfolderWarn: 5000,
            Keys.slots: 2, Keys.pin: false, Keys.sync: true, Keys.finderTags: false,
            Keys.cacheLimit: 5.0, Keys.thumbSize: 180.0, Keys.debug: false,
        ])
        pairRawWithRaster = defaults.bool(forKey: Keys.pair)
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
        if let d = defaults.data(forKey: Keys.presets), let p = try? JSONDecoder().decode([RenamePreset].self, from: d) {
            renamePresets = p
        } else {
            renamePresets = RenamePreset.defaults
        }
    }
}
