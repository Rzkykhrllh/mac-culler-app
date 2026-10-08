import Foundation
import Vision
import CoreGraphics

/// Visual "fingerprints" (Vision feature prints) used to group similar photos (spec v2: grouping by visual similarity).
/// Runs fully on-device.
public enum FeaturePrints {
    /// Computes a feature print from a small image (a ~400 px thumbnail is plenty). Returns it archived.
    public static func compute(from image: CGImage) -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    public static func observation(from data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    /// Vision's distance between two prints (0 = identical; ~0.1–0.3 for frames of the same scene,
    /// ~1 and above for unrelated photos). `infinity` when they cannot be compared.
    public static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
        var d: Float = 0
        do { try a.computeDistance(&d, to: b) } catch { return .infinity }
        return d
    }
}

/// Groups photos whose consecutive frames look alike. Distances are computed once (`prepare`);
/// regrouping for another threshold (slider) is then instant (`groups`).
public enum SimilarityGrouper {
    public struct Input: @unchecked Sendable {
        public var id: String
        public var captureDate: Date?
        /// Photos from different camera bodies (or file types) are never grouped.
        public var groupKey: String
        public var print: VNFeaturePrintObservation?
        public init(id: String, captureDate: Date?, groupKey: String, print: VNFeaturePrintObservation?) {
            self.id = id
            self.captureDate = captureDate
            self.groupKey = groupKey
            self.print = print
        }
    }

    /// Per camera body (/ file type): ids in capture order + distance / time gap to the previous frame.
    public struct Prepared: Sendable {
        struct Run: Sendable {
            var ids: [String]
            var start: Date
            /// distances[i] = distance between ids[i] and ids[i+1]
            var distances: [Float]
            var gaps: [TimeInterval]
        }
        var runs: [Run]
        /// Photos without a capture date or a feature print: always single.
        var singles: [String]
    }

    public static func prepare(_ inputs: [Input]) -> Prepared {
        let usable = inputs.filter { $0.captureDate != nil && $0.print != nil }
        let used = Set(usable.map(\.id))
        var runs: [Prepared.Run] = []
        for (_, frames) in Dictionary(grouping: usable, by: \.groupKey) {
            let sorted = frames.sorted { ($0.captureDate!, $0.id) < ($1.captureDate!, $1.id) }
            var distances: [Float] = []
            var gaps: [TimeInterval] = []
            for i in 1..<max(1, sorted.count) {
                distances.append(FeaturePrints.distance(sorted[i - 1].print!, sorted[i].print!))
                gaps.append(sorted[i].captureDate!.timeIntervalSince(sorted[i - 1].captureDate!))
            }
            runs.append(.init(ids: sorted.map(\.id), start: sorted[0].captureDate!, distances: distances, gaps: gaps))
        }
        runs.sort { $0.start < $1.start }
        return Prepared(runs: runs, singles: inputs.map(\.id).filter { !used.contains($0) })
    }

    /// Consecutive frames join a group when they look alike (distance ≤ threshold) and were taken within
    /// `maxGap` of each other. Groups are ordered by capture time; every input appears exactly once.
    public static func groups(_ p: Prepared, threshold: Float, maxGap: TimeInterval = 600) -> [[String]] {
        var out: [(Date, [String])] = []
        for run in p.runs {
            guard let first = run.ids.first else { continue }
            var current = [first]
            for i in 1..<max(1, run.ids.count) where run.ids.count > 1 {
                if run.distances[i - 1] <= threshold && run.gaps[i - 1] <= maxGap {
                    current.append(run.ids[i])
                } else {
                    out.append((run.start, current))
                    current = [run.ids[i]]
                }
            }
            out.append((run.start, current))
        }
        return out.map(\.1) + p.singles.map { [$0] }
    }
}
