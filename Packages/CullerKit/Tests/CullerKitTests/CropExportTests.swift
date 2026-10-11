import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import CullerKit

final class CropExportTests: XCTestCase {
    /// Solid red image.
    private func red(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// RGB of a pixel, (0,0) = top-left.
    private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (Int(p[0]), Int(p[1]), Int(p[2]))
    }

    private func isWhite(_ c: (Int, Int, Int)) -> Bool { c.0 > 240 && c.1 > 240 && c.2 > 240 }
    private func isRed(_ c: (Int, Int, Int)) -> Bool { c.0 > 200 && c.1 < 40 && c.2 < 40 }

    func testBorderTenPercentOfShorterSide() {
        var o = ExportOptions.twitter
        o.size = .original
        let out = PhotoExporter.render(red(600, 400), crop: nil, options: o)!
        XCTAssertEqual(out.width, 680)   // 40 px (10% of 400) on each side
        XCTAssertEqual(out.height, 480)
        XCTAssertTrue(isWhite(pixel(out, 5, 5)))
        XCTAssertTrue(isWhite(pixel(out, 675, 240)))
        XCTAssertTrue(isRed(pixel(out, 340, 240)))
        XCTAssertTrue(isRed(pixel(out, 45, 45)))
    }

    func testInstagramCanvasPadsLandscapeToFourFive() {
        let out = PhotoExporter.render(red(600, 400), crop: nil, options: .instagram)!
        XCTAssertEqual(out.width, 1080)
        XCTAssertEqual(out.height, 1350)
        XCTAssertTrue(isWhite(pixel(out, 540, 20)), "bar above")
        XCTAssertTrue(isWhite(pixel(out, 540, 1330)), "bar below")
        XCTAssertTrue(isRed(pixel(out, 540, 675)))
        XCTAssertTrue(isRed(pixel(out, 5, 675)), "full width")
    }

    func testFourFiveCropFillsInstagramCanvas() {
        let size = CGSize(width: 600, height: 400)
        let crop = CropGeometry.largest(ratio: 4.0 / 5.0, angle: 0, imageSize: size, aspect: "4:5")
        XCTAssertEqual(CropGeometry.outputSize(of: crop, imageSize: size), CGSize(width: 320, height: 400))
        let out = PhotoExporter.render(red(600, 400), crop: crop, options: .instagram)!
        XCTAssertEqual(out.width, 1080)
        XCTAssertEqual(out.height, 1350)
        XCTAssertTrue(isRed(pixel(out, 540, 3)), "no bars")
        XCTAssertTrue(isRed(pixel(out, 3, 675)))
    }

    func testNearlyFourFiveCropHasNoHairlineBar() {
        let size = CGSize(width: 601, height: 401)
        let crop = CropGeometry.largest(ratio: 4.0 / 5.0, angle: 0, imageSize: size, aspect: "4:5")
        let out = PhotoExporter.render(red(601, 401), crop: crop, options: .instagram)!
        for x in [0, 540, 1079] {
            XCTAssertTrue(isRed(pixel(out, x, 0)) && isRed(pixel(out, x, 1349)), "edge row at x \(x)")
        }
        XCTAssertTrue(isRed(pixel(out, 0, 675)) && isRed(pixel(out, 1079, 675)))
    }

    func testLongEdgeNeverUpscales() {
        XCTAssertEqual(PhotoExporter.finalSize(canvas: CGSize(width: 1000, height: 800), size: .longEdge(4096)), CGSize(width: 1000, height: 800))
        XCTAssertEqual(PhotoExporter.finalSize(canvas: CGSize(width: 8000, height: 6000), size: .longEdge(4096)), CGSize(width: 4096, height: 3072))
    }

    func testStraightenedCropStaysInsideThePhoto() {
        let size = CGSize(width: 600, height: 400)
        for angle in [-30.0, -7, 3, 12, 45] {
            let c = CropGeometry.largest(ratio: 1, angle: angle, imageSize: size, aspect: "1:1")
            XCTAssertTrue(CropGeometry.fits(c, imageSize: size), "\(angle)°")
            XCTAssertGreaterThan(c.width, 0.2)
            // Whole result is photo (red), no transparent / filled corners.
            let out = PhotoExporter.render(red(600, 400), crop: c, options: ExportOptions(frame: .none, size: .original, suffix: ""))!
            XCTAssertTrue(isRed(pixel(out, 1, 1)) && isRed(pixel(out, out.width - 2, out.height - 2)), "\(angle)°")
        }
        let tooBig = CropSpec(x: 0, y: 0, width: 1, height: 1, angle: 10)
        XCTAssertFalse(CropGeometry.fits(tooBig, imageSize: size))
        XCTAssertTrue(CropGeometry.fits(CropGeometry.shrinkToFit(tooBig, imageSize: size), imageSize: size))
    }

    func testCameraRawCropFollowsStoredOrientation() {
        let c = CropSpec(x: 0.1, y: 0.2, width: 0.5, height: 0.6)   // L .1 T .2 R .6 B .8
        let up = CropGeometry.cameraRawCrop(c, orientation: 1)!
        XCTAssertEqual(up.left, 0.1, accuracy: 1e-9); XCTAssertEqual(up.bottom, 0.8, accuracy: 1e-9)
        let r6 = CropGeometry.cameraRawCrop(c, orientation: 6)!   // portrait shot stored landscape (rotate 90° CW to view)
        XCTAssertEqual(r6.left, 0.2, accuracy: 1e-9); XCTAssertEqual(r6.top, 0.4, accuracy: 1e-9)
        XCTAssertEqual(r6.right, 0.8, accuracy: 1e-9); XCTAssertEqual(r6.bottom, 0.9, accuracy: 1e-9)
        XCTAssertNil(CropGeometry.cameraRawCrop(CropSpec(width: 0.5, height: 0.5, angle: 4), orientation: 1))
    }

    func testCropRoundTripsThroughSidecarAndEmbeddedXMP() throws {
        let dir = try TestSupport.tempDir()
        let crop = CropSpec(x: 0.125, y: 0, width: 0.5, height: 1, angle: 0, aspect: "4:5")
        var m = PhotoMetadata(rating: 3)
        m.crop = crop

        let sidecar = dir.appendingPathComponent("A.xmp")
        try XMPCodec.writeSidecar(m, to: sidecar)
        XCTAssertEqual(XMPCodec.readSidecar(sidecar)?.crop, crop)
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(text.contains("HasCrop") && text.contains("CropLeft"), "Lightroom crop fields written")

        let jpg = TestSupport.makeImage(dir.appendingPathComponent("A.jpg"))
        try XMPCodec.writeEmbedded(m, to: jpg)
        XCTAssertEqual(XMPCodec.readEmbedded(jpg)?.crop, crop)
        XCTAssertEqual(XMPCodec.readEmbedded(jpg)?.rating, 3)

        // Clearing the crop removes ours and turns Lightroom's off; the rating stays.
        m.crop = nil
        try XMPCodec.writeSidecar(m, to: sidecar)
        XCTAssertNil(XMPCodec.readSidecar(sidecar)?.crop)
        XCTAssertEqual(XMPCodec.readSidecar(sidecar)?.rating, 3)
        XCTAssertTrue(try String(contentsOf: sidecar, encoding: .utf8).contains("False"))
        try XMPCodec.writeEmbedded(m, to: jpg)
        XCTAssertNil(XMPCodec.readEmbedded(jpg)?.crop)
    }

    func testExportWritesJPEGNextToNothingElse() throws {
        let dir = try TestSupport.tempDir()
        let src = TestSupport.makeImage(dir.appendingPathComponent("IMG_1.jpg"))
        let item = ItemFiles(files: [FileRef.load(src)!])
        let out = dir.appendingPathComponent("Exports")
        let url = try PhotoExporter.export(item, crop: nil, options: .twitter, to: out)
        XCTAssertEqual(url.lastPathComponent, "IMG_1-x.jpg")
        let again = try PhotoExporter.export(item, crop: nil, options: .twitter, to: out)
        XCTAssertEqual(again.lastPathComponent, "IMG_1-x 2.jpg", "never overwrites")
        let s = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as! [CFString: Any]
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 96 + 2 * 6)   // 10% of 64 ≈ 6
        XCTAssertNotNil((props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifLensModel], "EXIF kept")
    }
}

final class CropStoreTests: XCTestCase {
    func testCropSurvivesMetadataStoreWriteAndRead() throws {
        let dir = try TestSupport.tempDir()
        let jpg = TestSupport.makeImage(dir.appendingPathComponent("B.jpg"))
        let item = ItemFiles(files: [FileRef.load(jpg)!])
        var m = PhotoMetadata(flag: .pick)
        m.crop = CropSpec(x: 0.1, y: 0, width: 0.5, height: 1, aspect: "4:5")
        try MetadataStore.write(m, to: item)
        XCTAssertEqual(MetadataStore.read(item, recover: false).metadata, m)
    }
}
