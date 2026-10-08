import XCTest
@testable import CullerKit

final class ScanAndStackTests: XCTestCase {
    /// Spec §16 "Pairing": exact base-name match only; pairing off yields separate items.
    func testPairingExactBaseNameOnly() throws {
        let dir = try TestSupport.tempDir()
        TestSupport.makeFakeRaw(dir.appendingPathComponent("IMG_001.CR3"))
        TestSupport.makeImage(dir.appendingPathComponent("IMG_001.JPG"))
        TestSupport.makeImage(dir.appendingPathComponent("IMG_001-edit.JPG"))
        TestSupport.makeImage(dir.appendingPathComponent("IMG_002.heic"), type: .heic)
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".hidden.jpg"))

        let paired = try TestSupport.items(dir)
        XCTAssertEqual(paired.count, 3)
        let pair = try XCTUnwrap(paired.first { $0.isPair })
        XCTAssertEqual(Set(pair.files.map(\.fileName)), ["IMG_001.CR3", "IMG_001.JPG"])
        XCTAssertEqual(pair.primary.fileName, "IMG_001.JPG", "display uses the JPEG")
        XCTAssertEqual(pair.raw?.fileName, "IMG_001.CR3")
        XCTAssertEqual(pair.badge, "RAW+JPG")
        XCTAssertTrue(paired.contains { $0.primary.fileName == "IMG_001-edit.JPG" && !$0.isPair })

        let unpaired = try TestSupport.items(dir, pair: false)
        XCTAssertEqual(unpaired.count, 4)
        XCTAssertTrue(unpaired.allSatisfy { !$0.isPair })
    }

    func testSidecarAttachesToRawItem() throws {
        let dir = try TestSupport.tempDir()
        TestSupport.makeFakeRaw(dir.appendingPathComponent("A.NEF"))
        TestSupport.makeImage(dir.appendingPathComponent("A.JPG"))
        try Data().write(to: dir.appendingPathComponent("A.xmp"))
        let unpaired = try TestSupport.items(dir, pair: false)
        XCTAssertEqual(unpaired.first { $0.primary.kind == .raw }?.sidecarURL?.lastPathComponent, "A.xmp")
        XCTAssertNil(unpaired.first { $0.primary.kind == .jpeg }?.sidecarURL)
        XCTAssertEqual(try TestSupport.items(dir).first?.sidecarURL?.lastPathComponent, "A.xmp")
    }

    func testSubfolderScanning() throws {
        let dir = try TestSupport.tempDir()
        let sub = dir.appendingPathComponent("day2", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        TestSupport.makeImage(dir.appendingPathComponent("a.jpg"))
        TestSupport.makeImage(sub.appendingPathComponent("a.jpg"))
        XCTAssertEqual(try FolderScanner.scan(folder: dir, options: ScanOptions(includeSubfolders: false)).count, 1)
        XCTAssertEqual(try FolderScanner.scan(folder: dir, options: ScanOptions(includeSubfolders: true)).count, 2,
                       "same base name in different folders must not pair")
        XCTAssertEqual(FolderScanner.countImages(folder: dir, includeSubfolders: true), 2)
    }

    func testSubfolderScanningGoesAllLevelsDeep() throws {
        let dir = try TestSupport.tempDir()
        let deep = dir.appendingPathComponent("A/B/C", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        TestSupport.makeImage(dir.appendingPathComponent("top.jpg"))
        TestSupport.makeImage(dir.appendingPathComponent("A/one.jpg"))
        TestSupport.makeImage(dir.appendingPathComponent("A/B/two.jpg"))
        TestSupport.makeImage(deep.appendingPathComponent("three.jpg"))
        XCTAssertEqual(try FolderScanner.scan(folder: dir, options: ScanOptions(includeSubfolders: false)).count, 1)
        let all = try FolderScanner.scan(folder: dir, options: ScanOptions(includeSubfolders: true))
        XCTAssertEqual(Set(all.map(\.primary.url.lastPathComponent)), ["top.jpg", "one.jpg", "two.jpg", "three.jpg"])
    }

    func testExifCaptureDateWithSubsecAndOffset() throws {
        let r = try XCTUnwrap(ExifReader.parseCaptureDate("2024:05:01 10:00:00", subsec: "250", offset: "+07:00"))
        XCTAssertEqual(r.offset, 7 * 3600)
        XCTAssertEqual(r.date.timeIntervalSince1970, 1714532400.25, accuracy: 0.0001)

        let dir = try TestSupport.tempDir()
        let url = TestSupport.makeImage(dir.appendingPathComponent("a.jpg"), subsec: "5", serial: "123")
        let e = try XCTUnwrap(ExifReader.read(url))
        XCTAssertEqual(e.cameraName, "Canon EOS R5")
        XCTAssertEqual(e.bodyKey, "serial:123")
        XCTAssertEqual(e.iso, 400)
        XCTAssertEqual(e.aperture, 2.8)
        XCTAssertEqual(e.lens, "RF24-70mm")
        XCTAssertEqual(e.pixelWidth, 96)
    }

    private func t(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + s) }

    /// Spec §16 "Stacks": threshold boundary (exactly 1.0 s in, 1.01 s out).
    func testStackThresholdBoundary() {
        let inputs = [
            StackBuilder.Input(id: "a", captureDate: t(0), bodyKey: "x"),
            StackBuilder.Input(id: "b", captureDate: t(1.0), bodyKey: "x"),
            StackBuilder.Input(id: "c", captureDate: t(2.01), bodyKey: "x"),
        ]
        XCTAssertEqual(StackBuilder.build(inputs, threshold: 1.0), [["a", "b"], ["c"]])

        // Same check through EXIF sub-second parsing (10:00:00.000 → 10:00:01.000 → 10:00:02.010).
        let d0 = ExifReader.parseCaptureDate("2024:05:01 10:00:00", subsec: "000", offset: nil)!.date
        let d1 = ExifReader.parseCaptureDate("2024:05:01 10:00:01", subsec: "000", offset: nil)!.date
        let d2 = ExifReader.parseCaptureDate("2024:05:01 10:00:02", subsec: "010", offset: nil)!.date
        let viaExif = StackBuilder.build([.init(id: "a", captureDate: d0, bodyKey: "x"),
                                          .init(id: "b", captureDate: d1, bodyKey: "x"),
                                          .init(id: "c", captureDate: d2, bodyKey: "x")], threshold: 1.0)
        XCTAssertEqual(viaExif, [["a", "b"], ["c"]])
    }

    /// Spec §16 "Stacks": two camera bodies interleaved in time produce separate stacks.
    func testInterleavedBodiesStaySeparate() {
        var inputs: [StackBuilder.Input] = []
        for i in 0..<4 {
            inputs.append(.init(id: "A\(i)", captureDate: t(Double(i) * 0.5), bodyKey: "serial:A"))
            inputs.append(.init(id: "B\(i)", captureDate: t(Double(i) * 0.5 + 0.1), bodyKey: "serial:B"))
        }
        let stacks = StackBuilder.build(inputs.shuffled(), threshold: 1.0)
        XCTAssertEqual(stacks, [["A0", "A1", "A2", "A3"], ["B0", "B1", "B2", "B3"]])
    }

    func testUndatedItemsAreSingles() {
        let s = StackBuilder.build([.init(id: "a", captureDate: nil, bodyKey: "x"), .init(id: "b", captureDate: nil, bodyKey: "x")], threshold: 1)
        XCTAssertEqual(s, [["a"], ["b"]])
    }

    func testStackCoverIsFirstPick() {
        XCTAssertEqual(StackBuilder.cover(of: ["a", "b", "c"]) { $0 == "c" || $0 == "b" }, "b")
        XCTAssertEqual(StackBuilder.cover(of: ["a", "b"]) { _ in false }, "a")
    }

    func testFilterCombinesWithAnd() throws {
        let dir = try TestSupport.tempDir()
        TestSupport.makeImage(dir.appendingPathComponent("a.jpg"))
        let files = try XCTUnwrap(TestSupport.items(dir).first)
        var f = FilterState()
        f.flags = [.pick]
        f.rating = 3
        let exif = ExifReader.read(files.primary.url)
        XCTAssertTrue(f.matches(metadata: PhotoMetadata(flag: .pick, rating: 4), exif: exif, files: files))
        XCTAssertFalse(f.matches(metadata: PhotoMetadata(flag: .pick, rating: 2), exif: exif, files: files))
        XCTAssertFalse(f.matches(metadata: PhotoMetadata(flag: .none, rating: 5), exif: exif, files: files))
        f = FilterState()
        f.ratingOperator = .equal
        f.rating = 0
        f.labels = [.none]
        f.cameras = ["Canon EOS R5"]
        f.isoRange = 100...800
        XCTAssertTrue(f.matches(metadata: .empty, exif: exif, files: files))
        XCTAssertFalse(f.matches(metadata: .empty, exif: nil, files: files), "EXIF filters exclude unindexed items")
        f.fileTypes = [.raw]
        XCTAssertFalse(f.matches(metadata: .empty, exif: exif, files: files))
    }
}
