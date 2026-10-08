import XCTest
import ImageIO
@testable import CullerKit

/// Opt-in tests against real camera files (never modified: they are copied to a temp folder first).
/// Run with: CULLER_REAL_RAW_DIR=/path/to/shoot swift test --filter RealCameraFileTests
final class RealCameraFileTests: XCTestCase {
    private func realPair() throws -> (raw: URL, jpg: URL) {
        guard let dir = ProcessInfo.processInfo.environment["CULLER_REAL_RAW_DIR"] else {
            throw XCTSkip("Set CULLER_REAL_RAW_DIR to a folder with RAW+JPEG pairs")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir)
        guard let raw = names.sorted().first(where: { FileKind(pathExtension: ($0 as NSString).pathExtension)?.isRaw == true }) else {
            throw XCTSkip("No RAW files in \(dir)")
        }
        let base = (raw as NSString).deletingPathExtension
        guard let jpg = names.first(where: { ($0 as NSString).deletingPathExtension == base && FileKind(pathExtension: ($0 as NSString).pathExtension) == .jpeg }) else {
            throw XCTSkip("No JPEG paired with \(raw)")
        }
        let tmp = try TestSupport.tempDir()
        let r = tmp.appendingPathComponent(raw), j = tmp.appendingPathComponent(jpg)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: dir).appendingPathComponent(raw), to: r)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: dir).appendingPathComponent(jpg), to: j)
        return (r, j)
    }

    private func meanAbsDiff(_ a: CGImage, _ b: CGImage) -> Double {
        let w = 64, h = 64
        func px(_ i: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(i, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }
        let x = px(a), y = px(b)
        var s = 0
        for i in 0..<x.count where i % 4 != 3 { s += abs(Int(x[i]) - Int(y[i])) }
        return Double(s) / Double(w * h * 3)
    }

    func testTrueRawLooksDifferentFromCameraPreview() throws {
        let (raw, _) = try realPair()
        let f = try XCTUnwrap(FileRef.load(raw))
        let embedded = try XCTUnwrap(ImageDecoder.preview(for: f, maxPixel: 1200, raw: .embedded))
        let rendered = try XCTUnwrap(ImageDecoder.preview(for: f, maxPixel: 1200, raw: .rendered))
        XCTAssertEqual(Double(embedded.width) / Double(embedded.height), Double(rendered.width) / Double(rendered.height), accuracy: 0.02,
                       "same orientation / aspect")
        let d = meanAbsDiff(embedded, rendered)
        XCTAssertGreaterThan(d, 2, "True RAW render should differ visibly from the camera's preview (mean Δ \(d))")
    }

    func testPeakingOnRealPhotoFavorsSubject() throws {
        let (raw, _) = try realPair()
        let img = try XCTUnwrap(ImageDecoder.preview(for: try XCTUnwrap(FileRef.load(raw)), maxPixel: 2560, raw: .embedded))
        let peak = try XCTUnwrap(FocusOverlays.peaking(img))
        let total = FocusOverlays.coverage(peak)
        XCTAssertGreaterThan(total, 0.003, "something is in focus")
        XCTAssertLessThan(total, 0.3, "not everything is painted")
        let analysis = FocusAnalyzer.analyze(try XCTUnwrap(ImageDecoder.preview(for: try XCTUnwrap(FileRef.load(raw)), maxPixel: 1600, raw: .embedded)))
        if let subject = analysis.subjects.first {
            XCTAssertGreaterThan(FocusOverlays.coverage(peak, in: subject.rect), total, "the subject has more in-focus edges than the frame average")
        }
        let clip = try XCTUnwrap(FocusOverlays.clipping(img))
        XCTAssertLessThan(FocusOverlays.coverage(clip), 0.1, "a normal exposure is barely clipped")
    }

    func testRealPairPipelineAndFullDecode() async throws {
        let (raw, jpg) = try realPair()
        let item = try XCTUnwrap(TestSupport.items(raw.deletingLastPathComponent()).first { $0.isPair })
        XCTAssertEqual(item.primary.url.lastPathComponent, jpg.lastPathComponent)
        let p = ImagePipeline(diskCache: nil)
        let thumb = await p.thumbnail(for: item)
        XCTAssertEqual(thumb.map { max($0.width, $0.height) }, 400)
        let exif = try XCTUnwrap(ExifReader.read(raw))
        XCTAssertNotNil(exif.captureDate)
        let full = try XCTUnwrap(ImageDecoder.fullResolution(for: try XCTUnwrap(FileRef.load(raw))))
        XCTAssertGreaterThan(full.width * full.height, 10_000_000, "full RAW decode at sensor resolution")
    }

    func testMarksOnRealPairKeepFilesIntact() throws {
        let (raw, jpg) = try realPair()
        let rawBytes = try Data(contentsOf: raw)
        let pixels = TestSupport.decodedPixels(jpg)
        let item = try XCTUnwrap(TestSupport.items(raw.deletingLastPathComponent()).first { $0.isPair })
        let m = PhotoMetadata(flag: .pick, rating: 4, label: .green, note: "real file")
        let written = try MetadataStore.write(m, to: item)
        XCTAssertEqual(try Data(contentsOf: raw), rawBytes, "RAW file is never touched (sidecar only)")
        XCTAssertEqual(TestSupport.decodedPixels(jpg), pixels, "JPEG pixels unchanged after embedded XMP write")
        XCTAssertEqual(MetadataStore.read(written).metadata, m)
        XCTAssertNotNil(ExifReader.read(jpg)?.lens, "camera EXIF preserved")
    }
}
