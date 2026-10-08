import XCTest
@testable import CullerKit

final class TrashTests: XCTestCase {
    /// A fake Trash: files move into a temp folder (unique names), never the user's real Trash.
    func fakeTrash() throws -> (URL, FileOperations.Trasher) {
        let bin = try TestSupport.tempDir("bin")
        return (bin, { url in
            let dest = bin.appendingPathComponent(UUID().uuidString.prefix(6) + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        })
    }

    func testTrashMovesEveryFileOfAPairWithSidecar() throws {
        let dir = try TestSupport.tempDir()
        TestSupport.makeFakeRaw(dir.appendingPathComponent("A.RAF"))
        TestSupport.makeImage(dir.appendingPathComponent("A.JPG"))
        try Data("<x/>".utf8).write(to: dir.appendingPathComponent("A.xmp"))
        TestSupport.makeImage(dir.appendingPathComponent("B.JPG"))
        let (bin, trasher) = try fakeTrash()
        let pair = try XCTUnwrap(TestSupport.items(dir).first { $0.isPair })
        let r = FileOperations.trash([(pair.primary.path, pair)], trasher: trasher)
        XCTAssertEqual(r.completed.count, 1)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["B.JPG"], "only the other photo stays")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bin.path).count, 3, "RAW + JPG + sidecar in the Trash")
    }

    func testFailedTrashPutsTheItemBack() throws {
        let dir = try TestSupport.tempDir()
        TestSupport.makeFakeRaw(dir.appendingPathComponent("A.RAF"))
        TestSupport.makeImage(dir.appendingPathComponent("A.JPG"))
        let (_, good) = try fakeTrash()
        let calls = EventCounter()
        let flaky: FileOperations.Trasher = { url in
            calls.bump()
            if calls.value == 2 { throw FileOperationError.cancelled }
            return try good(url)
        }
        let pair = try XCTUnwrap(TestSupport.items(dir).first)
        let r = FileOperations.trash([(pair.primary.path, pair)], trasher: flaky)
        XCTAssertEqual(r.failed.count, 1)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["A.RAF", "A.JPG"], "all or nothing per photo")
    }

    func testUndoRedoTrashAcrossRestart() throws {
        let dir = try TestSupport.tempDir()
        TestSupport.makeImage(dir.appendingPathComponent("A.jpg"))
        let (_, trasher) = try fakeTrash()
        let logURL = try TestSupport.tempDir("log").appendingPathComponent("ops.jsonl")
        var log = OperationLog(url: logURL)
        log.trasher = trasher
        let item = try XCTUnwrap(TestSupport.items(dir).first)
        let res = FileOperations.trash([(item.primary.path, item)], trasher: trasher)
        let rec = OperationRecord.make(kind: .trash, plans: res.completed)
        log.record(rec)
        XCTAssertEqual(rec.summary, "Moved 1 item to the Trash")

        log = OperationLog(url: logURL)        // "restart"
        log.trasher = trasher
        try log.undo(try XCTUnwrap(log.all.last))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("A.jpg").path), "restored from the Trash")

        try log.redo(try XCTUnwrap(log.all.last))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("A.jpg").path))
        let again = try XCTUnwrap(OperationLog(url: logURL).all.last)
        XCTAssertTrue(FileManager.default.fileExists(atPath: again.entries[0].to), "redo recorded the new Trash path")
        XCTAssertFalse(again.undone)

        // Undo is refused if the trashed file was changed meanwhile.
        try Data("changed".utf8).write(to: URL(fileURLWithPath: again.entries[0].to))
        XCTAssertThrowsError(try OperationLog(url: logURL).undo(again))
    }
}
