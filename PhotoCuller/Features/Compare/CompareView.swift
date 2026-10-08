import SwiftUI
import CullerKit

/// Two (or 3–4) slots side by side with a filmstrip of candidates (spec §6.3).
struct CompareView: View {
    @Bindable var session: FolderSession
    @State private var loaders: [SlotImageLoader] = []

    var body: some View {
        VStack(spacing: 0) {
            slotsGrid
                .background(Color(white: 0.08))
            if !session.isFullScreen {
                CompareToolbar(session: session)
                Divider()
                FilmstripView(session: session, entries: candidateEntries, revision: candidateRevision,
                              currentID: session.compare.activeItemID,
                              highlighted: Set(session.compare.slots.compactMap { $0 }),
                              compareSlots: session.compare.slots) { id in
                    session.putInActiveSlot(id)
                }
            }
        }
        .onAppear { syncLoaders() }
        .onChange(of: session.compare.slots) { syncLoaders() }
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
            HStack(spacing: 2) { ForEach(0..<n, id: \.self) { slot($0) } }
        } else {
            let rows = [Array(0..<2), Array(2..<n)]
            VStack(spacing: 2) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 2) { ForEach(rows[r], id: \.self) { slot($0) } }
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
                              onZoomChange: { loader.setZoomed($0) })
                if id == nil {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus").font(.largeTitle)
                        Text(active ? "Click a photo in the filmstrip" : "Empty slot").font(.callout)
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
                                    .padding(5).background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.white)
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
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(active ? Color.accentColor : Color.clear, lineWidth: 3)
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
        HStack(spacing: 14) {
            Picker("Slots", selection: Binding(get: { session.compare.slots.count },
                                               set: { session.compare.setSlotCount($0) })) {
                Text("2").tag(2)
                Text("3").tag(3)
                Text("4").tag(4)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            Toggle("Sync zoom & pan", isOn: $session.compare.syncZoom)
                .help("Hold ⌥ while panning to move only the image under the pointer")
            Toggle("Pin current best", isOn: $session.compare.pinBest)
                .help("Left slot holds the best; ←/→ cycles the right slot; Return promotes it")
            Spacer()
            Text("Tab: switch slot · ←/→: change photo in active slot · Z: 100%")
                .font(.caption).foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
