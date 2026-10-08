import SwiftUI
import CullerKit

/// Two (or 3–4) slots side by side with a filmstrip of candidates (spec §6.3).
struct CompareView: View {
    @Bindable var session: FolderSession
    @State private var loaders: [SlotImageLoader] = []
    /// Slot currently under a filmstrip drag.
    @State private var dropTarget: Int?

    var body: some View {
        VStack(spacing: 0) {
            slotsGrid
                .padding(6)
            if session.showFilmstrip {
                CompareToolbar(session: session)
                    .padding(.horizontal, 10)
                FilmstripView(session: session, entries: candidateEntries, revision: candidateRevision,
                              currentID: session.compare.activeItemID,
                              highlighted: Set(session.compare.slots.compactMap { $0 }),
                              compareSlots: session.compare.slots) { id in
                    session.putInActiveSlot(id)
                }
                .padding(4)
                .glassCard(18)
                .padding(10)
            }
        }
        .onAppear { syncLoaders() }
        .onChange(of: session.compare.slots) { syncLoaders() }
        .onChange(of: session.imageRevision) {
            for (i, id) in session.compare.slots.enumerated() where loaders.indices.contains(i) { loaders[i].reload(id.flatMap { session.items[$0] }) }
        }
        .onChange(of: session.compare.syncZoom) { session.viewports.sync = session.compare.syncZoom }
    }

    private var candidateEntries: [DisplayEntry] {
        session.compare.candidates.map { DisplayEntry(itemID: $0, stackID: nil, kind: .single) }
    }

    private var candidateRevision: Int {
        var h = Hasher()
        h.combine(session.compare.candidates)
        h.combine(session.displayRevision)
        return h.finalize()
    }

    @ViewBuilder private var slotsGrid: some View {
        let n = session.compare.slots.count
        if n <= 2 {
            HStack(spacing: 6) { ForEach(0..<n, id: \.self) { slot($0) } }
        } else {
            let rows = [Array(0..<2), Array(2..<n)]
            VStack(spacing: 6) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 6) { ForEach(rows[r], id: \.self) { slot($0) } }
                }
            }
        }
    }

    @ViewBuilder private func slot(_ i: Int) -> some View {
        if loaders.indices.contains(i) {
            let loader = loaders[i]
            let id = session.compare.slots[safe: i] ?? nil
            let active = session.compare.active == i
            ZStack {
                ZoomableImage(image: loader.image, pixelSize: loader.pixelSize, contentID: loader.itemID,
                              isFullResolution: loader.isFullResolution, slot: i, hub: session.viewports,
                              onActivate: { activate(i) },
                              onZoomChange: { loader.setZoomed($0) },
                              contextMenu: { PhotoContextMenu.make(session) },
                              onDropItem: { session.put($0, inSlot: i) },
                              onDragHover: { over in
                                  if over { dropTarget = i } else if dropTarget == i { dropTarget = nil }
                              })
                if id == nil {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus").font(.largeTitle)
                        Text(active ? "Click or drag a photo from the filmstrip" : "Drag a photo here").font(.callout)
                    }
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                }
                ImageStateOverlay(loader: loader)
                if let id, let item = session.items[id] {
                    VStack {
                        HStack {
                            if session.compare.pinBest && i == 0 {
                                Label("Current best", systemImage: "pin.fill").font(.caption.bold())
                                    .padding(.horizontal, 10).padding(.vertical, 5).glassCapsule(tint: Theme.accentStart.opacity(0.35)).foregroundStyle(.white)
                            }
                            Spacer()
                        }
                        Spacer()
                        HStack(alignment: .bottom) {
                            StatusOverlay(session: session, item: item, minimal: session.isFullScreen, showsPosition: false)
                            Spacer()
                            if session.showHistogram, let img = loader.image {
                                HistogramView(image: img).frame(width: 160, height: 80)
                            }
                        }
                    }
                    .padding(8)
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                if dropTarget == i {
                    ZStack {
                        Theme.accent.opacity(0.18)
                        Label(i == 0 ? "Drop to show on the left" : (i == 1 ? "Drop to show on the right" : "Drop to show in slot \(i + 1)"),
                              systemImage: "square.and.arrow.down")
                            .font(.headline)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .glassCapsule()
                    }
                    .allowsHitTesting(false)
                }
            }
            .background(Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(active || dropTarget == i ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.08)),
                                  style: StrokeStyle(lineWidth: active || dropTarget == i ? 3 : 1, dash: dropTarget == i ? [8, 5] : []))
                    .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
            .onTapGesture { activate(i) }
        }
    }

    private func activate(_ i: Int) {
        session.compare.active = i
        if let id = session.compare.activeItemID { session.currentID = id }
    }

    private func syncLoaders() {
        let n = session.compare.slots.count
        while loaders.count < n { loaders.append(SlotImageLoader(pipeline: session.app.pipeline)) }
        if loaders.count > n { loaders.removeLast(loaders.count - n) }
        session.viewports.sync = session.compare.syncZoom
        for (i, id) in session.compare.slots.enumerated() {
            loaders[i].show(id.flatMap { session.items[$0] })
        }
    }
}

struct CompareToolbar: View {
    @Bindable var session: FolderSession

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { controls(compact: false); Spacer(minLength: 8); hint }
            HStack(spacing: 14) { controls(compact: false); Spacer(minLength: 0) }
            HStack(spacing: 10) { controls(compact: true); Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) { slotPicker; stripPicker(compact: true); Spacer(minLength: 0) }
                HStack(spacing: 10) { toggles(compact: true); Spacer(minLength: 0) }
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassCard(16)
    }

    private func controls(compact: Bool) -> some View {
        HStack(spacing: compact ? 10 : 14) {
            slotPicker
            toggles(compact: compact)
            stripPicker(compact: compact)
        }
        .fixedSize()
    }

    private var slotPicker: some View {
        Picker("Slots", selection: Binding(get: { session.compare.slots.count },
                                           set: { session.compare.setSlotCount($0) })) {
            Text("2").tag(2)
            Text("3").tag(3)
            Text("4").tag(4)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Number of slots (⌥2 / ⌥3 / ⌥4)")
    }

    private func toggles(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 14) {
            Toggle(compact ? "Sync" : "Sync zoom & pan  ⌥Z", isOn: $session.compare.syncZoom)
                .help("Hold ⌥ while panning to move only the image under the pointer (⌥Z)")
            Toggle(compact ? "Pin best" : "Pin current best  ⌥P", isOn: $session.compare.pinBest)
                .help("Left slot holds the best; ←/→ cycles the right slot; Return promotes it (⌥P)")
        }
        .fixedSize()
    }

    private func stripPicker(compact: Bool) -> some View {
        Picker("", selection: Binding(get: { session.compare.stripShowsAll }, set: { session.setCompareStripShowsAll($0) })) {
            Text(compact ? "Candidates" : (session.compare.baseCandidates.count > 1 ? "Candidates (\(session.compare.baseCandidates.count))" : "Candidates")).tag(false)
            Text(compact ? "All" : "All Photos").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("What the filmstrip shows (⌥A)")
    }

    private var hint: some View {
        Text("Drag from the filmstrip onto a slot · Tab: switch slot · ←/→: change photo · Z: 100%")
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}
