import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// What an export does to each photo: frame (border / canvas), size, encoding.
public struct ExportOptions: Codable, Equatable, Sendable {
    public enum Frame: Codable, Equatable, Sendable {
        case none
        /// The same white (or `color`) margin on every side, as a percentage of the photo's shorter side.
        case border(percent: Double)
        /// The photo centered on a canvas of a fixed ratio (e.g. 4:5), at least `marginPercent`
        /// of the photo's size around it.
        case canvas(width: Double, height: Double, marginPercent: Double)
    }

    public enum Size: Codable, Equatable, Sendable {
        case original
        case longEdge(Int)
        /// Exact width; the height follows the canvas.
        case width(Int)
        case exact(width: Int, height: Int)
    }

    public var frame: Frame
    public var size: Size
    /// sRGB, 0…1.
    public var red = 1.0, green = 1.0, blue = 1.0
    public var quality = 0.92
    public var stripLocation = true
    /// RAW+JPG pairs: render the RAW (True RAW) instead of using the camera JPEG.
    public var useRaw = false
    public var suffix: String

    public init(frame: Frame, size: Size, suffix: String) {
        self.frame = frame
        self.size = size
        self.suffix = suffix
    }

    /// 4:5 portrait canvas, 1080 px wide (1080 × 1350): a photo cropped to 4:5 fills it, others get white bars.
    public static let fourFiveCanvas = ExportOptions(frame: .canvas(width: 4, height: 5, marginPercent: 0), size: .width(1080), suffix: "-4x5")
    /// The whole photo with a 10% white border, long edge 4096.
    public static let whiteBorder = ExportOptions(frame: .border(percent: 10), size: .longEdge(4096), suffix: "-border")
}

public enum ExportError: Error, LocalizedError {
    case cannotDecode(URL)
    case cannotRender
    case cannotWrite(URL)

    public var errorDescription: String? {
        switch self {
        case .cannotDecode(let u): return "Cannot read \(u.lastPathComponent)"
        case .cannotRender: return "Rendering failed"
        case .cannotWrite(let u): return "Cannot write \(u.lastPathComponent)"
        }
    }
}

public enum PhotoExporter {
    private static let ci = CIContext(options: [.cacheIntermediates: false])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: Geometry

    /// Canvas size and where the (cropped) photo goes, before final scaling.
    public static func layout(content: CGSize, frame: ExportOptions.Frame) -> (canvas: CGSize, photo: CGRect) {
        let cw = content.width, ch = content.height
        switch frame {
        case .none:
            return (content, CGRect(origin: .zero, size: content))
        case .border(let p):
            let b = (max(0, p) / 100 * Double(min(cw, ch))).rounded()
            return (CGSize(width: cw + 2 * b, height: ch + 2 * b), CGRect(x: b, y: b, width: cw, height: ch))
        case .canvas(let rw, let rh, let m):
            let ratio = rw / rh
            let margin = max(0, m) / 100
            // Already (almost) that ratio, e.g. cropped to 4:5: the photo is the canvas — no hairline bars from rounding.
            if margin == 0, abs(Double(cw / ch) - ratio) / ratio < 0.01 {
                return (content, CGRect(origin: .zero, size: content))
            }
            var W: Double, H: Double
            if Double(cw / ch) > ratio {
                W = Double(cw) * (1 + 2 * margin); H = W / ratio
            } else {
                H = Double(ch) * (1 + 2 * margin); W = H * ratio
            }
            W = W.rounded(); H = H.rounded()
            return (CGSize(width: W, height: H),
                    CGRect(x: ((W - Double(cw)) / 2).rounded(), y: ((H - Double(ch)) / 2).rounded(), width: cw, height: ch))
        }
    }

    /// Final pixel size for a canvas.
    public static func finalSize(canvas: CGSize, size: ExportOptions.Size) -> CGSize {
        switch size {
        case .original: return canvas
        case .exact(let w, let h): return CGSize(width: w, height: h)
        case .width(let w):
            return CGSize(width: CGFloat(w), height: (canvas.height * CGFloat(w) / max(1, canvas.width)).rounded())
        case .longEdge(let l):
            let long = max(canvas.width, canvas.height)
            guard long > CGFloat(l) else { return canvas }   // never upscale
            let s = CGFloat(l) / long
            return CGSize(width: (canvas.width * s).rounded(), height: (canvas.height * s).rounded())
        }
    }

    // MARK: Rendering

    /// Applies crop / straighten (in the displayed orientation of `image`).
    public static func cropped(_ image: CGImage, crop: CropSpec?) -> CGImage? {
        guard let crop, !crop.isIdentity else { return image }
        let W = CGFloat(image.width), H = CGFloat(image.height)
        var img = CIImage(cgImage: image)
        if abs(crop.angle) > 0.001 {
            // Clockwise on screen = negative angle in Core Image's y-up space, around the photo's center.
            let t = CGAffineTransform(translationX: -W / 2, y: -H / 2)
                .concatenating(CGAffineTransform(rotationAngle: -crop.angle * .pi / 180))
                .concatenating(CGAffineTransform(translationX: W / 2, y: H / 2))
            img = img.transformed(by: t)
        }
        let r = CGRect(x: crop.x * W, y: (1 - crop.y - crop.height) * H, width: crop.width * W, height: crop.height * H).integral
        let out = img.cropped(to: r)
        return ci.createCGImage(out, from: r, format: .RGBA8, colorSpace: image.colorSpace ?? sRGB)
    }

    /// The whole export render: crop, frame, scale. Returns an sRGB image.
    public static func render(_ source: CGImage, crop: CropSpec?, options o: ExportOptions) -> CGImage? {
        guard let photo = cropped(source, crop: crop) else { return nil }
        let (canvas, rect) = layout(content: CGSize(width: photo.width, height: photo.height), frame: o.frame)
        var out = finalSize(canvas: canvas, size: o.size)
        // A ratio canvas at a given width is exactly that ratio (e.g. 1080 × 1350 for 4:5).
        if case .canvas(let rw, let rh, _) = o.frame, case .width(let w) = o.size {
            out = CGSize(width: CGFloat(w), height: (CGFloat(w) * rh / rw).rounded())
        }
        // .exact keeps the canvas shape: scale to fit and center (bars of the frame color if the ratio differs).
        var s = min(out.width / canvas.width, out.height / canvas.height)
        // Within 1% of the output's shape: fill it (trims a pixel or two) instead of leaving a hairline bar.
        let shapeDiff = abs((canvas.width / canvas.height) / (out.width / out.height) - 1)
        if shapeDiff > 0, shapeDiff < 0.01 { s = max(out.width / canvas.width, out.height / canvas.height) }
        let ox = (out.width - canvas.width * s) / 2, oy = (out.height - canvas.height * s) / 2
        guard let ctx = CGContext(data: nil, width: Int(out.width), height: Int(out.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [o.red, o.green, o.blue, 1])!)
        ctx.fill(CGRect(origin: .zero, size: out))
        ctx.interpolationQuality = .high
        // CGContext is y-up: rect.y counts from the top of the canvas.
        let dst = CGRect(x: ox + rect.minX * s, y: oy + (canvas.height - rect.maxY) * s, width: rect.width * s, height: rect.height * s)
        ctx.draw(photo, in: dst)
        return ctx.makeImage()
    }

    // MARK: Files

    /// Renders one photo and writes `<name><suffix>.jpg` into `folder` (never overwriting). Returns the new file.
    public static func export(_ item: ItemFiles, crop: CropSpec?, options o: ExportOptions, to folder: URL) throws -> URL {
        let source: FileRef = o.useRaw ? (item.raw ?? item.primary) : (item.files.first { $0.kind.isRaster } ?? item.primary)
        guard let full = ImageDecoder.fullResolution(for: source) else { throw ExportError.cannotDecode(source.url) }
        guard let image = render(full, crop: crop, options: o) else { throw ExportError.cannotRender }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, base: item.baseName + o.suffix, ext: "jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ExportError.cannotWrite(url)
        }
        CGImageDestinationAddImage(dest, image, properties(from: source.url, options: o) as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.cannotWrite(url) }
        return url
    }

    /// The source's EXIF / TIFF / IPTC, upright (the pixels are already rotated), optionally without GPS.
    static func properties(from url: URL, options o: ExportOptions) -> [CFString: Any] {
        var p: [CFString: Any] = [:]
        if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary,
                        kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary] {
                if let v = props[key] { p[key] = v }
            }
        }
        if o.stripLocation { p[kCGImagePropertyGPSDictionary] = nil }
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            p[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            p[kCGImagePropertyExifDictionary] = exif
        }
        p[kCGImagePropertyOrientation] = 1
        p[kCGImageDestinationLossyCompressionQuality] = o.quality
        return p
    }

    static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}
