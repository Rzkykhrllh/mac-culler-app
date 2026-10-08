import Foundation
import ImageIO
import CoreImage
import Vision
import CullerKit

// Read-only benchmark: never writes into the folder (no sidecar recovery, caches go to a temp dir).
// Usage: culler-bench <folder> [--sample N]

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: culler-bench <folder> [--sample N]"); exit(1) }
let folder = URL(fileURLWithPath: args[1], isDirectory: true)
let sample = args.firstIndex(of: "--sample").flatMap { Int(args[$0 + 1]) } ?? 120
let cores = ProcessInfo.processInfo.activeProcessorCount

@Sendable func ms(_ start: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6 }
func time<T>(_ f: () throws -> T) rethrows -> (T, Double) { let t = DispatchTime.now(); let v = try f(); return (v, ms(t)) }
func fmt(_ v: Double) -> String { v >= 10_000 ? String(format: "%.1f s", v / 1000) : String(format: "%.0f ms", v) }
func line(_ s: String) { print(s); fflush(stdout) }

/// Runs `work` over items with bounded concurrency; returns wall time and per-item times.
func parallel<T: Sendable>(_ items: [T], width: Int = cores, _ work: @escaping @Sendable (T) -> Void) async -> (wall: Double, each: [Double]) {
    let t0 = DispatchTime.now()
    let each = await withTaskGroup(of: Double.self) { g in
        var it = items.makeIterator()
        var out: [Double] = []
        for _ in 0..<min(width, items.count) {
            if let x = it.next() { g.addTask { let t = DispatchTime.now(); work(x); return ms(t) } }
        }
        while let d = await g.next() {
            out.append(d)
            if let x = it.next() { g.addTask { let t = DispatchTime.now(); work(x); return ms(t) } }
        }
        return out
    }
    return (ms(t0), each)
}

func stats(_ v: [Double]) -> String {
    guard !v.isEmpty else { return "-" }
    let s = v.sorted()
    let p = { (q: Double) in s[min(s.count - 1, Int(Double(s.count - 1) * q))] }
    return "median \(fmt(p(0.5))) · p90 \(fmt(p(0.9))) · max \(fmt(s.last!))"
}

line("PhotoCuller benchmark — \(folder.lastPathComponent) — \(cores) cores")

// 1. Folder open like the app: scan, start the RAW warm-up, request every thumbnail through the pipeline.
let listing = try FolderScanner.list(folder: folder, includeSubfolders: false)
let raws = listing.images.filter { $0.kind.isRaw }.sorted { $0.fileName < $1.fileName }
let jpgs = listing.images.filter { $0.kind == .jpeg }.sorted { $0.fileName < $1.fileName }

func openFolder(label: String, pair: Bool, rendering: RawRendering, warm: Bool) async {
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent("culler-bench-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: cache) }
    let pipeline = ImagePipeline(diskCache: try? ThumbnailDiskCache(directory: cache, limitBytes: 1 << 34))
    pipeline.rawRendering = rendering
    let t0 = DispatchTime.now()
    let items = try! FolderScanner.scan(folder: folder, options: ScanOptions(pairRawWithRaster: pair))
        .filter { pair || $0.primary.kind.isRaw }
        .sorted { $0.primary.fileName < $1.primary.fileName }
    if warm, let r = items.lazy.compactMap(\.raw).first { ImagePipeline.warmUpRaw(with: r) }
    final class Times: @unchecked Sendable { let lock = NSLock(); var firstPartial: [Double] = []; var final: [Double] = [] }
    let times = Times()
    await withTaskGroup(of: Void.self) { g in
        for (i, item) in items.enumerated() {
            g.addTask {
                let img = await pipeline.thumbnail(for: item, priority: i < 30 ? .high : .low) { _ in
                    times.lock.withLock { if i < 30 { times.firstPartial.append(ms(t0)) } }
                }
                if img != nil { times.lock.withLock { times.final.append(ms(t0)) } }
            }
        }
    }
    let f = times.final.sorted()
    let firstScreen = f.count >= 30 ? f[29] : f.last ?? 0
    let partial = times.firstPartial.sorted()
    line("[open \(label)] \(items.count) photos · placeholders for first screen \(partial.isEmpty ? "-" : fmt(partial[min(29, partial.count - 1)])) · first 30 sharp \(fmt(firstScreen)) · all \(f.count) sharp \(fmt(f.last ?? 0))")
}

// Measured in a fresh process each time the RAW engine is cold only for the first run.
await openFolder(label: "RAW+JPG pair", pair: true, rendering: .rendered, warm: true)
await openFolder(label: "RAW only · True RAW", pair: false, rendering: .rendered, warm: true)
await openFolder(label: "RAW only · camera preview", pair: false, rendering: .embedded, warm: true)

// 2. Folder open: scan + group.
let (items, scanMs) = try time { try FolderScanner.scan(folder: folder, options: ScanOptions()) }
line("\n[scan] \(listing.images.count) files → \(items.count) items (paired) in \(fmt(scanMs))   target: grid visible < 1 s")

// 3. Index: EXIF + XMP for every item (what happens once per folder; later served from the SQLite index).
let idx = await parallel(items) { item in
    _ = ExifReader.read(item.primary.url)
    _ = MetadataStore.read(item, recover: false)
}
line("[index] EXIF+XMP for \(items.count) items: \(fmt(idx.wall)) wall (\(stats(idx.each)) per item)")

// 4. Thumbnails (400 px) on a sample, extrapolated to the folder.
let rs = Array(raws.prefix(sample)), js = Array(jpgs.prefix(sample))
let tj = await parallel(js) { _ = ImageDecoder.thumbnail(for: $0, maxPixel: 400) }
let te = await parallel(rs) { _ = ImageDecoder.thumbnail(for: $0, maxPixel: 400, raw: .embedded) }
let tr = await parallel(rs) { _ = ImageDecoder.thumbnail(for: $0, maxPixel: 400, raw: .rendered) }
func rate(_ r: (wall: Double, each: [Double]), _ n: Int, total: Int) -> String {
    let perSec = Double(n) / (r.wall / 1000)
    return String(format: "%.0f/s → all %d in %@", perSec, total, fmt(Double(total) / perSec * 1000))
}
line("\n[thumbs JPG]          \(stats(tj.each)) · \(rate(tj, js.count, total: jpgs.count))")
line("[thumbs RAW embedded] \(stats(te.each)) · \(rate(te, rs.count, total: raws.count))")
line("[thumbs RAW rendered] \(stats(tr.each)) · \(rate(tr, rs.count, total: raws.count))")

// 5. Screen previews (2560 px), sequential like stepping through the loupe.
let n5 = min(15, rs.count)
var pe: [Double] = [], pr: [Double] = [], pj: [Double] = []
for i in 0..<n5 {
    pe.append(time { ImageDecoder.preview(for: rs[i], maxPixel: 2560, raw: .embedded) }.1)
    pr.append(time { ImageDecoder.preview(for: rs[i], maxPixel: 2560, raw: .rendered) }.1)
    if i < js.count { pj.append(time { ImageDecoder.preview(for: js[i], maxPixel: 2560) }.1) }
}
line("\n[preview JPG 2560]          \(stats(pj))   target: < 150 ms not prefetched")
line("[preview RAW embedded 2560] \(stats(pe))")
line("[preview RAW rendered 2560] \(stats(pr))")

// 6. Full resolution (100% zoom).
var fr: [Double] = [], fj: [Double] = []
for i in 0..<min(4, rs.count) {
    fr.append(time { () -> Int in let img = ImageDecoder.fullResolution(for: rs[i]); return img?.width ?? 0 }.1)
    fj.append(time { () -> Int in let img = ImageDecoder.fullResolution(for: js[i]); return img?.width ?? 0 }.1)
}
line("\n[full RAW] \(stats(fr))   target: < 1 s")
line("[full JPG] \(stats(fj))")

// 7. Similar-photo grouping: see `culler-similar` (Vision must run off Swift concurrency's main actor in a CLI).
