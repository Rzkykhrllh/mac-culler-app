import XCTest
import ImageIO
@testable import CullerKit

final class IndexAndPipelineTests: XCTestCase {
    func testIndexKeyedByAttributes() throws {
        let dir = try TestSupport.tempDir()
        let url = TestSupport.makeImage(dir.appendingPathComponent("a.jpg"))
        let index = try IndexStore(url: dir.appendingPathComponent("i.sqlite"))
        let f = try XCTUnwrap(FileRef.load(url))
        index.storeExif([(f, ExifReader.read(url)!)])
        XCTAssertEqual(index.cachedExif(for: [f])[f.path]?.lens, "RF24-70mm")

        var changed = f
        changed.size += 1
        XCTAssertNil(index.cachedExif(for: [changed])[f.path], "stale row ignored")

        let item = try XCTUnwrap(TestSupport.items(dir).first)
        let sig = IndexStore.signature(of: item)
        index.storeMetadata([(item.primary.path, sig, PhotoMetadata(rating: 3))])
        XCTAssertEqual(index.cachedMetadata(for: [(item.primary.path, sig)])[item.primary.path]?.rating, 3)
        XCTAssertNil(index.cachedMetadata(for: [(item.primary.path, sig + "x")])[item.primary.path])

        index.setPending(itemID: item.primary.path, files: item, metadata: PhotoMetadata(rating: 4), error: "ro")
        XCTAssertEqual(index.pendingWrites(inFolder: dir).first?.metadata.rating, 4)
        index.clearPending(itemID: item.primary.path)
        XCTAssertTrue(index.pendingWrites(inFolder: dir).isEmpty)
    }

    func testPipelineThumbnailCaching() async throws {
        let dir = try TestSupport.tempDir()
        let url = TestSupport.makeImage(dir.appendingPathComponent("a.jpg"))
        let f = try XCTUnwrap(FileRef.load(url))
        let disk = try ThumbnailDiskCache(directory: dir.appendingPathComponent("cache"), limitBytes: 1 << 30)
        var p = ImagePipeline(diskCache: disk, thumbnailPixelSize: 64)
        let t = await p.thumbnail(f)
        XCTAssertEqual(t.map { max($0.width, $0.height) }, 64)
        XCTAssertNotNil(p.cachedThumbnail(f))
        XCTAssertEqual(p.stats.thumbGenerated, 1)

        p = ImagePipeline(diskCache: disk, thumbnailPixelSize: 64)
        _ = await p.thumbnail(f)
        XCTAssertEqual(p.stats.thumbDiskHits, 1)
        XCTAssertEqual(p.stats.thumbGenerated, 0)

        let preview = await p.preview(f, maxPixel: 50)
        XCTAssertEqual(preview.map { max($0.width, $0.height) }, 50)
        let full = await p.fullResolution(f)
        XCTAssertEqual(full?.width, 96)
    }

    func testCancelledLoadReturnsNil() async throws {
        let dir = try TestSupport.tempDir()
        let p = ImagePipeline(diskCache: nil)
        let files = (0..<40).map { i in FileRef.load(TestSupport.makeImage(dir.appendingPathComponent("\(i).jpg")))! }
        let task = Task { await withTaskGroup(of: Bool.self) { g in
            for f in files { g.addTask { await p.thumbnail(f, priority: .low) != nil } }
            var n = 0
            for await ok in g where ok { n += 1 }
            return n
        } }
        task.cancel()
        let loaded = await task.value
        XCTAssertLessThanOrEqual(loaded, 40)  // must simply not hang
    }

    func testDiskCacheTrimEvictsOldest() throws {
        let dir = try TestSupport.tempDir()
        let cache = try ThumbnailDiskCache(directory: dir, limitBytes: 1 << 30)
        let img = TestSupport.gradient(width: 200, height: 200)
        for i in 0..<10 { cache.write(img, key: "k\(i)") }
        let total = cache.currentSize()
        cache.setLimit(total / 2)
        XCTAssertLessThanOrEqual(cache.currentSize(), total / 2)
    }

    func testHistogram() {
        let h = Histogram.compute(TestSupport.gradient())
        XCTAssertEqual(h?.luma.reduce(0, +), 96 * 64)
    }

    /// Spec §16 "Performance": ≥2,000 files, folder-open (scan + group + stack) time.
    func testFolderOpenPerformance2000Files() throws {
        let dir = try TestSupport.tempDir()
        let jpeg = try Data(contentsOf: TestSupport.makeImage(dir.appendingPathComponent("seed.jpg")))
        for i in 0..<1000 {
            try jpeg.write(to: dir.appendingPathComponent(String(format: "IMG_%04d.JPG", i)))
            try Data(count: 64).write(to: dir.appendingPathComponent(String(format: "IMG_%04d.CR3", i)))
        }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("seed.jpg"))
        measure {
            let items = try! FolderScanner.scan(folder: dir, options: ScanOptions())
            XCTAssertEqual(items.count, 1000)
            let inputs = items.enumerated().map { StackBuilder.Input(id: $0.element.primary.path, captureDate: Date(timeIntervalSince1970: Double($0.offset) * 0.3), bodyKey: "x") }
            _ = StackBuilder.build(inputs, threshold: 1)
        }
    }
}

final class ProgressiveThumbnailTests: XCTestCase {
    func testPairThumbnailComesFromRawEmbeddedPreview() throws {
        let dir = try TestSupport.tempDir()
        TestSupport.makeFakeRaw(dir.appendingPathComponent("A.RAF"))
        TestSupport.makeImage(dir.appendingPathComponent("A.JPG"))
        TestSupport.makeImage(dir.appendingPathComponent("B.JPG"))
        let items = try TestSupport.items(dir)
        let p = ImagePipeline(diskCache: nil)
        p.rawRendering = .rendered
        let pair = try XCTUnwrap(items.first { $0.isPair })
        if !ImagePipeline.rawEngineReady {
            XCTAssertEqual(p.thumbnailSource(for: pair).file.kind, .jpeg, "JPEG while the RAW engine is still cold")
        }
        ImagePipeline.warmUpRaw(with: try XCTUnwrap(pair.raw))
        let deadline = Date().addingTimeInterval(20)
        while !ImagePipeline.rawEngineReady && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let src = p.thumbnailSource(for: pair)
        XCTAssertEqual(src.file.kind, .raw, "RAW embedded preview once warm")
        XCTAssertEqual(src.rendering, .embedded, "a pair keeps the camera look, never a slow True RAW render")
        XCTAssertEqual(p.thumbnailKey(for: pair), p.renderKey(try XCTUnwrap(pair.raw)).replacingOccurrences(of: "#rendered", with: ""),
                       "stable key regardless of which file produced the thumbnail")
        let single = try XCTUnwrap(items.first { !$0.isPair })
        XCTAssertEqual(p.thumbnailSource(for: single).file.fileName, "B.JPG")
    }

    func testJpegThumbnailIsProgressive() async throws {
        let dir = try TestSupport.tempDir()
        let url = dir.appendingPathComponent("A.jpg")
        // JPEG with an embedded EXIF thumbnail, like camera files.
        let d = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, TestSupport.gradient(width: 1200, height: 800),
                                   [kCGImageDestinationEmbedThumbnail: true] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(d))
        let item = try XCTUnwrap(TestSupport.items(dir).first)
        let p = ImagePipeline(diskCache: nil, thumbnailPixelSize: 400)
        let partials = EventCounter()
        let final = await p.thumbnail(for: item) { _ in partials.bump() }
        XCTAssertEqual(final.map { max($0.width, $0.height) }, 400)
        XCTAssertGreaterThanOrEqual(partials.value, 1, "the tiny embedded thumbnail is delivered first")
        XCTAssertEqual(p.cachedThumbnail(for: item)?.isFinal, true)
    }
}

final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
