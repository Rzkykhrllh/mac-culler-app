import Foundation

/// A completed file operation as recorded in the persistent log (spec §8.4).
public struct OperationRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case rename, move, copy

        public var title: String {
            switch self {
            case .rename: return "Rename"
            case .move: return "Move"
            case .copy: return "Copy"
            }
        }
    }

    /// One file of the operation, with the attributes it had right after the operation.
    public struct Entry: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
        public var size: Int64
        public var mtime: Double
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var itemCount: Int
    public var entries: [Entry]
    /// Security-scoped bookmarks of the folders involved, so undo works after a relaunch in the sandbox.
    public var folderBookmarks: [Data]
    public var undone: Bool

    public var summary: String {
        let noun = itemCount == 1 ? "item" : "items"
        switch kind {
        case .rename: return "Renamed \(itemCount) \(noun)"
        case .move: return "Moved \(itemCount) \(noun) to \(destinationName)"
        case .copy: return "Copied \(itemCount) \(noun) to \(destinationName)"
        }
    }

    var destinationName: String {
        entries.first.map { URL(fileURLWithPath: $0.to).deletingLastPathComponent().lastPathComponent } ?? "?"
    }

    public static func make(kind: OperationRecord.Kind, plans: [ItemPlan], folderBookmarks: [Data] = []) -> OperationRecord {
        var entries: [Entry] = []
        for p in plans {
            for m in p.moves where m.from.standardizedFileURL != m.to.standardizedFileURL || kind == .copy {
                let v = try? m.to.freshResourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                entries.append(Entry(from: m.from.path, to: m.to.path, size: Int64(v?.fileSize ?? -1),
                                     mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        return OperationRecord(id: UUID(), date: Date(), kind: kind, itemCount: plans.count,
                               entries: entries, folderBookmarks: folderBookmarks, undone: false)
    }
}

public enum UndoError: Error, LocalizedError, Equatable {
    case fileMissing(String)
    case fileChanged(String)
    case locationOccupied(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .fileMissing(let p): return "“\((p as NSString).lastPathComponent)” is no longer at \((p as NSString).deletingLastPathComponent). It may have been moved or deleted outside \(AppConstants.appName)."
        case .fileChanged(let p): return "“\((p as NSString).lastPathComponent)” was modified after the operation (size or date differ), so it is not safe to undo."
        case .locationOccupied(let p): return "Another file now exists at \(p)."
        case .failed(let s): return s
        }
    }
}

/// Persistent JSON-lines log of file operations in Application Support. Undo/redo state changes are appended
/// as separate lines, so the file is append-only.
public final class OperationLog: @unchecked Sendable {
    private enum Line: Codable {
        case operation(OperationRecord)
        case state(id: UUID, undone: Bool)
    }

    public let url: URL
    private let lock = NSLock()
    private var records: [OperationRecord] = []

    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(AppConstants.supportDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(AppConstants.operationLogFileName)
    }

    public init(url: URL) {
        self.url = url
        load()
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func load() {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return }
        var byID: [UUID: Int] = [:]
        var out: [OperationRecord] = []
        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let l = try? Self.decoder.decode(Line.self, from: Data(line.utf8)) else { continue }
            switch l {
            case .operation(let r):
                byID[r.id] = out.count
                out.append(r)
            case .state(let id, let undone):
                if let i = byID[id] { out[i].undone = undone }
            }
        }
        records = out
    }

    private func append(_ line: Line) {
        guard var data = try? Self.encoder.encode(line) else { return }
        data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    public var all: [OperationRecord] { lock.withLock { records } }

    public func record(_ r: OperationRecord) {
        lock.withLock {
            records.append(r)
            append(.operation(r))
        }
    }

    private func setUndone(_ id: UUID, _ undone: Bool) {
        lock.withLock {
            if let i = records.firstIndex(where: { $0.id == id }) { records[i].undone = undone }
            append(.state(id: id, undone: undone))
        }
    }

    // MARK: Verification

    static func check(path: String, size: Int64, mtime: Double) -> UndoError? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return .fileMissing(path) }
        let v = try? url.freshResourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let s = Int64(v?.fileSize ?? -1)
        let m = v?.contentModificationDate?.timeIntervalSince1970 ?? 0
        if s != size || abs(m - mtime) > 0.001 { return .fileChanged(path) }
        return nil
    }

    /// Returns the reason undo is refused, or nil when every file is exactly where/what the log expects.
    public func verifyUndo(_ r: OperationRecord) -> UndoError? {
        for e in r.entries {
            if let err = Self.check(path: e.to, size: e.size, mtime: e.mtime) { return err }
            if r.kind != .copy, e.from != e.to, FileManager.default.fileExists(atPath: e.from),
               !r.entries.contains(where: { $0.to == e.from }) {
                return .locationOccupied(e.from)
            }
        }
        return nil
    }

    public func verifyRedo(_ r: OperationRecord) -> UndoError? {
        for e in r.entries {
            if let err = Self.check(path: e.from, size: e.size, mtime: e.mtime) { return err }
            if FileManager.default.fileExists(atPath: e.to), !r.entries.contains(where: { $0.from == e.to }) {
                return .locationOccupied(e.to)
            }
        }
        return nil
    }

    // MARK: Undo / redo

    /// Reverts an operation after verifying it. Undoing a copy moves the copies to the Trash.
    public func undo(_ r: OperationRecord) throws {
        if let err = verifyUndo(r) { throw err }
        let fm = FileManager.default
        switch r.kind {
        case .rename, .move:
            let moves = r.entries.map { FileMove(from: URL(fileURLWithPath: $0.to), to: URL(fileURLWithPath: $0.from)) }
            do { try FileOperations.executeTwoPhase(moves) } catch { throw UndoError.failed(error.localizedDescription) }
        case .copy:
            for e in r.entries {
                do { try fm.trashItem(at: URL(fileURLWithPath: e.to), resultingItemURL: nil) } catch {
                    throw UndoError.failed(error.localizedDescription)
                }
            }
        }
        setUndone(r.id, true)
    }

    public func redo(_ r: OperationRecord) throws {
        if let err = verifyRedo(r) { throw err }
        let fm = FileManager.default
        switch r.kind {
        case .rename, .move:
            let moves = r.entries.map { FileMove(from: URL(fileURLWithPath: $0.from), to: URL(fileURLWithPath: $0.to)) }
            do { try FileOperations.executeTwoPhase(moves) } catch { throw UndoError.failed(error.localizedDescription) }
        case .copy:
            var made: [URL] = []
            do {
                for e in r.entries {
                    try fm.copyItem(at: URL(fileURLWithPath: e.from), to: URL(fileURLWithPath: e.to))
                    made.append(URL(fileURLWithPath: e.to))
                }
            } catch {
                for u in made { try? fm.removeItem(at: u) }
                throw UndoError.failed(error.localizedDescription)
            }
        }
        setUndone(r.id, false)
    }
}
