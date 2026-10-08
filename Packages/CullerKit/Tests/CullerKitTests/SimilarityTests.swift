import XCTest
import CoreGraphics
@testable import CullerKit

final class SimilarityTests: XCTestCase {
    /// A "scene": colored background with a disc at an offset; small offsets = burst frames of the same scene.
    func scene(hue: CGFloat, offset: CGFloat, pattern: Bool = false) -> CGImage {
        let w = 400, h = 300
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: hue, green: 0.5 * hue + 0.2, blue: 1 - hue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if pattern {
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for i in stride(from: 0, to: w, by: 20) { ctx.fill(CGRect(x: i, y: 0, width: 10, height: h)) }
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 120 + offset, y: 90, width: 120, height: 120))
        return ctx.makeImage()!
    }

    func testFeaturePrintsSeparateScenes() throws {
        let a1 = try XCTUnwrap(FeaturePrints.compute(from: scene(hue: 0.2, offset: 0)).flatMap(FeaturePrints.observation))
        let a2 = try XCTUnwrap(FeaturePrints.compute(from: scene(hue: 0.2, offset: 6)).flatMap(FeaturePrints.observation))
        let b = try XCTUnwrap(FeaturePrints.compute(from: scene(hue: 0.9, offset: 0, pattern: true)).flatMap(FeaturePrints.observation))
        let same = FeaturePrints.distance(a1, a2), different = FeaturePrints.distance(a1, b)
        XCTAssertLessThan(same, different, "burst frames are closer than different scenes (\(same) vs \(different))")
    }

    func testGroupingThresholdGapAndBodies() throws {
        let p1 = try XCTUnwrap(FeaturePrints.compute(from: scene(hue: 0.2, offset: 0)).flatMap(FeaturePrints.observation))
        let p2 = try XCTUnwrap(FeaturePrints.compute(from: scene(hue: 0.2, offset: 4)).flatMap(FeaturePrints.observation))
        let q = try XCTUnwrap(FeaturePrints.compute(from: scene(hue: 0.9, offset: 0, pattern: true)).flatMap(FeaturePrints.observation))
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        let inputs: [SimilarityGrouper.Input] = [
            .init(id: "a", captureDate: at(0), groupKey: "x", print: p1),
            .init(id: "b", captureDate: at(15), groupKey: "x", print: p2),        // same scene 15 s later: time stacks miss this
            .init(id: "c", captureDate: at(20), groupKey: "x", print: q),         // different scene
            .init(id: "d", captureDate: at(2000), groupKey: "x", print: q),       // same as c but > maxGap later
            .init(id: "e", captureDate: at(16), groupKey: "y", print: p2),        // other camera body
            .init(id: "f", captureDate: nil, groupKey: "x", print: p1),           // no date → single
        ]
        let prepared = SimilarityGrouper.prepare(inputs)
        let between = FeaturePrints.distance(p1, p2), across = FeaturePrints.distance(p2, q)
        let threshold = (between + across) / 2
        let groups = SimilarityGrouper.groups(prepared, threshold: threshold, maxGap: 600)
        XCTAssertTrue(groups.contains(["a", "b"]), "\(groups)")
        XCTAssertTrue(groups.contains(["c"]) && groups.contains(["d"]), "max gap splits identical scenes far apart: \(groups)")
        XCTAssertTrue(groups.contains(["e"]) && groups.contains(["f"]))
        XCTAssertEqual(groups.flatMap { $0 }.sorted(), ["a", "b", "c", "d", "e", "f"], "every photo exactly once")
        // A tiny threshold splits everything.
        XCTAssertTrue(SimilarityGrouper.groups(prepared, threshold: 0, maxGap: 600).allSatisfy { $0.count == 1 })
    }

    func testFeaturePrintsCachedInIndex() throws {
        let dir = try TestSupport.tempDir()
        let url = TestSupport.makeImage(dir.appendingPathComponent("a.jpg"))
        let f = try XCTUnwrap(FileRef.load(url))
        let index = try IndexStore()
        let data = try XCTUnwrap(FeaturePrints.compute(from: TestSupport.gradient(width: 300, height: 200)))
        index.storeFeaturePrints([(f, data)])
        XCTAssertEqual(index.cachedFeaturePrints(for: [f])[f.path], data)
        var changed = f
        changed.size += 1
        XCTAssertNil(index.cachedFeaturePrints(for: [changed])[f.path])
    }
}
