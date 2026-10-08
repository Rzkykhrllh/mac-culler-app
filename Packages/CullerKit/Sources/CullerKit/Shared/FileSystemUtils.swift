import Foundation
import Darwin

/// Extended attribute helpers (no-follow semantics are not needed: we only touch regular files).
public enum XAttr {
    public static func get(_ name: String, at url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let len = getxattr(path, name, nil, 0, 0, 0)
            guard len > 0 else { return nil }
            var data = Data(count: len)
            let r = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, len, 0, 0) }
            return r == len ? data : nil
        }
    }

    @discardableResult
    public static func set(_ name: String, data: Data, at url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) } == 0
        }
    }

    @discardableResult
    public static func remove(_ name: String, at url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return removexattr(path, name, 0) == 0
        }
    }

    public static func list(at url: URL) -> [String] {
        url.withUnsafeFileSystemRepresentation { path -> [String] in
            guard let path else { return [] }
            let len = listxattr(path, nil, 0, 0)
            guard len > 0 else { return [] }
            var buf = [CChar](repeating: 0, count: len)
            guard listxattr(path, &buf, len, 0) == len else { return [] }
            return buf.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        }
    }

    /// Copies every extended attribute from one file to another (used so atomic replacement keeps Finder tags etc.).
    public static func copyAll(from src: URL, to dst: URL, except: Set<String> = []) {
        for name in list(at: src) where !except.contains(name) {
            if let d = get(name, at: src) { set(name, data: d, at: dst) }
        }
    }
}

public enum AtomicFileError: Error, LocalizedError {
    case injectedFailure
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .injectedFailure: return "Simulated failure"
        case .writeFailed(let s): return s
        }
    }
}

/// Atomic file replacement: write to a temp file in the same directory, then swap it in.
/// On any failure the original file is left untouched and the temp file is removed (spec §5.3.3).
public enum AtomicFile {
    /// Test hook invoked after the temp file has been fully written, just before it replaces the original.
    public typealias BeforeReplaceHook = @Sendable (URL) throws -> Void

    public static func tempURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).culler-tmp-\(UUID().uuidString.prefix(8))")
    }

    /// - Parameter produce: writes the new content to the given temp URL.
    public static func replace(_ url: URL, beforeReplace: BeforeReplaceHook? = nil, produce: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let tmp = tempURL(for: url)
        do {
            try produce(tmp)
            guard fm.fileExists(atPath: tmp.path) else { throw AtomicFileError.writeFailed("Temporary file was not created") }
            let exists = fm.fileExists(atPath: url.path)
            if exists { XAttr.copyAll(from: url, to: tmp) }
            try beforeReplace?(tmp)
            if exists {
                _ = try fm.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, options: [])
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    public static func write(_ data: Data, to url: URL, beforeReplace: BeforeReplaceHook? = nil) throws {
        try replace(url, beforeReplace: beforeReplace) { tmp in
            try data.write(to: tmp, options: [.withoutOverwriting])
        }
    }
}

extension URL {
    /// Resource values read from disk, bypassing the per-instance cache `URL` keeps
    /// (a reused URL would otherwise report a stale size / modification date).
    public func freshResourceValues(forKeys keys: Set<URLResourceKey>) throws -> URLResourceValues {
        var u = self
        u.removeAllCachedResourceValues()
        return try u.resourceValues(forKeys: keys)
    }
}

/// Runs blocking work (Vision, Core Image renders) on its own GCD queue, never on Swift concurrency's
/// cooperative pool: Vision waits on internal work that needs threads, and blocking every pool thread
/// with it deadlocks the process.
public enum Offload {
    /// At most 3 jobs at once. Waiting jobs sit in the queue without a thread (a semaphore inside a GCD block
    /// parked one thread per waiting job: hundreds with a large folder).
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "PhotoCuller.offload"
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility
        return q
    }()

    public static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            queue.addOperation { cont.resume(returning: work()) }
        }
    }
}
