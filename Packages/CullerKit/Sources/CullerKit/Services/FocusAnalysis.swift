import Foundation
import CoreImage
import Vision
import Accelerate

/// What Vision found in a photo, plus how sharp the subject is. Rects / points are normalized to the image,
/// origin top-left (like `Viewport`).
public struct PhotoAnalysis: Codable, Equatable, Sendable {
    public struct Subject: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case face, animal }
        public var kind: Kind
        public var label: String?
        public var rect: CGRect
        /// Eye centers (faces with landmarks only).
        public var eyes: [CGPoint]
        public var confidence: Float

        /// Where 100% zoom should center: between the eyes, else the upper part of the face / animal (the head).
        public var focusPoint: CGPoint {
            if !eyes.isEmpty {
                return CGPoint(x: eyes.map(\.x).reduce(0, +) / CGFloat(eyes.count), y: eyes.map(\.y).reduce(0, +) / CGFloat(eyes.count))
            }
            return CGPoint(x: rect.midX, y: rect.minY + rect.height * (kind == .face ? 0.4 : 0.3))
        }
    }

    /// Focus measure 0–100 that does not depend on how much detail the scene has: the share of the subject's
    /// gradient energy that a slight blur destroys. Compare it between frames of the same scene (a stack).
    public var sharpness: Double
    /// Raw gradient energy of the subject region (depends on content and framing; tie-breaker only).
    public var energy: Double
    /// Largest first.
    public var subjects: [Subject]

    public init(sharpness: Double, energy: Double, subjects: [Subject]) {
        self.sharpness = sharpness
        self.energy = energy
        self.subjects = subjects
    }
}

public enum FocusAnalyzer {
    static let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false, .name: "PhotoCuller.focus"])

    /// Analyzes a ~1600 px image: faces (with eyes) and animals via Vision, then subject sharpness on the GPU.
    public static func analyze(_ image: CGImage) -> PhotoAnalysis {
        let faces = VNDetectFaceLandmarksRequest()
        let animals = VNRecognizeAnimalsRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([faces, animals])

        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }
        var subjects: [PhotoAnalysis.Subject] = []
        for f in faces.results ?? [] where f.confidence > 0.5 {
            let box = f.boundingBox
            var eyes: [CGPoint] = []
            for region in [f.landmarks?.leftPupil ?? f.landmarks?.leftEye, f.landmarks?.rightPupil ?? f.landmarks?.rightEye].compactMap({ $0 }) {
                let pts = region.normalizedPoints
                guard !pts.isEmpty else { continue }
                let cx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count), cy = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
                // Landmark points are relative to the face box (origin bottom-left).
                eyes.append(CGPoint(x: box.minX + cx * box.width, y: 1 - (box.minY + cy * box.height)))
            }
            subjects.append(.init(kind: .face, label: nil, rect: flip(box), eyes: eyes, confidence: f.confidence))
        }
        for a in animals.results ?? [] where a.confidence > 0.5 {
            subjects.append(.init(kind: .animal, label: a.labels.first?.identifier, rect: flip(a.boundingBox), eyes: [], confidence: a.confidence))
        }
        subjects.sort { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }

        // Sharpness on the main subject (a face counts before a larger animal), else the central 60%.
        let region = (subjects.first { $0.kind == .face } ?? subjects.first).map { expanded($0.rect) }
            ?? CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let ci = CIImage(cgImage: image)
        let e = gradientEnergy(ci, region: region)
        let blurred = gradientEnergy(ci.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.0]).cropped(to: ci.extent), region: region)
        let sharp = e > 0 ? max(0, min(100, (1 - blurred / e) * 100)) : 0
        return PhotoAnalysis(sharpness: sharp, energy: e, subjects: subjects)
    }

    private static func expanded(_ r: CGRect) -> CGRect {
        r.insetBy(dx: -r.width * 0.1, dy: -r.height * 0.1).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Mean squared Sobel gradient of (slightly denoised) luminance inside a normalized top-left region.
    static func gradientEnergy(_ img: CIImage, region: CGRect) -> Double {
        let e = img.extent
        // CI's origin is bottom-left.
        let r = CGRect(x: e.minX + region.minX * e.width, y: e.minY + (1 - region.maxY) * e.height,
                       width: region.width * e.width, height: region.height * e.height)
        let w = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let y = img.applyingFilter("CIColorMatrix", parameters: ["inputRVector": w, "inputGVector": w, "inputBVector": w])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.6]).cropped(to: e)
        let gx = y.applyingFilter("CIConvolution3X3", parameters: ["inputWeights": CIVector(values: [-1, 0, 1, -2, 0, 2, -1, 0, 1], count: 9), "inputBias": 0])
        let gy = y.applyingFilter("CIConvolution3X3", parameters: ["inputWeights": CIVector(values: [-1, -2, -1, 0, 0, 0, 1, 2, 1], count: 9), "inputBias": 0])
        let g2 = gx.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gx])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: gy.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gy])])
        let avg = g2.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
        var px = [Float](repeating: 0, count: 4)
        context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Double(px[0]) * 1000
    }

    /// The sharpest member of each stack (only when it is meaningfully sharper than the runner-up).
    public static func sharpest(in stacks: [[String]], analysis: [String: PhotoAnalysis], margin: Double = 0.5) -> Set<String> {
        var out = Set<String>()
        for members in stacks where members.count > 1 {
            let scored = members.compactMap { id in analysis[id].map { (id, $0.sharpness, $0.energy) } }
            guard scored.count == members.count else { continue }   // wait until the whole stack is analyzed
            let sorted = scored.sorted { ($0.1, $0.2) > ($1.1, $1.2) }
            if sorted[0].1 - sorted[1].1 >= margin { out.insert(sorted[0].0) }
        }
        return out
    }
}

/// Focus-peaking and clipping overlays (spec v2), computed on the CPU (Accelerate + a tight loop, ≈35 ms at
/// 2560 px) in 8-bit sRGB so thresholds mean what they say, returned as transparent RGBA images that are
/// stretched over the photo.
public enum FocusOverlays {
    /// Long edge the overlays are computed at (they are stretched over larger images).
    public static let maxSide = 2560

    private struct Gray { var w: Int; var h: Int; var px: [UInt8] }

    private static func scaledSize(_ img: CGImage) -> (Int, Int) {
        let s = min(1, Double(maxSide) / Double(max(img.width, img.height)))
        return (max(1, Int(Double(img.width) * s)), max(1, Int(Double(img.height) * s)))
    }

    private static func rgba(_ img: CGImage, _ w: Int, _ h: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }

    private static func image(_ buf: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        let data = Data(buf) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Float planes (0…255) of an image drawn at `w`×`h` in sRGB.
    private static func planes(_ img: CGImage, _ w: Int, _ h: Int) -> (r: [Float], g: [Float], b: [Float])? {
        guard var src = rgba(img, w, h) else { return nil }
        let n = w * h
        var r8 = [UInt8](repeating: 0, count: n), g8 = r8, b8 = r8, a8 = r8
        let ok = src.withUnsafeMutableBytes { s in r8.withUnsafeMutableBytes { r in g8.withUnsafeMutableBytes { g in
            b8.withUnsafeMutableBytes { b in a8.withUnsafeMutableBytes { a -> Bool in
                var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                func buf(_ p: UnsafeMutableRawBufferPointer) -> vImage_Buffer {
                    vImage_Buffer(data: p.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                }
                var rb = buf(r), gb = buf(g), bb = buf(b), ab = buf(a)
                // Splits by byte order → planes R, G, B, A.
                return vImageConvert_ARGB8888toPlanar8(&sb, &rb, &gb, &bb, &ab, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            } }
        } } }
        guard ok else { return nil }
        var rf = [Float](repeating: 0, count: n), gf = rf, bf = rf
        vDSP_vfltu8(r8, 1, &rf, 1, vDSP_Length(n))
        vDSP_vfltu8(g8, 1, &gf, 1, vDSP_Length(n))
        vDSP_vfltu8(b8, 1, &bf, 1, vDSP_Length(n))
        return (rf, gf, bf)
    }

    /// Interleaves four float planes (0…255, premultiplied) into an RGBA image.
    private static func compose(_ r: [Float], _ g: [Float], _ b: [Float], _ a: [Float], _ w: Int, _ h: Int) -> CGImage? {
        let n = w * h
        func u8(_ f: [Float]) -> [UInt8] {
            var o = [UInt8](repeating: 0, count: n)
            vDSP_vfixu8(f, 1, &o, 1, vDSP_Length(n))
            return o
        }
        var r8 = u8(r), g8 = u8(g), b8 = u8(b), a8 = u8(a)
        var out = [UInt8](repeating: 0, count: n * 4)
        out.withUnsafeMutableBytes { o in r8.withUnsafeMutableBytes { rp in g8.withUnsafeMutableBytes { gp in
            b8.withUnsafeMutableBytes { bp in a8.withUnsafeMutableBytes { ap in
                func buf(_ p: UnsafeMutableRawBufferPointer) -> vImage_Buffer {
                    vImage_Buffer(data: p.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                }
                var rb = buf(rp), gb = buf(gp), bb = buf(bp), ab = buf(ap)
                var ob = vImage_Buffer(data: o.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                // Interleaves in argument order → bytes R, G, B, A.
                _ = vImageConvert_Planar8toARGB8888(&rb, &gb, &bb, &ab, &ob, vImage_Flags(kvImageNoFlags))
            } }
        } } }
        return image(out, w, h)
    }

    /// 0/1 mask: 1 where `x >= t`.
    private static func atLeast(_ x: [Float], _ t: Float) -> [Float] {
        var t = t, one: Float = 1, zero: Float = 0
        var o = [Float](repeating: 0, count: x.count)
        vDSP_vlim(x, 1, &t, &one, &o, 1, vDSP_Length(x.count))     // +1 / -1
        vDSP_vclip(o, 1, &zero, &one, &o, 1, vDSP_Length(x.count))  // 1 / 0
        return o
    }

    /// Sharp edges (Sobel |gx|+|gy| ≥ 4·`threshold` on lightly denoised sRGB luminance) painted in `color`.
    /// Threshold 30 lights up a sharp subject and leaves out-of-focus background dark on real photos.
    /// Pure Accelerate (vectorized), so it is fast in any build configuration.
    public static func peaking(_ img: CGImage, threshold: UInt8 = 30, color: (UInt8, UInt8, UInt8) = (255, 40, 30)) -> CGImage? {
        let (w, h) = scaledSize(img)
        guard w > 2, h > 2, let p = planes(img, w, h) else { return nil }
        let n = w * h, N = vDSP_Length(n)
        var y = [Float](repeating: 0, count: n)
        vDSP_vsmul(p.r, 1, [0.2126], &y, 1, N)
        vDSP_vsma(p.g, 1, [0.7152], y, 1, &y, 1, N)
        vDSP_vsma(p.b, 1, [0.0722], y, 1, &y, 1, N)
        var soft = [Float](repeating: 0, count: n), gx = soft, gy = soft
        let tent: [Float] = [1, 2, 1, 2, 4, 2, 1, 2, 1].map { $0 / 16 }
        let sx: [Float] = [-1, 0, 1, -2, 0, 2, -1, 0, 1], sy: [Float] = [-1, -2, -1, 0, 0, 0, 1, 2, 1]
        vDSP_imgfir(y, vDSP_Length(h), vDSP_Length(w), tent, &soft, 3, 3)
        vDSP_imgfir(soft, vDSP_Length(h), vDSP_Length(w), sx, &gx, 3, 3)
        vDSP_imgfir(soft, vDSP_Length(h), vDSP_Length(w), sy, &gy, 3, 3)
        vDSP_vabs(gx, 1, &gx, 1, N)
        vDSP_vabs(gy, 1, &gy, 1, N)
        vDSP_vadd(gx, 1, gy, 1, &gx, 1, N)
        let mask = atLeast(gx, Float(threshold) * 4)
        func plane(_ v: UInt8) -> [Float] {
            var o = [Float](repeating: 0, count: n)
            vDSP_vsmul(mask, 1, [Float(v)], &o, 1, N)
            return o
        }
        return compose(plane(color.0), plane(color.1), plane(color.2), plane(255), w, h)
    }

    /// Blown highlights (any channel ≥ `high`) in red, crushed shadows (all channels ≤ `low`) in blue — 8-bit sRGB.
    public static func clipping(_ img: CGImage, high: UInt8 = 250, low: UInt8 = 5) -> CGImage? {
        let (w, h) = scaledSize(img)
        guard let p = planes(img, w, h) else { return nil }
        let n = w * h, N = vDSP_Length(n)
        var m = [Float](repeating: 0, count: n)
        vDSP_vmax(p.r, 1, p.g, 1, &m, 1, N)
        vDSP_vmax(m, 1, p.b, 1, &m, 1, N)
        let hi = atLeast(m, Float(high))
        var lo = atLeast(m, Float(low) + 0.5)          // 1 where above the shadow limit…
        vDSP_vsmsa(lo, 1, [-1], [1], &lo, 1, N)        // …inverted: 1 where crushed
        func plane(_ hv: Float, _ lv: Float) -> [Float] {
            var o = [Float](repeating: 0, count: n)
            vDSP_vsmul(hi, 1, [hv], &o, 1, N)
            vDSP_vsma(lo, 1, [lv], o, 1, &o, 1, N)
            return o
        }
        return compose(plane(255, 40), plane(30, 110), plane(60, 255), plane(255, 255), w, h)
    }

    /// Share of pixels an overlay paints, optionally in a normalized region (top-left origin). For tests / tuning.
    public static func coverage(_ overlay: CGImage, in region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> Double {
        let w = overlay.width, h = overlay.height
        guard let data = overlay.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 0 }
        let bpr = overlay.bytesPerRow
        let x0 = Int(region.minX * Double(w)), x1 = Int(region.maxX * Double(w))
        let y0 = Int(region.minY * Double(h)), y1 = Int(region.maxY * Double(h))
        var n = 0, c = 0
        for y in y0..<max(y0, y1) { for x in x0..<max(x0, x1) { n += 1; if p[y * bpr + x * 4 + 3] > 0 { c += 1 } } }
        return n == 0 ? 0 : Double(c) / Double(n)
    }
}
