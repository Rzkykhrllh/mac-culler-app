import Foundation

/// Token-based file name template, e.g. `{date:yyyyMMdd}_{seq:4}_{original}` (spec §8.1).
public struct RenameTemplate: Equatable, Sendable {
    public enum Token: Equatable, Sendable {
        case literal(String)
        case original
        case date(String)
        case time(String)
        case seq(Int)
        case camera
        case lens
        case rating
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case unknownToken(String)
        case unclosedBrace
        case invalidSequenceDigits(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .unknownToken(let t): return "Unknown token {\(t)}"
            case .unclosedBrace: return "Missing closing }"
            case .invalidSequenceDigits(let s): return "Invalid sequence digits “\(s)” (use 1–9)"
            case .empty: return "Template is empty"
            }
        }
    }

    public struct Context: Sendable {
        public var originalBaseName: String
        public var captureDate: Date?
        public var timeZone: TimeZone
        public var camera: String?
        public var lens: String?
        public var rating: Int

        public init(originalBaseName: String, captureDate: Date?, timeZone: TimeZone = .current,
                    camera: String? = nil, lens: String? = nil, rating: Int = 0) {
            self.originalBaseName = originalBaseName
            self.captureDate = captureDate
            self.timeZone = timeZone
            self.camera = camera
            self.lens = lens
            self.rating = rating
        }
    }

    public let source: String
    public let tokens: [Token]

    public static let availableTokens = ["{original}", "{date:yyyyMMdd}", "{time:HHmmss}", "{seq:4}", "{camera}", "{lens}", "{rating}"]

    public init(_ source: String) throws {
        self.source = source
        var tokens: [Token] = []
        var literal = ""
        var i = source.startIndex
        while i < source.endIndex {
            let c = source[i]
            if c == "{" {
                guard let close = source[i...].firstIndex(of: "}") else { throw ParseError.unclosedBrace }
                if !literal.isEmpty { tokens.append(.literal(literal)); literal = "" }
                let body = String(source[source.index(after: i)..<close])
                tokens.append(try Self.parseToken(body))
                i = source.index(after: close)
            } else {
                literal.append(c)
                i = source.index(after: i)
            }
        }
        if !literal.isEmpty { tokens.append(.literal(literal)) }
        guard !tokens.isEmpty else { throw ParseError.empty }
        self.tokens = tokens
    }

    private static func parseToken(_ body: String) throws -> Token {
        let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let arg = parts.count > 1 ? parts[1] : nil
        switch name {
        case "original": return .original
        case "date": return .date(arg ?? "yyyyMMdd")
        case "time": return .time(arg ?? "HHmmss")
        case "seq":
            guard let a = arg else { return .seq(4) }
            guard let n = Int(a), (1...9).contains(n) else { throw ParseError.invalidSequenceDigits(a) }
            return .seq(n)
        case "camera": return .camera
        case "lens": return .lens
        case "rating": return .rating
        default: throw ParseError.unknownToken(body)
        }
    }

    public var usesSequence: Bool { tokens.contains { if case .seq = $0 { return true } else { return false } } }

    /// Renders the base name (without extension) for one item. `sequence` is the absolute sequence number.
    public func render(_ ctx: Context, sequence: Int) -> String {
        var out = ""
        for t in tokens {
            switch t {
            case .literal(let s): out += s
            case .original: out += ctx.originalBaseName
            case .date(let f), .time(let f):
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = ctx.timeZone
                df.dateFormat = f
                out += Self.sanitize(df.string(from: ctx.captureDate ?? Date(timeIntervalSince1970: 0)))
            case .seq(let digits):
                let s = String(sequence)
                out += String(repeating: "0", count: max(0, digits - s.count)) + s
            case .camera: out += Self.sanitize(ctx.camera ?? "Unknown")
            case .lens: out += Self.sanitize(ctx.lens ?? "Unknown")
            case .rating: out += String(ctx.rating)
            }
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? ctx.originalBaseName : trimmed
    }

    /// Removes characters that are invalid or awkward in file names.
    static func sanitize(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        r = r.replacingOccurrences(of: "\0", with: "")
        while r.hasPrefix(".") { r.removeFirst() }
        return r
    }
}

/// A named, saved template.
public struct RenamePreset: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var template: String
    public var sequenceStart: Int

    public init(id: UUID = UUID(), name: String, template: String, sequenceStart: Int = 1) {
        self.id = id
        self.name = name
        self.template = template
        self.sequenceStart = sequenceStart
    }

    public static let defaults: [RenamePreset] = [
        RenamePreset(name: "Date + sequence + original", template: "{date:yyyyMMdd}_{seq:4}_{original}"),
        RenamePreset(name: "Date-time", template: "{date:yyyyMMdd}-{time:HHmmss}"),
        RenamePreset(name: "Camera + sequence", template: "{camera}_{seq:4}"),
    ]
}
