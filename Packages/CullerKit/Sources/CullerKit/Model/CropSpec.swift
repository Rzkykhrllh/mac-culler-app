import Foundation
import CoreGraphics

/// A non-destructive crop. The rectangle is normalized (0…1, origin top-left) in the frame of the photo as
/// displayed (orientation applied). With a straighten `angle` the photo is rotated inside that frame
/// (clockwise for positive degrees) and the rectangle stays axis-aligned; it must lie inside the rotated photo.
public struct CropSpec: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Straighten, degrees, clockwise positive (−45…45).
    public var angle: Double
    /// Aspect preset the crop was made with ("4:5", "1:1", …), nil = free. UI only.
    public var aspect: String?

    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1, angle: Double = 0, aspect: String? = nil) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.angle = angle; self.aspect = aspect
    }

    public static let full = CropSpec()

    /// Rounded to the precision stored in XMP, so the value in memory equals the one read back from the file.
    public var normalized: CropSpec {
        func r(_ v: Double) -> Double { (v * 1_000_000).rounded() / 1_000_000 }
        return CropSpec(x: r(x), y: r(y), width: r(width), height: r(height), angle: r(angle), aspect: aspect)
    }

    /// No visible change (whole photo, not rotated).
    public var isIdentity: Bool {
        abs(angle) < 0.01 && x < 0.0005 && y < 0.0005 && abs(width - 1) < 0.0005 && abs(height - 1) < 0.0005
    }

    // MARK: XMP text form (culler:Crop)

    /// "x y w h angle [aspect]" with fixed precision.
    public var xmpValue: String {
        let nums = [x, y, width, height, angle].map { String(format: "%.6f", $0) }.joined(separator: " ")
        return aspect.map { nums + " " + $0 } ?? nums
    }

    public init?(xmpValue: String) {
        let parts = xmpValue.split(separator: " ").map(String.init)
        guard parts.count >= 5, let x = Double(parts[0]), let y = Double(parts[1]), let w = Double(parts[2]),
              let h = Double(parts[3]), let a = Double(parts[4]), w > 0, h > 0 else { return nil }
        self.init(x: x, y: y, width: w, height: h, angle: a, aspect: parts.count > 5 ? parts[5] : nil)
    }
}

/// Crop math shared by the editor, the loupe overlay and the exporter.
public enum CropGeometry {
    /// Aspect presets offered in the editor (width:height of the result).
    public static let presets: [(id: String, title: String, ratio: Double?)] = [
        ("free", "Free", nil), ("original", "Original", nil), ("4:5", "4:5", 4.0 / 5.0), ("1:1", "1:1", 1),
        ("3:2", "3:2", 3.0 / 2.0), ("2:3", "2:3", 2.0 / 3.0), ("16:9", "16:9", 16.0 / 9.0), ("9:16", "9:16", 9.0 / 16.0),
    ]

    /// Ratio (width / height, in pixels) for a preset id; "original" uses the photo's own ratio.
    public static func ratio(for id: String?, imageSize: CGSize) -> Double? {
        guard let id else { return nil }
        if id == "original" { return Double(imageSize.width / max(1, imageSize.height)) }
        return presets.first { $0.id == id }?.ratio
    }

    /// The four corners of `crop` in source-image pixels (the photo before straightening).
    public static func sourceCorners(of crop: CropSpec, imageSize s: CGSize) -> [CGPoint] {
        let W = Double(s.width), H = Double(s.height)
        let cx = W / 2, cy = H / 2
        let t = -crop.angle * .pi / 180
        let pts = [(crop.x, crop.y), (crop.x + crop.width, crop.y), (crop.x + crop.width, crop.y + crop.height), (crop.x, crop.y + crop.height)]
        return pts.map { px, py in
            let qx = px * W - cx, qy = py * H - cy
            return CGPoint(x: cos(t) * qx - sin(t) * qy + cx, y: sin(t) * qx + cos(t) * qy + cy)
        }
    }

    /// True when the whole crop shows photo (no corner outside the straightened photo).
    public static func fits(_ crop: CropSpec, imageSize s: CGSize, tolerance: Double = 0.5) -> Bool {
        guard crop.width > 0, crop.height > 0 else { return false }
        return sourceCorners(of: crop, imageSize: s).allSatisfy {
            $0.x >= -tolerance && $0.y >= -tolerance && $0.x <= Double(s.width) + tolerance && $0.y <= Double(s.height) + tolerance
        }
    }

    /// Shrinks `crop` around its center (keeping its shape) until it fits.
    public static func shrinkToFit(_ crop: CropSpec, imageSize s: CGSize) -> CropSpec {
        if fits(crop, imageSize: s) { return crop }
        let cx = crop.x + crop.width / 2, cy = crop.y + crop.height / 2
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            var c = crop
            c.width = crop.width * mid; c.height = crop.height * mid
            c.x = cx - c.width / 2; c.y = cy - c.height / 2
            if fits(c, imageSize: s) { lo = mid } else { hi = mid }
        }
        var c = crop
        c.width = crop.width * lo; c.height = crop.height * lo
        c.x = cx - c.width / 2; c.y = cy - c.height / 2
        return c
    }

    /// The largest crop of `ratio` (pixel width / height; nil = whole frame) centered in the photo, straightened by `angle`.
    public static func largest(ratio: Double?, angle: Double, imageSize s: CGSize, aspect: String? = nil) -> CropSpec {
        let W = Double(s.width), H = Double(s.height)
        var w = 1.0, h = 1.0
        if let r = ratio {
            if W / H > r { w = r * H / W } else { h = W / r / H }
        }
        let c = CropSpec(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h, angle: angle, aspect: aspect)
        return shrinkToFit(c, imageSize: s)
    }

    /// Size in pixels of the cropped result.
    public static func outputSize(of crop: CropSpec?, imageSize s: CGSize) -> CGSize {
        guard let crop else { return s }
        return CGSize(width: (crop.width * Double(s.width)).rounded(), height: (crop.height * Double(s.height)).rounded())
    }

    /// Lightroom / Camera Raw crop (crs:CropLeft…Bottom), which is expressed in the file's stored pixel
    /// orientation, not the displayed one. Nil for straightened crops (not mapped).
    public static func cameraRawCrop(_ crop: CropSpec, orientation: Int) -> (left: Double, top: Double, right: Double, bottom: Double)? {
        guard abs(crop.angle) < 0.01 else { return nil }
        let L = crop.x, T = crop.y, R = crop.x + crop.width, B = crop.y + crop.height
        switch orientation {
        case 3: return (1 - R, 1 - B, 1 - L, 1 - T)
        case 6: return (T, 1 - R, B, 1 - L)
        case 8: return (1 - B, L, 1 - T, R)
        default: return (L, T, R, B)
        }
    }
}
