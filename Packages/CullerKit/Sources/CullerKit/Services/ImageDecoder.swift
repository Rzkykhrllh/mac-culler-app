import Foundation
import ImageIO
import CoreImage

/// How RAW files are shown.
public enum RawRendering: String, Sendable, CaseIterable {
    /// The JPEG preview embedded by the camera: fastest, but already has the camera's look (e.g. film simulation).
    case embedded
    /// Demosaiced from the sensor data with Core Image: the neutral, "real" RAW.
    case rendered
}

/// Stateless decode routines for the three representations of an item (spec §3 pipeline).
public enum ImageDecoder {
    static let ciContext = CIContext(options: [.cacheIntermediates: false, .name: "PhotoCuller.raw"])

    private static func source(_ url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    private static func thumbnail(_ src: CGImageSource, maxPixel: Int, always: Bool, extra: [CFString: Any] = [:]) -> CGImage? {
        var opts: [CFString: Any] = [
            always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        extra.forEach { opts[$0.key] = $0.value }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// ~400 px thumbnail. RAW: prefer the embedded preview (no full decode). Raster: downsampled decode
    /// (the EXIF thumbnail of a JPEG is usually too small to use).
    public static func thumbnail(for file: FileRef, maxPixel: Int = 400, raw: RawRendering = .embedded) -> CGImage? {
        guard let src = source(file.url) else { return nil }
        if file.kind.isRaw, raw == .rendered, let r = rawPreviewViaCoreImage(file.url, maxPixel: maxPixel, draft: true) {
            return r
        }
        if file.kind.isRaw {
            if let t = thumbnail(src, maxPixel: maxPixel, always: false), max(t.width, t.height) >= maxPixel * 6 / 10 {
                return t
            }
            if let p = rawPreviewViaCoreImage(file.url, maxPixel: maxPixel, draft: true) { return p }
            return thumbnail(src, maxPixel: maxPixel, always: true)
        }
        return thumbnail(src, maxPixel: maxPixel, always: true, extra: subsampleOptions(src, file: file, maxPixel: maxPixel))
    }

    /// The small thumbnail embedded in the file (no decode of the main image; ≈1 ms). nil if absent.
    public static func embeddedThumbnail(for file: FileRef) -> CGImage? {
        guard let src = source(file.url) else { return nil }
        return thumbnail(src, maxPixel: 400, always: false)
    }

    /// JPEG / HEIC can decode directly at 1/2, 1/4 or 1/8 size; pick the largest factor that keeps ≥ maxPixel.
    private static func subsampleOptions(_ src: CGImageSource, file: FileRef, maxPixel: Int) -> [CFString: Any] {
        guard file.kind == .jpeg || file.kind == .heic,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return [:] }
        let long = max(w, h)
        for f in [8, 4, 2] where long / f >= maxPixel { return [kCGImageSourceSubsampleFactor: f] }
        return [:]
    }

    /// Screen-sized preview. RAW: the embedded full-size JPEG preview; raster: downsampled decode.
    public static func preview(for file: FileRef, maxPixel: Int, raw: RawRendering = .embedded) -> CGImage? {
        guard let src = source(file.url) else { return nil }
        if file.kind.isRaw, raw == .rendered, let r = rawPreviewViaCoreImage(file.url, maxPixel: maxPixel, draft: false) {
            return r
        }
        if file.kind.isRaw {
            if let t = thumbnail(src, maxPixel: maxPixel, always: false),
               max(t.width, t.height) >= min(maxPixel, 1600) {
                return t
            }
            // Embedded preview missing or tiny: draft-mode RAW decode at reduced scale.
            return rawPreviewViaCoreImage(file.url, maxPixel: maxPixel, draft: true) ?? thumbnail(src, maxPixel: maxPixel, always: false)
        }
        return thumbnail(src, maxPixel: maxPixel, always: true, extra: subsampleOptions(src, file: file, maxPixel: maxPixel))
    }

    /// Native-resolution image for 100% zoom. RAW via `CIRAWFilter`; raster decoded at native size with orientation.
    public static func fullResolution(for file: FileRef) -> CGImage? {
        if file.kind.isRaw {
            guard let filter = CIRAWFilter(imageURL: file.url), let out = filter.outputImage else { return nil }
            return ciContext.createCGImage(out, from: out.extent, format: .RGBA8,
                                           colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
        }
        guard let src = source(file.url),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return thumbnail(src, maxPixel: max(w, h), always: true)
    }

    /// RAW decoded from sensor data at reduced scale (orientation applied). Draft mode = faster, lower quality demosaic.
    static func rawPreviewViaCoreImage(_ url: URL, maxPixel: Int, draft: Bool) -> CGImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let native = filter.nativeSize
        let longEdge = max(native.width, native.height)
        if longEdge > 0 { filter.scaleFactor = Float(min(1, CGFloat(maxPixel) / longEdge)) }
        filter.isDraftModeEnabled = draft
        guard let out = filter.outputImage else { return nil }
        return ciContext.createCGImage(out, from: out.extent, format: .RGBA8,
                                       colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
    }

    /// Pixel size after orientation, read from properties only.
    public static func orientedPixelSize(of url: URL) -> CGSize? {
        guard let src = source(url),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(o) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
}

/// RGB + luminance histogram (256 bins), computed from a small downsample of the preview (spec §6.4).
public struct Histogram: Sendable, Equatable {
    public var red: [UInt32]
    public var green: [UInt32]
    public var blue: [UInt32]
    public var luma: [UInt32]

    public static func compute(_ image: CGImage, sampleWidth: Int = 256) -> Histogram? {
        let w = min(sampleWidth, image.width)
        let h = max(1, Int(Double(image.height) * Double(w) / Double(max(1, image.width))))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var r = [UInt32](repeating: 0, count: 256), g = r, b = r, l = r
        for i in 0..<(w * h) {
            let R = Int(px[i * 4]), G = Int(px[i * 4 + 1]), B = Int(px[i * 4 + 2])
            r[R] += 1; g[G] += 1; b[B] += 1
            l[(R * 2126 + G * 7152 + B * 722) / 10000] += 1
        }
        return Histogram(red: r, green: g, blue: b, luma: l)
    }
}
