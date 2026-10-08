import Foundation
import ImageIO
import CoreImage

/// Stateless decode routines for the three representations of an item (spec §3 pipeline).
public enum ImageDecoder {
    static let ciContext = CIContext(options: [.cacheIntermediates: false, .name: "PhotoCuller.raw"])

    private static func source(_ url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    private static func thumbnail(_ src: CGImageSource, maxPixel: Int, always: Bool) -> CGImage? {
        let opts: [CFString: Any] = [
            always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// ~400 px thumbnail. RAW: prefer the embedded preview (no full decode). Raster: downsampled decode
    /// (the EXIF thumbnail of a JPEG is usually too small to use).
    public static func thumbnail(for file: FileRef, maxPixel: Int = 400) -> CGImage? {
        guard let src = source(file.url) else { return nil }
        if file.kind.isRaw {
            if let t = thumbnail(src, maxPixel: maxPixel, always: false), max(t.width, t.height) >= maxPixel * 6 / 10 {
                return t
            }
            if let p = rawPreviewViaCoreImage(file.url, maxPixel: maxPixel) { return p }
            return thumbnail(src, maxPixel: maxPixel, always: true)
        }
        return thumbnail(src, maxPixel: maxPixel, always: true)
    }

    /// Screen-sized preview. RAW: the embedded full-size JPEG preview; raster: downsampled decode.
    public static func preview(for file: FileRef, maxPixel: Int) -> CGImage? {
        guard let src = source(file.url) else { return nil }
        if file.kind.isRaw {
            if let t = thumbnail(src, maxPixel: maxPixel, always: false),
               max(t.width, t.height) >= min(maxPixel, 1600) {
                return t
            }
            // Embedded preview missing or tiny: draft-mode RAW decode at reduced scale.
            return rawPreviewViaCoreImage(file.url, maxPixel: maxPixel) ?? thumbnail(src, maxPixel: maxPixel, always: false)
        }
        return thumbnail(src, maxPixel: maxPixel, always: true)
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

    static func rawPreviewViaCoreImage(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let native = filter.nativeSize
        let longEdge = max(native.width, native.height)
        if longEdge > 0 { filter.scaleFactor = Float(min(1, CGFloat(maxPixel) / longEdge)) }
        filter.isDraftModeEnabled = true
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
