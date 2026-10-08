import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import CullerKit

final class XMPTests: XCTestCase {
    /// Spec §16 "XMP merge": changing the rating preserves all other content byte-for-meaning.
    func testSidecarMergePreservesForeignContent() throws {
        let dir = try TestSupport.tempDir()
        let sidecar = dir.appendingPathComponent("IMG_0001.xmp")
        try FileManager.default.copyItem(at: TestSupport.fixture("lightroom-sidecar.xmp"), to: sidecar)
        let before = TestSupport.flatten(CGImageMetadataCreateFromXMPData(try Data(contentsOf: sidecar) as CFData)!)
        XCTAssertGreaterThan(before.count, 15)

        try XMPCodec.writeSidecar(PhotoMetadata(flag: .pick, rating: 5, label: .green, note: "keeper"), to: sidecar)

        let after = TestSupport.flatten(CGImageMetadataCreateFromXMPData(try Data(contentsOf: sidecar) as CFData)!)
        let foreignBefore = before.filter { !TestSupport.ownedPaths.contains($0.key) }
        let foreignAfter = after.filter { !TestSupport.ownedPaths.contains($0.key) }
        XCTAssertEqual(foreignBefore, foreignAfter, "non-owned XMP properties must survive unchanged")
        XCTAssertEqual(XMPCodec.readSidecar(sidecar)?.resolved, PhotoMetadata(flag: .pick, rating: 5, label: .green, note: "keeper"))

        // Clearing owned fields removes them and still leaves everything else alone.
        try XMPCodec.writeSidecar(.empty, to: sidecar)
        let cleared = TestSupport.flatten(CGImageMetadataCreateFromXMPData(try Data(contentsOf: sidecar) as CFData)!)
        XCTAssertTrue(cleared.keys.allSatisfy { !TestSupport.ownedPaths.contains($0) })
        XCTAssertEqual(cleared, foreignBefore)
    }

    func testReadsLightroomRatingAndLabel() throws {
        let p = XMPCodec.readSidecar(TestSupport.fixture("lightroom-sidecar.xmp"))
        XCTAssertEqual(p?.rating, 2)
        XCTAssertEqual(p?.label, .yellow)
        XCTAssertNil(p?.flag)
    }

    /// Spec §16 "Lossless embed": decoded pixels identical before/after writing metadata (JPEG + HEIC + TIFF).
    func testEmbeddedWriteIsLossless() throws {
        let dir = try TestSupport.tempDir()
        for (ext, type) in [("jpg", UTType.jpeg), ("heic", UTType.heic), ("tif", UTType.tiff)] {
            let url = TestSupport.makeImage(dir.appendingPathComponent("a.\(ext)"), type: type)
            let pixels = TestSupport.decodedPixels(url)
            let exifBefore = ExifReader.read(url)

            let m = PhotoMetadata(flag: .reject, rating: 3, label: .red, note: "soft focus")
            try XMPCodec.writeEmbedded(m, to: url)
            XCTAssertEqual(XMPCodec.readEmbedded(url)?.resolved, m, ext)
            XCTAssertEqual(TestSupport.decodedPixels(url), pixels, "\(ext) pixels changed")
            XCTAssertEqual(ExifReader.read(url)?.lens, exifBefore?.lens, "\(ext) EXIF lost")

            // Clear everything again.
            try XMPCodec.writeEmbedded(.empty, to: url)
            XCTAssertEqual(XMPCodec.readEmbedded(url)?.resolved, .empty, ext)
            XCTAssertEqual(TestSupport.decodedPixels(url), pixels, "\(ext) pixels changed on clear")
        }
    }

    func testEmbeddedWriteSkipsUnchangedFile() throws {
        let dir = try TestSupport.tempDir()
        let url = TestSupport.makeImage(dir.appendingPathComponent("a.jpg"))
        let m = PhotoMetadata(rating: 2)
        try XMPCodec.writeEmbedded(m, to: url)
        let data = try Data(contentsOf: url)
        try XMPCodec.writeEmbedded(m, to: url)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    /// Spec §16 "Atomicity": a simulated failure mid-write leaves the original unchanged.
    func testFailedWriteLeavesOriginalUntouched() throws {
        let dir = try TestSupport.tempDir()
        let jpg = TestSupport.makeImage(dir.appendingPathComponent("a.jpg"))
        let sidecar = dir.appendingPathComponent("b.xmp")
        try FileManager.default.copyItem(at: TestSupport.fixture("lightroom-sidecar.xmp"), to: sidecar)
        let jpgBytes = try Data(contentsOf: jpg)
        let scBytes = try Data(contentsOf: sidecar)

        let fail: AtomicFile.BeforeReplaceHook = { _ in throw AtomicFileError.injectedFailure }
        XCTAssertThrowsError(try XMPCodec.writeEmbedded(PhotoMetadata(rating: 4), to: jpg, beforeReplace: fail))
        XCTAssertThrowsError(try XMPCodec.writeSidecar(PhotoMetadata(rating: 4), to: sidecar, beforeReplace: fail))

        XCTAssertEqual(try Data(contentsOf: jpg), jpgBytes)
        XCTAssertEqual(try Data(contentsOf: sidecar), scBytes)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("culler-tmp") }
        XCTAssertEqual(leftovers, [], "temp files must be cleaned up")
    }

    func testAtomicReplacePreservesOtherXattrs() throws {
        let dir = try TestSupport.tempDir()
        let jpg = TestSupport.makeImage(dir.appendingPathComponent("a.jpg"))
        XAttr.set("com.example.keep", data: Data("x".utf8), at: jpg)
        try XMPCodec.writeEmbedded(PhotoMetadata(rating: 1), to: jpg)
        XCTAssertEqual(XAttr.get("com.example.keep", at: jpg), Data("x".utf8))
    }

    func testForeignPrefixForCullerNamespaceIsRead() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:pc="\(AppConstants.xmpNamespaceURI)" pc:Flag="reject" pc:Note="hi"/>
        </rdf:RDF></x:xmpmeta>
        """
        let dir = try TestSupport.tempDir()
        let url = dir.appendingPathComponent("x.xmp")
        try Data(xml.utf8).write(to: url)
        XCTAssertEqual(XMPCodec.readSidecar(url)?.flag, .reject)
        try XMPCodec.writeSidecar(PhotoMetadata(flag: .pick), to: url)
        XCTAssertEqual(XMPCodec.readSidecar(url)?.flag, .pick)
        XCTAssertNil(XMPCodec.readSidecar(url)?.note)
    }
}
