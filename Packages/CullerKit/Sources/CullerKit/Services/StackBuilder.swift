import Foundation

/// Groups items into burst stacks (spec §4.4).
public enum StackBuilder {
    public struct Input: Sendable {
        public var id: String
        public var captureDate: Date?
        public var bodyKey: String
        public init(id: String, captureDate: Date?, bodyKey: String) {
            self.id = id
            self.captureDate = captureDate
            self.bodyKey = bodyKey
        }
    }

    /// Returns groups of item IDs. Every input appears in exactly one group; members are in capture-time order.
    /// Items are grouped per camera body first so two bodies shooting simultaneously never mix, then consecutive
    /// frames whose gap is ≤ `threshold` are joined. Items without a capture date are always single.
    /// Groups are returned ordered by their first member's capture time.
    public static func build(_ inputs: [Input], threshold: TimeInterval) -> [[String]] {
        // Tolerance so that a gap of exactly `threshold` (e.g. 1.000 s from sub-second fields) counts as inside.
        let limit = threshold + 1e-6
        var groups: [(start: Date, ids: [String])] = []

        let dated = inputs.filter { $0.captureDate != nil }
        let byBody = Dictionary(grouping: dated, by: \.bodyKey)
        for (_, frames) in byBody {
            let sorted = frames.sorted { ($0.captureDate!, $0.id) < ($1.captureDate!, $1.id) }
            var current: [Input] = []
            for f in sorted {
                if let last = current.last, f.captureDate!.timeIntervalSince(last.captureDate!) <= limit {
                    current.append(f)
                } else {
                    if !current.isEmpty { groups.append((current[0].captureDate!, current.map(\.id))) }
                    current = [f]
                }
            }
            if !current.isEmpty { groups.append((current[0].captureDate!, current.map(\.id))) }
        }
        groups.sort { ($0.start, $0.ids[0]) < ($1.start, $1.ids[0]) }
        return groups.map(\.ids) + inputs.filter { $0.captureDate == nil }.map { [$0.id] }
    }

    /// Stack cover: the first pick if any member is picked, else the first member (spec §4.4).
    public static func cover(of members: [String], isPick: (String) -> Bool) -> String {
        members.first(where: isPick) ?? members[0]
    }
}
