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
    private let thumbLoads: LoadQueue
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
    public func renderKey(_ file: FileRef) -> String {
        file.kind.isRaw && rawRendering == .rendered ? file.cacheKey + "#rendered" : file.cacheKey
    }

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
        thumbLoads = LoadQueue(name: "thumbnails", maxConcurrent: ProcessInfo.processInfo.activeProcessorCount)
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
        let img = await previewLoads.load(key: key, priority: priority) { [weak self] in
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

    public func clearMemory() {
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
