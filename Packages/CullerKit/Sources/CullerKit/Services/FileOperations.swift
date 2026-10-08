import Foundation
import CryptoKit

/// One file moving from one path to another (rename, move, or the destination of a copy).
public struct FileMove: Codable, Equatable, Hashable, Sendable {
    public var from: URL
    public var to: URL
    public init(from: URL, to: URL) {
        self.from = from
        self.to = to
    }
}

/// The plan for one item: every file of the item (images + sidecar) goes to the same new base name.
public struct ItemPlan: Equatable, Sendable, Identifiable {
    public var id: String { itemID }
    public var itemID: String
    public var oldBaseName: String
    /// Base name before collision suffixing.
    public var proposedBaseName: String
    public var newBaseName: String
    public var moves: [FileMove]
    public var hadCollision: Bool { proposedBaseName != newBaseName }
    public var isNoOp: Bool { moves.allSatisfy { $0.from.standardizedFileURL == $0.to.standardizedFileURL } }
}

public enum TransferMode: String, Codable, Sendable {
    case move
    case copy
}

public enum FileOperationError: Error, LocalizedError {
    case verificationFailed(URL)
    case destinationExists(URL)
    case sourceMissing(URL)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .verificationFailed(let u): return "Copy of \(u.lastPathComponent) did not verify (size/checksum mismatch)"
        case .destinationExists(let u): return "\(u.lastPathComponent) already exists at the destination"
        case .sourceMissing(let u): return "\(u.lastPathComponent) is missing"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Rename / move / copy planning and execution (spec §8). Items are the unit of atomicity:
/// either every file of an item ends up at its destination, or none does.
public enum FileOperations {
    // MARK: Collision handling

    /// Picks `base`, `base-1`, `base-2`, … such that none of the item's target names is taken.
    /// Comparison is case-insensitive (APFS/HFS+ default).
    static func resolveCollision(base: String, extensions: [String], isTaken: (String) -> Bool) -> String {
        var candidate = base
        var n = 0
        while extensions.contains(where: { isTaken("\(candidate).\($0)".lowercased()) }) {
            n += 1
            candidate = "\(base)-\(n)"
        }
        return candidate
    }

    /// Extensions of all files of an item, original case preserved (sidecar included).
    static func extensions(of item: ItemFiles) -> [String] {
        item.allURLs.map(\.pathExtension)
    }

    static func existingNames(in folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.map { $0.lowercased() })
    }

    // MARK: Rename

    public struct RenameInput: Sendable {
        public var itemID: String
        public var files: ItemFiles
        public var context: RenameTemplate.Context
        public init(itemID: String, files: ItemFiles, context: RenameTemplate.Context) {
            self.itemID = itemID
            self.files = files
            self.context = context
        }
    }

    /// Builds the old → new table. Names freed by other items of the same batch count as available.
    public static func planRename(_ inputs: [RenameInput], template: RenameTemplate, sequenceStart: Int) -> [ItemPlan] {
        let sources = Set(inputs.flatMap { $0.files.allURLs.map { $0.standardizedFileURL.path.lowercased() } })
        var taken: [String: Set<String>] = [:]   // folder path → lowercased names that are occupied
        func occupied(_ folder: URL) -> Set<String> {
            let key = folder.standardizedFileURL.path
            if let t = taken[key] { return t }
            let names = existingNames(in: folder).filter { !sources.contains(folder.appendingPathComponent($0).standardizedFileURL.path.lowercased()) }
            taken[key] = names
            return names
        }

        var plans: [ItemPlan] = []
        for (i, input) in inputs.enumerated() {
            let folder = input.files.folder
            let proposed = template.render(input.context, sequence: sequenceStart + i)
            let exts = extensions(of: input.files)
            let occ = occupied(folder)
            let base = resolveCollision(base: proposed, extensions: exts) { occ.contains($0) }
            taken[folder.standardizedFileURL.path, default: []].formUnion(exts.map { "\(base).\($0)".lowercased() })
            let moves = input.files.allURLs.map {
                FileMove(from: $0, to: folder.appendingPathComponent(base).appendingPathExtension($0.pathExtension))
            }
            plans.append(ItemPlan(itemID: input.itemID, oldBaseName: input.files.baseName,
                                  proposedBaseName: proposed, newBaseName: base, moves: moves))
        }
        return plans
    }

    /// Executes renames in two phases (all → temp names → final names) so swaps and chains work.
    /// On any failure every completed step is rolled back.
    public static func executeRename(_ plans: [ItemPlan]) throws -> [ItemPlan] {
        let active = plans.filter { !$0.isNoOp }
        let moves = active.flatMap(\.moves)
        try executeTwoPhase(moves)
        return active
    }

    static func executeTwoPhase(_ moves: [FileMove]) throws {
        let fm = FileManager.default
        var done: [(from: URL, to: URL)] = []
        func rollback() {
            for step in done.reversed() { try? fm.moveItem(at: step.to, to: step.from) }
        }
        var temps: [(tmp: URL, final: URL)] = []
        do {
            for m in moves {
                guard fm.fileExists(atPath: m.from.path) else { throw FileOperationError.sourceMissing(m.from) }
                let tmp = m.from.deletingLastPathComponent()
                    .appendingPathComponent(".culler-rename-\(UUID().uuidString.prefix(8))-\(m.from.lastPathComponent)")
                try fm.moveItem(at: m.from, to: tmp)
                done.append((m.from, tmp))
                temps.append((tmp, m.to))
            }
            for t in temps {
                if fm.fileExists(atPath: t.final.path) { throw FileOperationError.destinationExists(t.final) }
                try fm.moveItem(at: t.tmp, to: t.final)
                done.append((t.tmp, t.final))
            }
        } catch {
            rollback()
            throw error
        }
    }

    // MARK: Move / copy

    public static func planTransfer(_ items: [(itemID: String, files: ItemFiles)], to destination: URL) -> [ItemPlan] {
        var occ = existingNames(in: destination)
        var plans: [ItemPlan] = []
        for item in items {
            let exts = extensions(of: item.files)
            let base = resolveCollision(base: item.files.baseName, extensions: exts) { occ.contains($0) }
            occ.formUnion(exts.map { "\(base).\($0)".lowercased() })
            let moves = item.files.allURLs.map {
                FileMove(from: $0, to: destination.appendingPathComponent(base).appendingPathExtension($0.pathExtension))
            }
            plans.append(ItemPlan(itemID: item.itemID, oldBaseName: item.files.baseName,
                                  proposedBaseName: item.files.baseName, newBaseName: base, moves: moves))
        }
        return plans
    }

    public struct TransferResult: Sendable {
        public var completed: [ItemPlan] = []
        public var failed: [(itemID: String, error: String)] = []
        public var cancelled = false
    }

    /// Hooks for tests (simulate failures / cancellation at precise points).
    public struct TransferHooks: Sendable {
        /// Called after each file is copied, before verification. Throwing aborts the item.
        public var afterCopy: (@Sendable (FileMove) throws -> Void)?
        /// Forces the cross-volume path even on one volume.
        public var forceCrossVolume = false
        public init(afterCopy: (@Sendable (FileMove) throws -> Void)? = nil, forceCrossVolume: Bool = false) {
            self.afterCopy = afterCopy
            self.forceCrossVolume = forceCrossVolume
        }
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let ka = try? a.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let kb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let ka, let kb else { return false }
        return ka.isEqual(kb)
    }

    /// Moves or copies items one by one. Cancellation is checked between items; an interrupted item is rolled back.
    public static func executeTransfer(_ plans: [ItemPlan], mode: TransferMode, hooks: TransferHooks = .init(),
                                       isCancelled: @Sendable () -> Bool = { false },
                                       progress: @Sendable (Int, Int) -> Void = { _, _ in }) -> TransferResult {
        var result = TransferResult()
        for (i, plan) in plans.enumerated() {
            if isCancelled() { result.cancelled = true; break }
            do {
                try transferItem(plan, mode: mode, hooks: hooks, isCancelled: isCancelled)
                result.completed.append(plan)
            } catch FileOperationError.cancelled {
                result.cancelled = true
                break
            } catch {
                result.failed.append((plan.itemID, error.localizedDescription))
            }
            progress(i + 1, plans.count)
        }
        return result
    }

    static func transferItem(_ plan: ItemPlan, mode: TransferMode, hooks: TransferHooks, isCancelled: () -> Bool) throws {
        let fm = FileManager.default
        for m in plan.moves {
            guard fm.fileExists(atPath: m.from.path) else { throw FileOperationError.sourceMissing(m.from) }
            if fm.fileExists(atPath: m.to.path) { throw FileOperationError.destinationExists(m.to) }
        }
        let crossVolume = hooks.forceCrossVolume || !(plan.moves.first.map { sameVolume($0.to, $0.from) } ?? true)

        if mode == .move && !crossVolume {
            // Same volume: atomic renames; roll back the item on failure.
            var done: [FileMove] = []
            do {
                for m in plan.moves {
                    try fm.moveItem(at: m.from, to: m.to)
                    done.append(m)
                }
            } catch {
                for m in done.reversed() { try? fm.moveItem(at: m.to, to: m.from) }
                throw error
            }
            return
        }

        // Copy (or cross-volume move): copy → verify → (move only) delete sources after all files verified.
        var copied: [URL] = []
        do {
            for m in plan.moves {
                if isCancelled() { throw FileOperationError.cancelled }
                try fm.copyItem(at: m.from, to: m.to)
                copied.append(m.to)
                try hooks.afterCopy?(m)
                guard try verifyCopy(m.from, m.to) else { throw FileOperationError.verificationFailed(m.from) }
            }
        } catch {
            for u in copied { try? fm.removeItem(at: u) }
            throw error
        }
        if mode == .move {
            for m in plan.moves { try fm.removeItem(at: m.from) }
        }
    }

    /// Size + SHA-256 comparison.
    public static func verifyCopy(_ a: URL, _ b: URL) throws -> Bool {
        let sa = try a.freshResourceValues(forKeys: [.fileSizeKey]).fileSize
        let sb = try b.freshResourceValues(forKeys: [.fileSizeKey]).fileSize
        guard sa == sb else { return false }
        return try sha256(a) == sha256(b)
    }

    public static func sha256(_ url: URL) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}
