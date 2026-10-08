import SwiftUI
import CullerKit

struct LoupeView: View {
    @Bindable var session: FolderSession
    @State private var loader: SlotImageLoader

    init(session: FolderSession) {
        self.session = session
        _loader = State(initialValue: SlotImageLoader(pipeline: session.app.pipeline))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ZoomableImage(image: loader.image, pixelSize: loader.pixelSize, contentID: loader.itemID,
                              isFullResolution: loader.isFullResolution, slot: 0, hub: session.viewports,
                              onZoomChange: { loader.setZoomed($0) },
                              contextMenu: { PhotoContextMenu.make(session) },
                              onDropItem: { session.select($0) })
                ImageStateOverlay(loader: loader)
                if let item = session.currentItem {
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom) {
                            StatusOverlay(session: session, item: item, minimal: session.isFullScreen)
                            Spacer()
                            if session.showHistogram, let img = loader.image {
                                HistogramView(image: img).frame(width: 220, height: 110)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            if session.showFilmstrip {
                FilmstripView(session: session, entries: session.display, revision: session.displayRevision,
                              currentID: session.currentID, highlighted: Set([session.currentID].compactMap { $0 })) { id in
                    session.select(id)
                }
                .padding(4)
                .glassCard(18)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .onAppear { show() }
        .onChange(of: session.currentID) { show() }
        .onChange(of: session.currentItem?.files) { show() }
    }

    private func show() {
        loader.show(session.currentItem)
        prefetch()
    }

    /// Next 3 + previous 1 in the direction of travel; everything else is cancelled (spec §10).
    private func prefetch() {
        guard let i = session.currentIndex else { return }
        let d = session.lastDirection
        let offsets = [0, d, 2 * d, 3 * d, -d]
        let files = offsets.compactMap { o -> FileRef? in
            let j = i + o
            guard session.display.indices.contains(j) else { return nil }
            return session.items[session.display[j].itemID]?.files.primary
        }
        session.app.pipeline.prefetchPreviews(files, maxPixel: SlotImageLoader.previewPixelSize)
    }
}

/// Loading / unsupported placeholder on top of an image slot.
struct ImageStateOverlay: View {
    let loader: SlotImageLoader

    var body: some View {
        if loader.failed {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text("Unsupported or damaged image").font(.headline)
                Text("This RAW format may need a newer version of macOS.").font(.caption).foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
        } else if loader.image == nil && loader.itemID != nil {
            ProgressView().controlSize(.small)
        } else if loader.isLoadingFull {
            VStack {
                HStack {
                    Spacer()
                    Label("Loading full resolution…", systemImage: "circle.dotted")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassCapsule()
                        .foregroundStyle(.white)
                }
                Spacer()
            }
            .padding(10)
        }
    }
}
