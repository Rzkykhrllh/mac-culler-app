import Foundation
import Vision
import CullerKit

// Read-only prototype: Vision feature prints on 360 px thumbnails, then consecutive-frame grouping.
// Usage: culler-similar <folder> [--count N] [--show threshold]

final class Store: @unchecked Sendable {
    let lock = NSLock()
    var prints: [VNFeaturePrintObservation?]
    var times: [Double]
    init(_ n: Int) { prints = Array(repeating: nil, count: n); times = Array(repeating: 0, count: n) }
}

func run() throws {
let args = CommandLine.arguments
let folder = URL(fileURLWithPath: args[1], isDirectory: true)
let count = args.firstIndex(of: "--count").flatMap { Int(args[$0 + 1]) } ?? 240

let listing = try FolderScanner.list(folder: folder, includeSubfolders: false)
// RAW embedded previews are the fast thumbnail source for pairs (same look as the camera JPEG).
var files = listing.images.filter { $0.kind.isRaw }.sorted { $0.fileName < $1.fileName }
if files.isEmpty { files = listing.images.sorted { $0.fileName < $1.fileName } }
files = Array(files.prefix(count))
let exifs = files.map { ExifReader.read($0.url) }
// Order by capture time like the app does.
let order = files.indices.sorted { (exifs[$0]?.captureDate ?? .distantPast) < (exifs[$1]?.captureDate ?? .distantPast) }

let store = Store(files.count)
let t0 = Date()
let work = files
DispatchQueue.concurrentPerform(iterations: work.count) { i in
    let s = Date()
    guard let thumb = ImageDecoder.thumbnail(for: work[i], maxPixel: 360, raw: .embedded) else { return }
    let req = VNGenerateImageFeaturePrintRequest()
    try? VNImageRequestHandler(cgImage: thumb).perform([req])
    let o = req.results?.first
    store.lock.withLock { store.prints[i] = o; store.times[i] = Date().timeIntervalSince(s) * 1000 }
}
let prints = store.prints, times = store.times
let wall = Date().timeIntervalSince(t0)
let ok = prints.compactMap { $0 }.count
let st = times.filter { $0 > 0 }.sorted()
print(String(format: "feature prints: %d photos in %.1f s (%.0f/s), median %.0f ms each (incl. thumbnail)", ok, wall, Double(ok) / wall, st[st.count / 2]))

func dist(_ a: Int, _ b: Int) -> Float {
    guard let x = prints[a], let y = prints[b] else { return .infinity }
    var d: Float = 0
    try? x.computeDistance(&d, to: y)
    return d
}
var consecutive: [Float] = []
for k in 1..<order.count { consecutive.append(dist(order[k - 1], order[k])) }
let fin = consecutive.filter(\.isFinite).sorted()
let q = { (p: Double) in fin[Int(Double(fin.count - 1) * p)] }
print(String(format: "distance between consecutive photos: p10 %.2f · p25 %.2f · median %.2f · p75 %.2f · p90 %.2f", q(0.1), q(0.25), q(0.5), q(0.75), q(0.9)))

let timeStacks = StackBuilder.build(order.map { StackBuilder.Input(id: String($0), captureDate: exifs[$0]?.captureDate, bodyKey: exifs[$0]?.bodyKey ?? "") }, threshold: 1.0)
print("time stacks (≤1 s): \(timeStacks.filter { $0.count > 1 }.count) stacks of ≥2 covering \(timeStacks.filter { $0.count > 1 }.reduce(0) { $0 + $1.count }) photos")

func groups(_ t: Float) -> [[Int]] {
    var g: [[Int]] = [[order[0]]]
    for k in 1..<order.count { if consecutive[k - 1] <= t { g[g.count - 1].append(order[k]) } else { g.append([order[k]]) } }
    return g
}
for t: Float in [0.3, 0.4, 0.5, 0.6, 0.7] {
    let m = groups(t).filter { $0.count > 1 }
    print(String(format: "threshold %.2f → %3d similar groups covering %3d photos · largest %@", t, m.count, m.reduce(0) { $0 + $1.count },
                 m.map(\.count).sorted(by: >).prefix(6).map(String.init).joined(separator: ",")))
}
let show: Float = args.firstIndex(of: "--show").flatMap { Float(args[$0 + 1]) } ?? 0.5
print("\ngroups at \(show) (file: seconds after previous, distance):")
for grp in groups(show).filter({ $0.count > 1 }).prefix(25) {
    var parts: [String] = []
    for (k, i) in grp.enumerated() {
        let name = files[i].url.deletingPathExtension().lastPathComponent
        if k == 0 { parts.append(name); continue }
        let gap = (exifs[i]?.captureDate).flatMap { d in exifs[grp[k - 1]]?.captureDate.map { d.timeIntervalSince($0) } } ?? .nan
        parts.append(String(format: "%@ +%.0fs d%.2f", name, gap, dist(grp[k - 1], i)))
    }
    print("  • " + parts.joined(separator: "  "))
}

}

try run()
