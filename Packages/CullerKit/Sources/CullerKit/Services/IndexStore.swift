import Foundation
import GRDB

/// SQLite cache of per-file EXIF and per-item metadata (spec §5.6). Never the source of truth:
/// rows are keyed by file attributes and simply ignored when they no longer match. Safe to delete at any time.
/// It additionally keeps metadata writes that have not reached disk yet, so a failed write is not lost.
public final class IndexStore: Sendable {
    private let db: DatabaseQueue

    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(AppConstants.supportDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(AppConstants.indexFileName)
    }

    public init(url: URL) throws {
        func open() throws -> DatabaseQueue {
            var config = Configuration()
            config.label = "index"
            let q = try DatabaseQueue(path: url.path, configuration: config)
            try Self.migrator.migrate(q)
            return q
        }
        do {
            db = try open()
        } catch {
            // A corrupt cache is discarded and rebuilt.
            try? FileManager.default.removeItem(at: url)
            db = try open()
        }
    }

    /// In-memory index (tests, or fallback when the on-disk index cannot be opened).
    public init() throws {
        db = try DatabaseQueue()
        try Self.migrator.migrate(db)
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "exif") { t in
                t.primaryKey("path", .text)
                t.column("size", .integer).notNull()
                t.column("mtime", .double).notNull()
                t.column("json", .blob).notNull()
            }
            try db.create(table: "itemMeta") { t in
                t.primaryKey("itemID", .text)
                t.column("signature", .text).notNull()
                t.column("json", .blob).notNull()
            }
            try db.create(table: "pendingMeta") { t in
                t.primaryKey("itemID", .text)
                t.column("files", .blob).notNull()
                t.column("json", .blob).notNull()
                t.column("error", .text)
            }
        }
        return m
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// `SELECT … WHERE key IN (…)` in chunks (SQLite limits the number of bound parameters).
    private static func fetch(_ db: Database, table: String, columns: String, key: String, values: [String]) throws -> [Row] {
        var rows: [Row] = []
        var i = 0
        while i < values.count {
            let chunk = Array(values[i..<min(i + 500, values.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            rows += try Row.fetchAll(db, sql: "SELECT \(columns) FROM \(table) WHERE \(key) IN (\(marks))",
                                     arguments: StatementArguments(chunk))
            i += 500
        }
        return rows
    }

    // MARK: EXIF

    /// Cached EXIF for files whose size + mtime still match. Keyed by path.
    public func cachedExif(for files: [FileRef]) -> [String: ExifInfo] {
        guard !files.isEmpty else { return [:] }
        let wanted = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: ExifInfo] = [:]
        try? db.read { db in
            for row in try Self.fetch(db, table: "exif", columns: "path, size, mtime, json", key: "path", values: Array(wanted.keys)) {
                let path: String = row["path"]
                guard let f = wanted[path], f.size == row["size"] as Int64,
                      abs(f.modificationDate.timeIntervalSince1970 - (row["mtime"] as Double)) < 0.001,
                      let e = try? Self.decoder.decode(ExifInfo.self, from: row["json"] as Data) else { continue }
                out[path] = e
            }
        }
        return out
    }

    public func storeExif(_ entries: [(FileRef, ExifInfo)]) {
        guard !entries.isEmpty else { return }
        try? db.write { db in
            for (f, e) in entries {
                guard let data = try? Self.encoder.encode(e) else { continue }
                try db.execute(sql: "INSERT OR REPLACE INTO exif (path, size, mtime, json) VALUES (?, ?, ?, ?)",
                               arguments: [f.path, f.size, f.modificationDate.timeIntervalSince1970, data])
            }
        }
    }

    // MARK: Item metadata

    /// Signature of everything an item's metadata is read from: all files + the sidecar.
    public static func signature(of item: ItemFiles) -> String {
        var parts = item.files.map(\.cacheKey)
        if let sc = item.sidecarURL, let f = try? sc.freshResourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            parts.append("\(sc.path)|\(f.fileSize ?? 0)|\(Int64((f.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000))")
        }
        return parts.joined(separator: "\n")
    }

    public func cachedMetadata(for items: [(id: String, signature: String)]) -> [String: PhotoMetadata] {
        guard !items.isEmpty else { return [:] }
        let wanted = Dictionary(items.map { ($0.id, $0.signature) }, uniquingKeysWith: { a, _ in a })
        var out: [String: PhotoMetadata] = [:]
        try? db.read { db in
            for row in try Self.fetch(db, table: "itemMeta", columns: "itemID, signature, json", key: "itemID", values: Array(wanted.keys)) {
                let id: String = row["itemID"]
                guard let sig = wanted[id], sig == row["signature"] as String,
                      let m = try? Self.decoder.decode(PhotoMetadata.self, from: row["json"] as Data) else { continue }
                out[id] = m
            }
        }
        return out
    }

    public func storeMetadata(_ entries: [(id: String, signature: String, metadata: PhotoMetadata)]) {
        guard !entries.isEmpty else { return }
        try? db.write { db in
            for e in entries {
                guard let data = try? Self.encoder.encode(e.metadata) else { continue }
                try db.execute(sql: "INSERT OR REPLACE INTO itemMeta (itemID, signature, json) VALUES (?, ?, ?)",
                               arguments: [e.id, e.signature, data])
            }
        }
    }

    // MARK: Pending writes

    public struct PendingWrite: Sendable {
        public var itemID: String
        public var files: ItemFiles
        public var metadata: PhotoMetadata
        public var error: String?
    }

    public func setPending(itemID: String, files: ItemFiles, metadata: PhotoMetadata, error: String?) {
        guard let f = try? Self.encoder.encode(files), let m = try? Self.encoder.encode(metadata) else { return }
        try? db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO pendingMeta (itemID, files, json, error) VALUES (?, ?, ?, ?)",
                           arguments: [itemID, f, m, error])
        }
    }

    public func clearPending(itemID: String) {
        try? db.write { db in try db.execute(sql: "DELETE FROM pendingMeta WHERE itemID = ?", arguments: [itemID]) }
    }

    public func pendingWrites(inFolder folder: URL) -> [PendingWrite] {
        // Item IDs may carry the /private firmlink prefix or not, depending on how the folder URL was obtained.
        let resolved = folder.resolvingSymlinksInPath().path
        let prefixes = Set([folder.standardizedFileURL.path, resolved, "/private" + resolved]).map { $0 + "/" }
        var out: [PendingWrite] = []
        try? db.read { db in
            for row in try Row.fetchAll(db, sql: "SELECT itemID, files, json, error FROM pendingMeta") {
                let id: String = row["itemID"]
                guard prefixes.contains(where: id.hasPrefix),
                      let f = try? Self.decoder.decode(ItemFiles.self, from: row["files"] as Data),
                      let m = try? Self.decoder.decode(PhotoMetadata.self, from: row["json"] as Data) else { continue }
                out.append(PendingWrite(itemID: id, files: f, metadata: m, error: row["error"]))
            }
        }
        return out
    }

    public func removeAll() {
        try? db.write { db in
            try db.execute(sql: "DELETE FROM exif")
            try db.execute(sql: "DELETE FROM itemMeta")
        }
    }
}
