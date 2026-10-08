import Foundation

public struct ScanOptions: Sendable, Equatable {
    public var includeSubfolders: Bool
    /// "Treat RAW+JPEG as one photo" (spec §4.3).
    public var pairRawWithRaster: Bool

    public init(includeSubfolders: Bool = false, pairRawWithRaster: Bool = true) {
        self.includeSubfolders = includeSubfolders
        self.pairRawWithRaster = pairRawWithRaster
    }
}

/// Enumerates a folder and groups files into logical items (RAW+raster pairs, sidecars).
public enum FolderScanner {
    public struct Listing: Sendable {
        public var images: [FileRef]
        public var sidecars: [URL]
    }

    /// Lists supported image files and `.xmp` sidecars. Hidden files and this app's temp files are skipped.
    public static func list(folder: URL, includeSubfolders: Bool) throws -> Listing {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        var images: [FileRef] = []
        var sidecars: [URL] = []

        func consider(_ url: URL, _ values: URLResourceValues) {
            guard values.isRegularFile == true else { return }
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { return }
            let ext = url.pathExtension.lowercased()
            if ext == "xmp" {
                sidecars.append(url)
            } else if let kind = FileKind(pathExtension: ext) {
                images.append(FileRef(url: url, kind: kind, size: Int64(values.fileSize ?? 0),
                                      modificationDate: values.contentModificationDate ?? .distantPast))
            }
        }

        if includeSubfolders {
            guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: keys,
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: folder])
            }
            for case let url as URL in e {
                if let v = try? url.resourceValues(forKeys: Set(keys)) { consider(url, v) }
            }
        } else {
            let urls = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                  options: [.skipsHiddenFiles])
            for url in urls {
                if let v = try? url.resourceValues(forKeys: Set(keys)) { consider(url, v) }
            }
        }
        return Listing(images: images, sidecars: sidecars)
    }

    /// Quick count of candidate image files, used for the "too many files" warning when scanning subfolders.
    public static func countImages(folder: URL, includeSubfolders: Bool, stopAfter limit: Int = .max) -> Int {
        let fm = FileManager.default
        var n = 0
        if includeSubfolders {
            guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil,
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
            for case let url as URL in e where FileKind(pathExtension: url.pathExtension) != nil {
                n += 1
                if n > limit { break }
            }
        } else {
            let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            n = urls.filter { FileKind(pathExtension: $0.pathExtension) != nil }.count
        }
        return n
    }

    /// Groups files into items. Pairing only happens for an exact base-name match in the same folder,
    /// between one RAW and one raster file (spec §4.3).
    public static func group(_ listing: Listing, options: ScanOptions) -> [ItemFiles] {
        struct Key: Hashable { let folder: String; let base: String }
        func key(_ url: URL) -> Key {
            Key(folder: url.deletingLastPathComponent().standardizedFileURL.path,
                base: url.deletingPathExtension().lastPathComponent)
        }

        var byKey: [Key: [FileRef]] = [:]
        for f in listing.images { byKey[key(f.url), default: []].append(f) }
        var sidecarByKey: [Key: URL] = [:]
        for s in listing.sidecars { sidecarByKey[key(s)] = s }

        let rasterPreference: [FileKind] = [.jpeg, .heic, .tiff, .png]
        var items: [ItemFiles] = []
        items.reserveCapacity(listing.images.count)

        for (k, files) in byKey {
            let sidecar = sidecarByKey[k]
            var raws = files.filter { $0.kind.isRaw }.sorted { $0.fileName < $1.fileName }
            var rasters = files.filter { $0.kind.isRaster }.sorted {
                let a = rasterPreference.firstIndex(of: $0.kind)!, b = rasterPreference.firstIndex(of: $1.kind)!
                return a != b ? a < b : $0.fileName < $1.fileName
            }

            var sidecarClaimed = false
            if options.pairRawWithRaster, !raws.isEmpty, !rasters.isEmpty {
                let raw = raws.removeFirst()
                let raster = rasters.removeFirst()
                items.append(ItemFiles(files: [raw, raster], sidecarURL: sidecar))
                sidecarClaimed = true
            }
            // Otherwise the sidecar belongs to the first file that stores its metadata in a sidecar.
            for f in raws + rasters {
                var sc: URL?
                if !sidecarClaimed, f.kind.metadataStorage == .sidecar, let sidecar {
                    sc = sidecar
                    sidecarClaimed = true
                }
                items.append(ItemFiles(files: [f], sidecarURL: sc))
            }
        }
        return items.sorted { $0.primary.path.localizedStandardCompare($1.primary.path) == .orderedAscending }
    }

    public static func scan(folder: URL, options: ScanOptions) throws -> [ItemFiles] {
        group(try list(folder: folder, includeSubfolders: options.includeSubfolders), options: options)
    }
}
