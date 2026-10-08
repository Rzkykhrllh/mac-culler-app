import Foundation

/// Snapshot of the EXIF fields the app displays, filters, sorts and stacks on.
public struct ExifInfo: Codable, Equatable, Hashable, Sendable {
    /// Absolute capture instant (DateTimeOriginal + SubSecTimeOriginal, honoring OffsetTimeOriginal).
    public var captureDate: Date?
    /// UTC offset in seconds when OffsetTimeOriginal was present; nil = the camera clock was interpreted in the local time zone.
    public var captureUTCOffset: Int?
    public var make: String?
    public var model: String?
    public var bodySerial: String?
    public var lens: String?
    public var focalLength: Double?
    public var aperture: Double?
    /// Exposure time in seconds.
    public var shutter: Double?
    public var iso: Int?
    public var exposureCompensation: Double?
    public var exposureProgram: Int?
    public var exposureMode: Int?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// EXIF orientation (1…8).
    public var orientation: Int?

    public init() {}

    /// "Canon EOS R5" — make is dropped when the model already starts with it.
    public var cameraName: String? {
        let m = model?.trimmingCharacters(in: .whitespaces)
        let mk = make?.trimmingCharacters(in: .whitespaces)
        switch (mk, m) {
        case let (mk?, m?) where !mk.isEmpty:
            let first = mk.split(separator: " ").first.map(String.init) ?? mk
            return m.lowercased().hasPrefix(first.lowercased()) ? m : "\(mk) \(m)"
        case let (_, m?): return m
        case let (mk?, nil): return mk
        default: return nil
        }
    }

    /// Identity of the camera body used to keep simultaneous bodies apart in burst stacks (spec §4.4).
    public var bodyKey: String {
        if let s = bodySerial?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            return "serial:\(s)"
        }
        return "model:\(make ?? "")|\(model ?? "")"
    }

    /// The capture time zone (falls back to the current zone when the camera wrote no offset).
    public var captureTimeZone: TimeZone {
        captureUTCOffset.flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
    }

    /// Width/height after applying orientation.
    public var orientedSize: (width: Int, height: Int)? {
        guard let w = pixelWidth, let h = pixelHeight else { return nil }
        if let o = orientation, (5...8).contains(o) { return (h, w) }
        return (w, h)
    }
}
