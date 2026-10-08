import Foundation

/// Background, serialized, debounced metadata writer (spec §5.3.4–5).
/// Rapid changes to the same item are coalesced; only the latest value is written.
public actor MetadataWriteQueue {
    public enum Event: Sendable {
        case written(itemID: String, files: ItemFiles, metadata: PhotoMetadata)
        case failed(itemID: String, metadata: PhotoMetadata, error: String)
    }

    struct Pending {
        var files: ItemFiles
        var metadata: PhotoMetadata
        var generation: Int
    }

    private var pending: [String: Pending] = [:]
    private var generation = 0
    private let debounce: Duration
    private var options: MetadataStore.WriteOptions
    private let onEvent: @Sendable (Event) -> Void

    public init(debounce: Duration = .milliseconds(300), options: MetadataStore.WriteOptions = .init(),
                onEvent: @escaping @Sendable (Event) -> Void) {
        self.debounce = debounce
        self.options = options
        self.onEvent = onEvent
    }

    public func setOptions(_ o: MetadataStore.WriteOptions) { options = o }

    public var pendingCount: Int { pending.count }

    /// Schedules a write of `metadata` for the item. Supersedes any not-yet-written value for the same item.
    public func enqueue(itemID: String, files: ItemFiles, metadata: PhotoMetadata) {
        generation += 1
        let gen = generation
        pending[itemID] = Pending(files: files, metadata: metadata, generation: gen)
        Task { [debounce] in
            try? await Task.sleep(for: debounce)
            self.fire(itemID: itemID, generation: gen)
        }
    }

    /// Updates the file set of a pending write (e.g. after a rename) so it lands on the right files.
    public func retarget(itemID: String, to newID: String, files: ItemFiles) {
        guard var p = pending.removeValue(forKey: itemID) else { return }
        p.files = files
        pending[newID] = p
    }

    private func fire(itemID: String, generation gen: Int) {
        guard let p = pending[itemID], p.generation == gen else { return }
        pending[itemID] = nil
        perform(itemID: itemID, p)
    }

    private func perform(itemID: String, _ p: Pending) {
        do {
            let files = try MetadataStore.write(p.metadata, to: p.files, options: options)
            onEvent(.written(itemID: itemID, files: files, metadata: p.metadata))
        } catch {
            onEvent(.failed(itemID: itemID, metadata: p.metadata, error: error.localizedDescription))
        }
    }

    /// Writes everything that is pending right now (app quit / folder close).
    public func flush() {
        let all = pending
        pending.removeAll()
        for (id, p) in all.sorted(by: { $0.value.generation < $1.value.generation }) {
            perform(itemID: id, p)
        }
    }
}
