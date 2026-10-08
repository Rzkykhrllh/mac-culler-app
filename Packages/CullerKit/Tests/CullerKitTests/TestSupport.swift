import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import XCTest
@testable import CullerKit

enum TestSupport {
    static func tempDir(_ name: String = #function) throws -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("CullerKitTests-\(UUID().uuidString.prefix(6))-\(name.filter { $0.isLetter })", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func gradient(width: Int = 96, height: Int = 64) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            for x in 0..<width {
                ctx.setFillColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height), blue: 0.4, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    /// Writes a small image with EXIF capture time / camera fields.
    @discardableResult
    static func makeImage(_ url: URL, type: UTType = .jpeg, date: String? = "2024:05:01 10:00:00",
                          subsec: String? = nil, model: String = "EOS R5", serial: String? = nil) -> URL {
        var exif: [CFString: Any] = [kCGImagePropertyExifLensModel: "RF24-70mm", kCGImagePropertyExifFNumber: 2.8,
                                     kCGImagePropertyExifExposureTime: 0.004, kCGImagePropertyExifISOSpeedRatings: [400],
                                     kCGImagePropertyExifFocalLength: 50.0]
        if let date { exif[kCGImagePropertyExifDateTimeOriginal] = date }
        if let subsec { exif[kCGImagePropertyExifSubsecTimeOriginal] = subsec }
        if let serial { exif[kCGImagePropertyExifBodySerialNumber] = serial }
        let props: [CFString: Any] = [kCGImagePropertyExifDictionary: exif,
                                      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: model]]
        let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, gradient(), props as CFDictionary)
        precondition(CGImageDestinationFinalize(d))
        return url
    }

    /// A stand-in proprietary RAW (only its name/extension matters for most tests).
    @discardableResult
    static func makeFakeRaw(_ url: URL, bytes: Int = 4096) -> URL {
        var d = Data(count: bytes)
        for i in 0..<bytes { d[i] = UInt8(truncatingIfNeeded: i &* 31) }
        try! d.write(to: url)
        return url
    }

    static func decodedPixels(_ url: URL) -> Data {
        let s = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let img = CGImageSourceCreateImageAtIndex(s, 0, nil)!
        return img.dataProvider!.data! as Data
    }

    static func items(_ folder: URL, pair: Bool = true) throws -> [ItemFiles] {
        try FolderScanner.scan(folder: folder, options: ScanOptions(includeSubfolders: false, pairRawWithRaster: pair))
    }

    static func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
    }

    /// Flattens an XMP tree into "path = value" pairs (recursively, including arrays and structs).
    static func flatten(_ meta: CGImageMetadata) -> [String: String] {
        var out: [String: String] = [:]
        func walk(_ tag: CGImageMetadataTag, path: String) {
            let value = CGImageMetadataTagCopyValue(tag)
            switch CGImageMetadataTagGetType(tag) {
            case .arrayUnordered, .arrayOrdered, .alternateArray, .alternateText:
                let arr = (value as? [CGImageMetadataTag]) ?? []
                for (i, t) in arr.enumerated() { walk(t, path: "\(path)[\(i)]") }
                if arr.isEmpty { out[path] = "[]" }
            case .structure:
                let dict = (value as? [String: CGImageMetadataTag]) ?? [:]
                for (k, t) in dict { walk(t, path: "\(path)/\(k)") }
            default:
                out[path] = "\(value ?? "nil" as CFString)"
            }
            if let q = CGImageMetadataTagCopyQualifiers(tag) as? [CGImageMetadataTag] {
                for t in q { walk(t, path: "\(path)?\(CGImageMetadataTagCopyName(t) as String? ?? "")") }
            }
        }
        for tag in (CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag]) ?? [] {
            let ns = CGImageMetadataTagCopyNamespace(tag) as String? ?? ""
            let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
            walk(tag, path: "\(ns)\(name)")
        }
        return out
    }

    static let ownedPaths: Set<String> = [
        "http://ns.adobe.com/xap/1.0/Rating", "http://ns.adobe.com/xap/1.0/Label",
        AppConstants.xmpNamespaceURI + "Flag", AppConstants.xmpNamespaceURI + "Note",
    ]
}
