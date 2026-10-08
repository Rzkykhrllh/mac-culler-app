import XCTest
import CoreGraphics
import CoreImage
@testable import CullerKit

final class FocusTests: XCTestCase {
    func detailed(blur: Bool) -> CGImage {
        let w = 800, h = 600
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
        for y in stride(from: 0, to: h, by: 8) { for x in stride(from: (y / 8) % 2 * 8, to: w, by: 16) { ctx.fill(CGRect(x: x, y: y, width: 8, height: 8)) } }
        let img = ctx.makeImage()!
        guard blur else { return img }
        let ci = CIImage(cgImage: img).applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3]).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        return CIContext().createCGImage(ci, from: ci.extent)!
    }

    func testSharpScoresHigherThanBlurred() {
        let sharp = FocusAnalyzer.analyze(detailed(blur: false))
        let soft = FocusAnalyzer.analyze(detailed(blur: true))
        XCTAssertGreaterThan(sharp.sharpness, soft.sharpness + 5, "\(sharp.sharpness) vs \(soft.sharpness)")
        XCTAssertTrue(sharp.subjects.isEmpty)
    }

    func testSharpestInStackNeedsWholeStackAndMargin() {
        let a = PhotoAnalysis(sharpness: 70, energy: 1, subjects: []), b = PhotoAnalysis(sharpness: 60, energy: 1, subjects: [])
        let c = PhotoAnalysis(sharpness: 69.9, energy: 1, subjects: [])
        XCTAssertEqual(FocusAnalyzer.sharpest(in: [["a", "b"]], analysis: ["a": a, "b": b]), ["a"])
        XCTAssertEqual(FocusAnalyzer.sharpest(in: [["a", "c"]], analysis: ["a": a, "c": c]), [], "too close to call")
        XCTAssertEqual(FocusAnalyzer.sharpest(in: [["a", "b", "x"]], analysis: ["a": a, "b": b]), [], "not fully analyzed yet")
        XCTAssertEqual(FocusAnalyzer.sharpest(in: [["a"]], analysis: ["a": a]), [], "singles have no 'sharpest'")
    }

    /// Left half sharp checkerboard, right half the same blurred: peaking must light up the left only.
    func testPeakingMarksSharpNotBlurred() throws {
        let sharp = detailed(blur: false), soft = detailed(blur: true)
        let w = sharp.width, h = sharp.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(sharp, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.clip(to: CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        ctx.draw(soft, in: CGRect(x: 0, y: 0, width: w, height: h))
        let peak = try XCTUnwrap(FocusOverlays.peaking(ctx.makeImage()!))
        let left = FocusOverlays.coverage(peak, in: CGRect(x: 0.05, y: 0.1, width: 0.4, height: 0.8))
        let right = FocusOverlays.coverage(peak, in: CGRect(x: 0.55, y: 0.1, width: 0.4, height: 0.8))
        XCTAssertGreaterThan(left, 0.2, "sharp half lit")
        XCTAssertLessThan(right, left / 5, "blurred half mostly dark (\(right) vs \(left))")
    }

    func testClippingFlagsOnlyExtremes() throws {
        let w = 300, h = 100
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (i, g) in [CGFloat(0), 0.2, 1].enumerated() {   // black · dark grey (not clipped) · white
            ctx.setFillColor(CGColor(gray: g, alpha: 1))
            ctx.fill(CGRect(x: i * 100, y: 0, width: 100, height: h))
        }
        let clip = try XCTUnwrap(FocusOverlays.clipping(ctx.makeImage()!))
        XCTAssertGreaterThan(FocusOverlays.coverage(clip, in: CGRect(x: 0.02, y: 0.1, width: 0.3, height: 0.8)), 0.95, "black flagged")
        XCTAssertEqual(FocusOverlays.coverage(clip, in: CGRect(x: 0.36, y: 0.1, width: 0.28, height: 0.8)), 0, "dark grey is not clipped")
        XCTAssertGreaterThan(FocusOverlays.coverage(clip, in: CGRect(x: 0.68, y: 0.1, width: 0.3, height: 0.8)), 0.95, "white flagged")
    }

    func testSubjectFocusPoint() {
        let face = PhotoAnalysis.Subject(kind: .face, label: nil, rect: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3),
                                         eyes: [CGPoint(x: 0.45, y: 0.3), CGPoint(x: 0.55, y: 0.32)], confidence: 1)
        XCTAssertEqual(face.focusPoint.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(face.focusPoint.y, 0.31, accuracy: 0.001)
        let cat = PhotoAnalysis.Subject(kind: .animal, label: "Cat", rect: CGRect(x: 0, y: 0.5, width: 0.4, height: 0.4), eyes: [], confidence: 1)
        XCTAssertEqual(cat.focusPoint.y, 0.62, accuracy: 0.001, "head = upper part of the animal box")
    }

    func testAnalysisCachedInIndex() throws {
        let dir = try TestSupport.tempDir()
        let f = try XCTUnwrap(FileRef.load(TestSupport.makeImage(dir.appendingPathComponent("a.jpg"))))
        let index = try IndexStore()
        let a = PhotoAnalysis(sharpness: 42, energy: 3, subjects: [])
        index.storeAnalysis([(f, a)])
        XCTAssertEqual(index.cachedAnalysis(for: [f])[f.path], a)
    }
}
