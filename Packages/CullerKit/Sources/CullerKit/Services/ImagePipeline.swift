import Foundation
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

/// Image loading with memory + disk caches, request de-duplication, priorities and cancellation (spec §3, §10).
/// Cache lookups are synchronous so the UI can show whatever is already available in the same frame.
public final class ImagePipeline: @unchecked Sendable {
    public struct Stats: Sendable {
        public var thumbRequests = 0
        public var thumbMemoryHits = 0
        public var thumbDiskHits = 0
        public var thumbGenerated = 0
        public var previewRequests = 0
        public var previewHits = 0
        public var lastPreviewMs: Double = 0
        public var avgPreviewMs: Double = 0
        public var previewDecodes = 0
        public var lastFullMs: Double = 0
        public var fullDecodes = 0
        public var failures = 0

        public var thumbHitRate: Double {
            thumbRequests == 0 ? 0 : Double(thumbMemoryHits + thumbDiskHits) / Double(thumbRequests)
        }
        public var previewHitRate: Double { previewRequests == 0 ? 0 : Double(previewHits) / Double(previewRequests) }
    }

    public let thumbnailPixelSize: Int
    private let thumbMemory = NSCache<NSString, ImageBox>()
    private let previewMemory = NSCache<NSString, ImageBox>()
    private let fullMemory = NSCache<NSString, ImageBox>()
    private let quickMemory = NSCache<NSString, ImageBox>()
    private let thumbLoads: LoadQueue
    /// Tiny embedded thumbnails (≈1 ms) shown while the real thumbnail decodes.
    private let quickLoads: LoadQueue
    /// Core Image RAW renders are effectively serialized on the GPU; their own queue keeps them from
    /// starving JPEG / embedded-preview thumbnails.
    private let rawLoads: LoadQueue
    private let previewLoads: LoadQueue
    private let fullLoads: LoadQueue
    public let diskCache: ThumbnailDiskCache?

    private let renderingLock = NSLock()
    private var _rawRendering: RawRendering = .rendered
    /// How RAW thumbnails / previews are produced. Part of every cache key, so switching is instant for cached images.
    public var rawRendering: RawRendering {
        get { renderingLock.withLock { _rawRendering } }
        set { renderingLock.withLock { _rawRendering = newValue } }
    }

    /// Cache key of a file's derived images under the current RAW rendering.
    public func renderKey(_ file: FileRef) -> String { key(file, rawRendering) }

    func key(_ file: FileRef, _ r: RawRendering) -> String {
        file.kind.isRaw && r == .rendered ? file.cacheKey + "#rendered" : file.cacheKey
    }

    /// File + look a photo's grid thumbnail is made from.
    /// A RAW+JPEG pair uses the RAW's embedded camera preview: the same look as the JPEG, but ~6× faster
    /// than decoding a 26 MP JPEG. Single RAWs follow the RAW-look setting; everything else decodes itself.
    /// Until the RAW engine has warmed up (its first use costs ≈5 s), pairs decode the JPEG instead.
    public func thumbnailSource(for item: ItemFiles) -> (file: FileRef, rendering: RawRendering) {
        if item.isPair, let raw = item.raw {
            return Self.rawEngineReady ? (raw, .embedded) : (item.primary, .embedded)
        }
        return (item.primary, item.primary.kind.isRaw ? rawRendering : .embedded)
    }

    /// Stable key of an item's final thumbnail (independent of which file of a pair produced it).
    public func thumbnailKey(for item: ItemFiles) -> String {
        if item.isPair, let raw = item.raw { return key(raw, .embedded) }
        let s = thumbnailSource(for: item)
        return key(s.file, s.rendering)
    }

    private func finalKeys(for item: ItemFiles) -> [String] { [thumbnailKey(for: item)] }

    private let statsLock = NSLock()
    private var _stats = Stats()
    public var stats: Stats { statsLock.withLock { _stats } }
    private func record(_ f: (inout Stats) -> Void) { statsLock.withLock { f(&_stats) } }

    public init(diskCache: ThumbnailDiskCache?, thumbnailPixelSize: Int = 400,
                thumbnailMemoryBytes: Int = 512 * 1024 * 1024, previewCount: Int = 12) {
        self.diskCache = diskCache
        self.thumbnailPixelSize = thumbnailPixelSize
        thumbMemory.totalCostLimit = thumbnailMemoryBytes
        previewMemory.countLimit = previewCount
        fullMemory.countLimit = 2
        quickMemory.countLimit = 4000
        thumbLoads = LoadQueue(name: "thumbnails", maxConcurrent: ProcessInfo.processInfo.activeProcessorCount)
        quickLoads = LoadQueue(name: "quick", maxConcurrent: 4)
        rawLoads = LoadQueue(name: "raw-render", maxConcurrent: 2)
        previewLoads = LoadQueue(name: "previews", maxConcurrent: 3)
        fullLoads = LoadQueue(name: "full", maxConcurrent: 1)
    }

    // MARK: Thumbnails

    public func cachedThumbnail(_ file: FileRef) -> CGImage? {
        thumbMemory.object(forKey: renderKey(file) as NSString)?.image
    }

    /// Loads a thumbnail: memory → disk cache → generated. `priority` lets visible cells jump the queue.
    public func thumbnail(_ file: FileRef, priority: Operation.QueuePriority = .normal) async -> CGImage? {
        record { $0.thumbRequests += 1 }
        let key = renderKey(file)
        let raw = rawRendering
        if let img = thumbMemory.object(forKey: key as NSString)?.image {
            record { $0.thumbMemoryHits += 1 }
            return img
        }
        let px = thumbnailPixelSize
        let img = await thumbLoads.load(key: key, priority: priority) { [weak self] in
            guard let self else { return nil }
            if let d = self.diskCache?.read(key: key) {
                self.record { $0.thumbDiskHits += 1 }
                return d
            }
            guard let t = ImageDecoder.thumbnail(for: file, maxPixel: px, raw: raw) else {
                self.record { $0.failures += 1 }
                return nil
            }
            self.record { $0.thumbGenerated += 1 }
            self.diskCache?.write(t, key: key)
            return t
        }
        if let img { thumbMemory.setObject(ImageBox(img), forKey: key as NSString, cost: img.bytesPerRow * img.height) }
        return img
    }

    public func cancelThumbnail(_ file: FileRef) { thumbLoads.cancel(key: renderKey(file)) }

    // MARK: Item thumbnails (progressive)

    /// The best thumbnail already in memory for an item: final, else the camera preview, else the tiny one.
    public func cachedThumbnail(for item: ItemFiles) -> (image: CGImage, isFinal: Bool)? {
        let src = thumbnailSource(for: item)
        for k in finalKeys(for: item) {
            if let img = thumbMemory.object(forKey: k as NSString)?.image { return (img, true) }
        }
        if src.rendering == .rendered, let img = thumbMemory.object(forKey: key(src.file, .embedded) as NSString)?.image { return (img, false) }
        if let img = quickMemory.object(forKey: quickSource(for: item).cacheKey as NSString)?.image { return (img, false) }
        return nil
    }

    /// Loads an item's thumbnail progressively: `progress` receives quicker, lower-quality versions first
    /// (tiny embedded thumbnail; camera preview while a True RAW render is pending). Returns the final image.
    public func thumbnail(for item: ItemFiles, priority: Operation.QueuePriority = .high,
                          progress: @escaping @Sendable (CGImage) -> Void = { _ in }) async -> CGImage? {
        let src = thumbnailSource(for: item)
        let finalKey = key(src.file, src.rendering)
        for k in finalKeys(for: item) {
            if let img = thumbMemory.object(forKey: k as NSString)?.image {
                record { $0.thumbRequests += 1; $0.thumbMemoryHits += 1 }
                return img
            }
        }
        if item.isPair, let raw = item.raw {
            let stable = key(raw, .embedded)
            if diskCache?.contains(key: stable) != true, let q = await quickThumbnail(quickSource(for: item)) { progress(q) }
            if Task.isCancelled { return nil }
            // The source is chosen when the job runs: JPEG while the RAW engine is cold, its embedded preview after.
            return await load(key: stable, queue: thumbLoads, priority: priority) { px in
                Self.rawEngineReady
                    ? ImageDecoder.thumbnail(for: raw, maxPixel: px, raw: .embedded)
                    : ImageDecoder.thumbnail(for: item.primary, maxPixel: px, raw: .embedded)
            }
        }
        if src.rendering == .rendered {
            // Camera preview right away, True RAW render afterwards on its own queue.
            if let e = await load(src.file, .embedded, queue: thumbLoads, priority: priority) { progress(e) }
            if Task.isCancelled { return nil }
            return await load(src.file, .rendered, queue: rawLoads, priority: priority)
        }
        let quick = quickSource(for: item)
        if !quick.kind.isRaw || Self.rawEngineReady, diskCache?.contains(key: finalKey) != true, let q = await quickThumbnail(quick) {
            progress(q)
        }
        if Task.isCancelled { return nil }
        return await load(src.file, src.rendering, queue: thumbLoads, priority: priority)
    }

    /// File for the ≈1 ms placeholder: the raster file when there is one (needs no RAW engine).
    private func quickSource(for item: ItemFiles) -> FileRef {
        item.files.first { $0.kind.isRaster } ?? item.primary
    }

    /// ≈1 ms: the small thumbnail embedded in the file (160 px for camera JPEGs). Placeholder only.
    func quickThumbnail(_ file: FileRef) async -> CGImage? {
        let k = file.cacheKey
        if let img = quickMemory.object(forKey: k as NSString)?.image { return img }
        let img = await quickLoads.load(key: k, priority: .veryHigh) { ImageDecoder.embeddedThumbnail(for: file) }
        if let img { quickMemory.setObject(ImageBox(img), forKey: k as NSString) }
        return img
    }

    private func load(_ file: FileRef, _ rendering: RawRendering, queue: LoadQueue, priority: Operation.QueuePriority) async -> CGImage? {
        await load(key: key(file, rendering), queue: queue, priority: priority) { px in
            ImageDecoder.thumbnail(for: file, maxPixel: px, raw: rendering)
        }
    }

    private func load(key k: String, queue: LoadQueue, priority: Operation.QueuePriority,
                      decode: @escaping @Sendable (Int) -> CGImage?) async -> CGImage? {
        record { $0.thumbRequests += 1 }
        if let img = thumbMemory.object(forKey: k as NSString)?.image {
            record { $0.thumbMemoryHits += 1 }
            return img
        }
        let px = thumbnailPixelSize
        let img = await queue.load(key: k, priority: priority) { [weak self] in
            guard let self else { return nil }
            if let d = self.diskCache?.read(key: k) {
                self.record { $0.thumbDiskHits += 1 }
                return d
            }
            guard let t = decode(px) else {
                self.record { $0.failures += 1 }
                return nil
            }
            self.record { $0.thumbGenerated += 1 }
            self.diskCache?.write(t, key: k)
            return t
        }
        if let img { thumbMemory.setObject(ImageBox(img), forKey: k as NSString, cost: img.bytesPerRow * img.height) }
        return img
    }

    // MARK: Warm-up

    private static let warmLock = NSLock()
    nonisolated(unsafe) private static var warmed = false
    nonisolated(unsafe) private static var _rawEngineReady = false
    /// True once ImageIO's RAW support has been loaded in this process.
    public static var rawEngineReady: Bool { warmLock.withLock { _rawEngineReady } }

    /// The first RAW a process touches pays a one-time cost (≈5 s for ImageIO's RAW support, ≈7 s for the
    /// first Core Image RAW render on an M2). Paying it in the background right after a folder opens means
    /// the first photo the user looks at is fast.
    public static func warmUpRaw(with file: FileRef) {
        guard file.kind.isRaw else { return }
        let first = warmLock.withLock { () -> Bool in
            if warmed { return false }
            warmed = true
            return true
        }
        guard first else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ImageDecoder.thumbnail(for: file, maxPixel: 64, raw: .embedded)
            warmLock.withLock { _rawEngineReady = true }
        }
        DispatchQueue.global(qos: .utility).async { _ = ImageDecoder.thumbnail(for: file, maxPixel: 64, raw: .rendered) }
    }

    // MARK: Screen previews

    private func previewKey(_ file: FileRef, _ maxPixel: Int) -> String { "\(renderKey(file))#\(maxPixel)" }

    public func cachedPreview(_ file: FileRef, maxPixel: Int) -> CGImage? {
        previewMemory.object(forKey: previewKey(file, maxPixel) as NSString)?.image
    }

    public func preview(_ file: FileRef, maxPixel: Int, priority: Operation.QueuePriority = .high) async -> CGImage? {
        record { $0.previewRequests += 1 }
        let key = previewKey(file, maxPixel)
        if let img = previewMemory.object(forKey: key as NSString)?.image {
            record { $0.previewHits += 1 }
            return img
        }
        let raw = rawRendering
        let queue = file.kind.isRaw && raw == .rendered ? rawLoads : previewLoads
        let img = await queue.load(key: key, priority: priority) { [weak self] in
            let t0 = DispatchTime.now()
            let img = ImageDecoder.preview(for: file, maxPixel: maxPixel, raw: raw)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            self?.record { s in
                s.previewDecodes += 1
                s.lastPreviewMs = ms
                s.avgPreviewMs += (ms - s.avgPreviewMs) / Double(s.previewDecodes)
                if img == nil { s.failures += 1 }
            }
            return img
        }
        if let img { previewMemory.setObject(ImageBox(img), forKey: key as NSString) }
        return img
    }

    /// Keeps only the given previews in flight (prefetch window); stale prefetches are cancelled.
    public func prefetchPreviews(_ files: [FileRef], maxPixel: Int) {
        let keys = Set(files.map { previewKey($0, maxPixel) })
        previewLoads.cancelAll(except: keys)
        rawLoads.cancelAll(except: keys.union(rawThumbKeysInFlight()))
        for f in files where cachedPreview(f, maxPixel: maxPixel) == nil {
            Task.detached(priority: .utility) { [weak self] in
                _ = await self?.preview(f, maxPixel: maxPixel, priority: .normal)
            }
        }
    }

    // MARK: Full resolution

    public func cachedFullResolution(_ file: FileRef) -> CGImage? {
        fullMemory.object(forKey: file.cacheKey as NSString)?.image
    }

    public func fullResolution(_ file: FileRef) async -> CGImage? {
        let key = file.cacheKey
        if let img = fullMemory.object(forKey: key as NSString)?.image { return img }
        fullLoads.cancelAll(except: [key])
        let img = await fullLoads.load(key: key, priority: .veryHigh) { [weak self] in
            let t0 = DispatchTime.now()
            let img = ImageDecoder.fullResolution(for: file)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            self?.record { $0.fullDecodes += 1; $0.lastFullMs = ms; if img == nil { $0.failures += 1 } }
            return img
        }
        if let img { fullMemory.setObject(ImageBox(img), forKey: key as NSString) }
        return img
    }

    /// Rendered RAW thumbnails share the RAW queue with previews; prefetch must not cancel them.
    private func rawThumbKeysInFlight() -> Set<String> { rawLoads.keys.filter { !$0.contains("#rendered#") } }

    public func clearMemory() {
        quickMemory.removeAllObjects()
        thumbMemory.removeAllObjects()
        previewMemory.removeAllObjects()
        fullMemory.removeAllObjects()
    }
}

final class ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ i: CGImage) { image = i }
}

// MARK: - Load queue

/// Bounded-concurrency loader that de-duplicates requests by key and cancels work nobody waits for anymore.
final class LoadQueue: @unchecked Sendable {
    private final class Job: Operation, @unchecked Sendable {
        let work: @Sendable () -> CGImage?
        var onDone: (@Sendable (CGImage?) -> Void)?
        init(work: @escaping @Sendable () -> CGImage?) { self.work = work }
        override func main() {
            guard !isCancelled else { return }
            let r = work()
            onDone?(r)
        }
    }

    private final class Entry {
        let job: Job
        var waiters: [UUID: CheckedContinuation<CGImage?, Never>] = [:]
        init(job: Job) { self.job = job }
    }

    private let queue = OperationQueue()
    private let lock = NSLock()
    private var inflight: [String: Entry] = [:]

    var keys: Set<String> { lock.withLock { Set(inflight.keys) } }

    init(name: String, maxConcurrent: Int) {
        queue.name = "PhotoCuller.\(name)"
        queue.maxConcurrentOperationCount = maxConcurrent
        queue.qualityOfService = .userInitiated
    }

    func load(key: String, priority: Operation.QueuePriority, work: @escaping @Sendable () -> CGImage?) async -> CGImage? {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    cont.resume(returning: nil)
                    return
                }
                if let e = inflight[key] {
                    e.waiters[token] = cont
                    if priority.rawValue > e.job.queuePriority.rawValue { e.job.queuePriority = priority }
                    lock.unlock()
                    return
                }
                let job = Job(work: work)
                job.queuePriority = priority
                let entry = Entry(job: job)
                entry.waiters[token] = cont
                inflight[key] = entry
                job.onDone = { [weak self, weak job] img in
                    guard let self, let job else { return }
                    self.finish(key: key, job: job, image: img)
                }
                lock.unlock()
                queue.addOperation(job)
            }
        } onCancel: {
            self.cancel(key: key, token: token)
        }
    }

    private func finish(key: String, job: Job, image: CGImage?) {
        lock.lock()
        guard let e = inflight[key], e.job === job else { lock.unlock(); return }
        inflight[key] = nil
        let waiters = e.waiters.values
        lock.unlock()
        for w in waiters { w.resume(returning: image) }
    }

    private func cancel(key: String, token: UUID) {
        lock.lock()
        guard let e = inflight[key], let w = e.waiters.removeValue(forKey: token) else { lock.unlock(); return }
        if e.waiters.isEmpty {
            e.job.cancel()
            inflight[key] = nil
        }
        lock.unlock()
        w.resume(returning: nil)
    }

    /// Cancels a key for every waiter.
    func cancel(key: String) {
        lock.lock()
        guard let e = inflight.removeValue(forKey: key) else { lock.unlock(); return }
        e.job.cancel()
        let waiters = e.waiters.values
        lock.unlock()
        for w in waiters { w.resume(returning: nil) }
    }

    func cancelAll(except keep: Set<String>) {
        lock.lock()
        let drop = inflight.filter { !keep.contains($0.key) }
        for k in drop.keys { inflight[k] = nil }
        lock.unlock()
        for e in drop.values {
            e.job.cancel()
            for w in e.waiters.values { w.resume(returning: nil) }
        }
    }
}

// MARK: - Disk cache

/// Thumbnail disk cache in `~/Library/Caches/<bundle-id>/thumbs`, keyed by a hash of (path, size, mtime),
/// with LRU eviction by access time (spec §5.6).
public final class ThumbnailDiskCache: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var limitBytes: Int64
    private var writesSinceTrim = 0

    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(AppConstants.cacheDirectoryName, isDirectory: true)
            .appendingPathComponent("thumbs", isDirectory: true)
    }

    public init(directory: URL, limitBytes: Int64) throws {
        self.directory = directory
        self.limitBytes = limitBytes
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func setLimit(_ bytes: Int64) {
        lock.withLock { limitBytes = bytes }
        trim()
    }

    func fileURL(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent(digest).appendingPathExtension("jpg")
    }

    public func contains(key: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(key).path)
    }

    public func read(key: String) -> CGImage? {
        let url = fileURL(key)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        // LRU: bump the access time.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return img
    }

    public func write(_ image: CGImage, key: String) {
        let url = fileURL(key)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let shouldTrim = lock.withLock { () -> Bool in
            writesSinceTrim += 1
            if writesSinceTrim >= 500 { writesSinceTrim = 0; return true }
            return false
        }
        if shouldTrim { trim() }
    }

    public func currentSize() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    private func entries() -> [(url: URL, size: Int64, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var out: [(URL, Int64, Date)] = []
        for case let url as URL in e where url.pathExtension == "jpg" {
            let v = try? url.resourceValues(forKeys: Set(keys))
            out.append((url, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast))
        }
        return out
    }

    /// Evicts least-recently-used thumbnails until the cache is below 90% of the limit.
    public func trim() {
        let limit = lock.withLock { limitBytes }
        var all = entries()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        all.sort { $0.date < $1.date }
        let target = limit * 9 / 10
        for e in all where total > target {
            try? FileManager.default.removeItem(at: e.url)
            total -= e.size
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
