import Foundation
import CullerKit

enum ExifFormat {
    static func shutter(_ s: Double?) -> String? {
        guard let s, s > 0 else { return nil }
        if s >= 1 { return s.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(s))s" : String(format: "%.1fs", s) }
        return "1/\(Int((1 / s).rounded()))"
    }

    static func aperture(_ a: Double?) -> String? {
        guard let a, a > 0 else { return nil }
        return a.truncatingRemainder(dividingBy: 1) == 0 ? "f/\(Int(a))" : String(format: "f/%.1f", a)
    }

    static func iso(_ i: Int?) -> String? { i.map { "ISO \($0)" } }

    static func focal(_ f: Double?) -> String? {
        guard let f, f > 0 else { return nil }
        return "\(Int(f.rounded()))mm"
    }

    static func exposureComp(_ v: Double?) -> String? {
        guard let v else { return nil }
        if abs(v) < 0.01 { return "0 EV" }
        return String(format: "%+.1f EV", v)
    }

    /// Shutter · aperture · ISO · focal length · lens.
    static func summary(_ e: ExifInfo) -> String {
        [shutter(e.shutter), aperture(e.aperture), iso(e.iso), focal(e.focalLength), e.lens].compactMap { $0 }.joined(separator: "   ")
    }

    static func exposureProgram(_ p: Int?) -> String? {
        guard let p else { return nil }
        return ["Not defined", "Manual", "Program", "Aperture priority", "Shutter priority", "Creative",
                "Action", "Portrait", "Landscape"][safe: p]
    }

    static func exposureMode(_ m: Int?) -> String? {
        guard let m else { return nil }
        return ["Auto exposure", "Manual exposure", "Auto bracket"][safe: m]
    }

    static let captureFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    static func captureDate(_ e: ExifInfo) -> String? {
        guard let d = e.captureDate else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = e.captureTimeZone
        return f.string(from: d)
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
