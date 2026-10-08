import XCTest
@testable import CullerKit

final class FileOperationTests: XCTestCase {
    func ctx(_ base: String, _ date: String = "2024:05:01 10:20:30") -> RenameTemplate.Context {
        let d = ExifReader.parseCaptureDate(date, subsec: nil, offset: "+07:00")!
        return .init(originalBaseName: base, captureDate: d.date, timeZone: TimeZone(secondsFromGMT: d.offset!)!,
                     camera: "Canon EOS R5", lens: "RF 24/70", rating: 3)
    }

    func testTemplateRendering() throws {
        let t = try RenameTemplate("{date:yyyyMMdd}_{seq:4}_{original}")
        XCTAssertEqual(t.render(ctx("IMG_1"), sequence: 7), "20240501_0007_IMG_1")
        XCTAssertEqual(try RenameTemplate("{time}-{camera}-{lens}-r{rating}").render(ctx("x"), sequence: 1),
                       "102030-Canon EOS R5-RF 24-70-r3")
        XCTAssertEqual(try RenameTemplate("{seq:2}").render(ctx("x"), sequence: 123), "123", "padding never truncates")
        XCTAssertThrowsError(try RenameTemplate("{bogus}"))
        XCTAssertThrowsError(try RenameTemplate("{date"))
        XCTAssertThrowsError(try RenameTemplate("{seq:0}"))
    }

    func testRenamePairWithSidecarAndCollisions() throws {
        let dir = try TestSupport.tempDir()
        TestSupport.makeFakeRaw(dir.appendingPathComponent("IMG_1.CR3"))
        TestSupport.makeImage(dir.appendingPathComponent("IMG_1.JPG"))
        try Data("<x/>".utf8).write(to: dir.appendingPathComponent("IMG_1.xmp"))
        TestSupport.makeImage(dir.appendingPathComponent("IMG_2.jpg"))
        TestSupport.makeImage(dir.appendingPathComponent("shoot.jpg"))   // existing file not in the batch

        let items = try TestSupport.items(dir).filter { $0.baseName != "shoot" }
        XCTAssertEqual(items.count, 2)
        let template = try RenameTemplate("shoot")
        let plans = FileOperations.planRename(items.map { .init(itemID: $0.primary.path, files: $0, context: ctx($0.baseName)) },
                                              template: template, sequenceStart: 1)
        XCTAssertEqual(plans.map(\.newBaseName), ["shoot-1", "shoot-2"])
        XCTAssertTrue(plans.allSatisfy(\.hadCollision))

        let done = try FileOperations.executeRename(plans)
        XCTAssertEqual(done.count, 2)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(names, ["shoot.jpg", "shoot-1.CR3", "shoot-1.JPG", "shoot-1.xmp", "shoot-2.jpg"],
                       "extensions keep their case; pair + sidecar renamed together")
    }

    func testRenameSwapWithinBatch() throws {
        let dir = try TestSupport.tempDir()
        TestSupport.makeImage(dir.appendingPathComponent("A.jpg"))
        TestSupport.makeImage(dir.appendingPathComponent("B.jpg"))
        let a = Data(try Data(contentsOf: dir.appendingPathComponent("A.jpg")))
        let items = try TestSupport.items(dir)
        // Reverse order so that A → "B" and B → "A"  via {seq} mapped names.
        let template = try RenameTemplate("{original}")
        var plans = FileOperations.planRename(items.map { .init(itemID: $0.primary.path, files: $0, context: ctx($0.baseName)) },
                                              template: template, sequenceStart: 1)
        plans[0].newBaseName = "B"; plans[0].moves = [FileMove(from: dir.appendingPathComponent("A.jpg"), to: dir.appendingPathComponent("B.jpg"))]
        plans[1].newBaseName = "A"; plans[1].moves = [FileMove(from: dir.appendingPathComponent("B.jpg"), to: dir.appendingPathComponent("A.jpg"))]
        _ = try FileOperations.executeRename(plans)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("B.jpg")), a)
    }

    func testNoCollisionWhenNameFreedByBatch() throws {
        let dir = try TestSupport.tempDir()
        TestSupport.makeImage(dir.appendingPathComponent("x_0001.jpg"))
        let items = try TestSupport.items(dir)
        let plans = FileOperations.planRename(items.map { .init(itemID: $0.primary.path, files: $0, context: ctx($0.baseName)) },
                                              template: try RenameTemplate("x_{seq:4}"), sequenceStart: 1)
        XCTAssertEqual(plans.first?.newBaseName, "x_0001")
        XCTAssertTrue(plans.first!.isNoOp)
    }

    /// Spec §16 "Move cross-volume": source removed only after verified copy.
    func testCrossVolumeMoveVerifiesBeforeDeleting() throws {
        let src = try TestSupport.tempDir(), dst = try TestSupport.tempDir()
        TestSupport.makeFakeRaw(src.appendingPathComponent("A.CR3"))
        TestSupport.makeImage(src.appendingPathComponent("A.JPG"))
        let items = try TestSupport.items(src)
        let plans = FileOperations.planTransfer(items.map { ($0.primary.path, $0) }, to: dst)

        // Corrupt the copy → verification fails → nothing deleted, nothing left at destination.
        let corrupt = FileOperations.TransferHooks(afterCopy: { m in
            if m.to.pathExtension == "CR3" { try Data("corrupt".utf8).write(to: m.to) }
        }, forceCrossVolume: true)
        let bad = FileOperations.executeTransfer(plans, mode: .move, hooks: corrupt)
        XCTAssertEqual(bad.failed.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dst.path), [])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: src.path)), ["A.CR3", "A.JPG"])

        let ok = FileOperations.executeTransfer(plans, mode: .move, hooks: .init(forceCrossVolume: true))
        XCTAssertEqual(ok.completed.count, 1, "\(ok.failed)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: src.path), [])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dst.path)), ["A.CR3", "A.JPG"])
    }

    /// Spec §16: cancellation leaves no partial items.
    func testCancellationLeavesNoPartialItems() throws {
        let src = try TestSupport.tempDir(), dst = try TestSupport.tempDir()
        for i in 1...3 {
            TestSupport.makeFakeRaw(src.appendingPathComponent("P\(i).CR3"))
            TestSupport.makeImage(src.appendingPathComponent("P\(i).JPG"))
        }
        let items = try TestSupport.items(src)
        let plans = FileOperations.planTransfer(items.map { ($0.primary.path, $0) }, to: dst)
        let flag = CancelFlag()
        // Cancel in the middle of the second item (after its first file was copied).
        let hooks = FileOperations.TransferHooks(afterCopy: { m in
            if m.from.lastPathComponent == "P2.JPG" { flag.cancel() }
        }, forceCrossVolume: true)
        let r = FileOperations.executeTransfer(plans, mode: .move, hooks: hooks, isCancelled: { flag.isCancelled })
        XCTAssertTrue(r.cancelled)
        XCTAssertEqual(r.completed.map(\.newBaseName), ["P1"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dst.path)), ["P1.CR3", "P1.JPG"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: src.path)), ["P2.CR3", "P2.JPG", "P3.CR3", "P3.JPG"])
    }

    func testCopyCollisionSuffix() throws {
        let src = try TestSupport.tempDir(), dst = try TestSupport.tempDir()
        TestSupport.makeImage(src.appendingPathComponent("A.jpg"))
        TestSupport.makeImage(dst.appendingPathComponent("a.JPG"))
        let items = try TestSupport.items(src)
        let plans = FileOperations.planTransfer(items.map { ($0.primary.path, $0) }, to: dst)
        XCTAssertEqual(plans.first?.newBaseName, "A-1")
        let r = FileOperations.executeTransfer(plans, mode: .copy)
        XCTAssertEqual(r.completed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("A.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent("A-1.jpg").path))
    }

    /// Spec §16 "Undo": rename undo, move undo after app restart; refused when the file changed externally.
    func testUndoRenameAndMoveAcrossRestart() throws {
        let dir = try TestSupport.tempDir(), dst = try TestSupport.tempDir()
        let logURL = dir.appendingPathComponent("log.jsonl")
        TestSupport.makeImage(dir.appendingPathComponent("A.jpg"))
        var log = OperationLog(url: logURL)

        let items = try TestSupport.items(dir)
        let plans = try FileOperations.executeRename(FileOperations.planRename(
            items.map { .init(itemID: $0.primary.path, files: $0, context: ctx($0.baseName)) },
            template: try RenameTemplate("renamed"), sequenceStart: 1))
        let rec = OperationRecord.make(kind: .rename, plans: plans)
        log.record(rec)
        try log.undo(rec)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("A.jpg").path))
        try log.redo(rec)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("renamed.jpg").path))

        // Move, then "restart" (new log instance reading the file), then undo.
        let moved = try TestSupport.items(dir).filter { $0.primary.kind == .jpeg }
        let mplans = FileOperations.planTransfer(moved.map { ($0.primary.path, $0) }, to: dst)
        let res = FileOperations.executeTransfer(mplans, mode: .move)
        let mrec = OperationRecord.make(kind: .move, plans: res.completed)
        log.record(mrec)
        log = OperationLog(url: logURL)
        XCTAssertEqual(log.all.count, 2)
        XCTAssertEqual(log.all.first?.undone, false)
        let reloaded = try XCTUnwrap(log.all.last)
        try log.undo(reloaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("renamed.jpg").path))
        XCTAssertEqual(OperationLog(url: logURL).all.last?.undone, true)
    }

    func testUndoRefusedWhenFileChanged() throws {
        let dir = try TestSupport.tempDir()
        TestSupport.makeImage(dir.appendingPathComponent("A.jpg"))
        let log = OperationLog(url: dir.appendingPathComponent("log.jsonl"))
        let items = try TestSupport.items(dir)
        let plans = try FileOperations.executeRename(FileOperations.planRename(
            items.map { .init(itemID: $0.primary.path, files: $0, context: ctx($0.baseName)) },
            template: try RenameTemplate("B"), sequenceStart: 1))
        let rec = OperationRecord.make(kind: .rename, plans: plans)
        log.record(rec)
        // External modification.
        try Data("changed".utf8).write(to: dir.appendingPathComponent("B.jpg"))
        XCTAssertThrowsError(try log.undo(rec)) { e in
            guard case UndoError.fileChanged = e else { return XCTFail("\(e)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("B.jpg").path), "never guess")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("B.jpg"))
        XCTAssertThrowsError(try log.undo(rec)) { e in
            guard case UndoError.fileMissing = e else { return XCTFail("\(e)") }
        }
    }

    func testUndoCopyTrashesCopies() throws {
        let src = try TestSupport.tempDir(), dst = try TestSupport.tempDir()
        TestSupport.makeImage(src.appendingPathComponent("A.jpg"))
        let log = OperationLog(url: src.appendingPathComponent("log.jsonl"))
        let items = try TestSupport.items(src)
        let r = FileOperations.executeTransfer(FileOperations.planTransfer(items.map { ($0.primary.path, $0) }, to: dst), mode: .copy)
        let rec = OperationRecord.make(kind: .copy, plans: r.completed)
        log.record(rec)
        try log.undo(rec)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent("A.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("A.jpg").path))
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func cancel() { lock.withLock { v = true } }
    var isCancelled: Bool { lock.withLock { v } }
}
