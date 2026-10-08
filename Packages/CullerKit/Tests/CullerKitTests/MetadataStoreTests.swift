import XCTest
@testable import CullerKit

final class MetadataStoreTests: XCTestCase {
    func testPairWritesSidecarAndEmbeddedInSync() throws {
        let dir = try TestSupport.tempDir()
        TestSupport.makeFakeRaw(dir.appendingPathComponent("IMG_0001.CR3"))
        TestSupport.makeImage(dir.appendingPathComponent("IMG_0001.JPG"))
        let item = try XCTUnwrap(TestSupport.items(dir).first)
        XCTAssertTrue(item.isPair)

        let m = PhotoMetadata(flag: .pick, rating: 4, label: .blue, note: "n")
        let updated = try MetadataStore.write(m, to: item)
        XCTAssertEqual(updated.sidecarURL?.lastPathComponent, "IMG_0001.xmp")
        XCTAssertEqual(XMPCodec.readSidecar(updated.sidecarURL!)?.resolved, m)
        XCTAssertEqual(XMPCodec.readEmbedded(dir.appendingPathComponent("IMG_0001.JPG"))?.resolved, m)
        XCTAssertEqual(MetadataStore.readBackup(updated)?.metadata, m)
        XCTAssertEqual(MetadataStore.read(updated).metadata, m)
        // xattr on both files of the pair
        for f in updated.files { XCTAssertNotNil(XAttr.get(AppConstants.xattrName, at: f.url)) }
    }

    /// Spec §16 "xattr recovery": delete a RAW's sidecar → reopen folder → sidecar regenerated from xattr.
    func testSidecarRegeneratedFromXattr() throws {
        let dir = try TestSupport.tempDir()
        TestSupport.makeFakeRaw(dir.appendingPathComponent("DSC_1.NEF"))
        let item = try XCTUnwrap(TestSupport.items(dir).first)
        let m = PhotoMetadata(flag: .reject, rating: 1, label: .purple, note: "blink")
        let written = try MetadataStore.write(m, to: item)
        try FileManager.default.removeItem(at: written.sidecarURL!)

        let reopened = try XCTUnwrap(TestSupport.items(dir).first)
        XCTAssertNil(reopened.sidecarURL)
        let r = MetadataStore.read(reopened)
        XCTAssertEqual(r.metadata, m)
        XCTAssertEqual(r.recoveredSidecar?.lastPathComponent, "DSC_1.xmp")
        XCTAssertEqual(XMPCodec.readSidecar(dir.appendingPathComponent("DSC_1.xmp"))?.resolved, m)
    }

    func testXMPWinsOverXattrWhenBothExist() throws {
        let dir = try TestSupport.tempDir()
        TestSupport.makeFakeRaw(dir.appendingPathComponent("A.ARW"))
        let item = try MetadataStore.write(PhotoMetadata(rating: 2), to: try XCTUnwrap(TestSupport.items(dir).first))
        // Another app edits the sidecar.
        try XMPCodec.writeSidecar(PhotoMetadata(rating: 5, label: .red), to: item.sidecarURL!)
        let r = MetadataStore.read(try XCTUnwrap(TestSupport.items(dir).first))
        XCTAssertEqual(r.metadata.rating, 5)
        XCTAssertEqual(r.metadata.label, .red)
        XCTAssertNil(r.recoveredSidecar)
    }

    func testFinderTagsOnlyTouchOwnColorTags() throws {
        let dir = try TestSupport.tempDir()
        let url = TestSupport.makeImage(dir.appendingPathComponent("a.jpg"))
        try (url as NSURL).setResourceValue(["Client", "Red"], forKey: .tagNamesKey)
        FinderTags.apply(label: .green, to: url)
        var tags = try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        XCTAssertEqual(Set(tags), ["Client", "Green"])
        FinderTags.apply(label: .none, to: url)
        tags = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        XCTAssertEqual(tags, ["Client"])
    }

    func testWriteQueueCoalescesRapidChanges() async throws {
        let dir = try TestSupport.tempDir()
        let url = TestSupport.makeImage(dir.appendingPathComponent("a.jpg"))
        let item = try XCTUnwrap(TestSupport.items(dir).first)
        let events = EventBox()
        let q = MetadataWriteQueue(debounce: .milliseconds(100)) { events.append($0) }
        for r in 1...5 { await q.enqueue(itemID: "a", files: item, metadata: PhotoMetadata(rating: r)) }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(events.count, 1, "five rapid changes → one write")
        XCTAssertEqual(XMPCodec.readEmbedded(url)?.rating, 5)

        await q.enqueue(itemID: "a", files: item, metadata: PhotoMetadata(rating: 2))
        await q.flush()
        XCTAssertEqual(XMPCodec.readEmbedded(url)?.rating, 2)
    }

    func testWriteFailureIsReported() async throws {
        let dir = try TestSupport.tempDir()
        TestSupport.makeImage(dir.appendingPathComponent("a.jpg"))
        let item = try XCTUnwrap(TestSupport.items(dir).first)
        try FileManager.default.removeItem(at: item.primary.url)
        let events = EventBox()
        let q = MetadataWriteQueue(debounce: .milliseconds(10)) { events.append($0) }
        await q.enqueue(itemID: "a", files: item, metadata: PhotoMetadata(rating: 3))
        await q.flush()
        guard case .failed(_, let m, _)? = events.last else { return XCTFail("expected failure event") }
        XCTAssertEqual(m.rating, 3)
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MetadataWriteQueue.Event] = []
    func append(_ e: MetadataWriteQueue.Event) { lock.withLock { events.append(e) } }
    var count: Int { lock.withLock { events.count } }
    var last: MetadataWriteQueue.Event? { lock.withLock { events.last } }
}
