import Foundation
import ImageIO

/// Reads the EXIF snapshot of a file via ImageIO properties (no pixel decode).
public enum ExifReader {
    public static func read(_ url: URL) -> ExifInfo? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any] else { return nil }
        return parse(props)
    }

    public static func parse(_ props: [CFString: Any]) -> ExifInfo {
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        var info = ExifInfo()
        info.make = string(tiff[kCGImagePropertyTIFFMake])
        info.model = string(tiff[kCGImagePropertyTIFFModel])
        info.bodySerial = string(exif[kCGImagePropertyExifBodySerialNumber]) ?? string(aux[kCGImagePropertyExifAuxSerialNumber])
        info.lens = string(exif[kCGImagePropertyExifLensModel]) ?? string(aux[kCGImagePropertyExifAuxLensModel])
        info.focalLength = double(exif[kCGImagePropertyExifFocalLength])
        info.aperture = double(exif[kCGImagePropertyExifFNumber])
        info.shutter = double(exif[kCGImagePropertyExifExposureTime])
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = isos.first {
            info.iso = first.intValue
        } else if let iso = double(exif[kCGImagePropertyExifISOSpeed]) {
            info.iso = Int(iso)
        }
        info.exposureCompensation = double(exif[kCGImagePropertyExifExposureBiasValue])
        info.exposureProgram = (exif[kCGImagePropertyExifExposureProgram] as? NSNumber)?.intValue
        info.exposureMode = (exif[kCGImagePropertyExifExposureMode] as? NSNumber)?.intValue
        info.pixelWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        info.pixelHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        info.orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue

        if let dto = string(exif[kCGImagePropertyExifDateTimeOriginal]) ?? string(exif[kCGImagePropertyExifDateTimeDigitized]) ?? string(tiff[kCGImagePropertyTIFFDateTime]) {
            let subsec = string(exif[kCGImagePropertyExifSubsecTimeOriginal])
            let offset = string(exif[kCGImagePropertyExifOffsetTimeOriginal]) ?? string(exif[kCGImagePropertyExifOffsetTime])
            let parsed = parseCaptureDate(dto, subsec: subsec, offset: offset)
            info.captureDate = parsed?.date
            info.captureUTCOffset = parsed?.offset
        }
        return info
    }

    /// Parses EXIF "yyyy:MM:dd HH:mm:ss" + SubSecTime ("123") + OffsetTime ("+07:00").
    /// Without an offset the wall-clock time is interpreted in the current time zone.
    public static func parseCaptureDate(_ s: String, subsec: String?, offset: String?) -> (date: Date, offset: Int?)? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "-" || $0 == "T" })
        guard parts.count >= 6, let y = Int(parts[0]), let mo = Int(parts[1]), let d = Int(parts[2]),
              let h = Int(parts[3]), let mi = Int(parts[4]), let se = Int(parts[5].prefix(2)), y > 1900 else { return nil }

        let off = offset.flatMap(parseOffset)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = off.flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
        guard let base = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: se)) else { return nil }

        var frac = 0.0
        if let ss = subsec?.trimmingCharacters(in: .whitespaces), !ss.isEmpty, ss.allSatisfy(\.isNumber) {
            frac = Double("0." + ss) ?? 0
        }
        return (base.addingTimeInterval(frac), off)
    }

    static func parseOffset(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 6, let sign = t.first, sign == "+" || sign == "-" else { return nil }
        let comps = t.dropFirst().split(separator: ":")
        guard comps.count == 2, let h = Int(comps[0]), let m = Int(comps[1]) else { return nil }
        return (sign == "-" ? -1 : 1) * (h * 3600 + m * 60)
    }

    private static func string(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return t.isEmpty ? nil : t
    }

    private static func double(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue
    }
}
