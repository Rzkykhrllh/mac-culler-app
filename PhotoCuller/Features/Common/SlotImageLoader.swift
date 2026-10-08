import AppKit
import Observation
import CullerKit

/// Loads the fastest available representation for one image slot: cached thumbnail → screen preview →
/// full resolution (only while zoomed). Never blocks the main thread (spec §3, §10).
@Observable
final class SlotImageLoader {
    private(set) var itemID: ItemID?
    private(set) var image: CGImage? {
        didSet { if image !== oldValue { refreshOverlays() } }
    }
    private(set) var pixelSize: CGSize = CGSize(width: 1, height: 1)
    private(set) var isFullResolution = false
    private(set) var isLoadingFull = false
    private(set) var failed = false
    /// Milliseconds from request to the first preview being shown (debug overlay).
    private(set) var lastShowMs: Double = 0
    /// Focus-peaking / clipping overlays for the image currently shown (nil while off).
    private(set) var peaking: CGImage?
    private(set) var clipping: CGImage?
    @ObservationIgnored private var wantPeaking = false
    @ObservationIgnored private var wantClipping = false
    @ObservationIgnored private var overlayTask: Task<Void, Never>?
    @ObservationIgnored private var overlaySource: CGImage?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var fullTask: Task<Void, Never>?
    @ObservationIgnored private var files: ItemFiles?
    @ObservationIgnored private var wantsFull = false
    @ObservationIgnored private var pixelSizeKnown = false
    @ObservationIgnored private let pipeline: ImagePipeline

    init(pipeline: ImagePipeline) {
        self.pipeline = pipeline
    }

    static var previewPixelSize: Int {
        let s = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 2560
        return Int(min(4096, max(1600, s)))
    }

    /// Re-requests the current photo (cached representations under the old RAW look are not reused).
    func reload(_ item: PhotoItem?) {
        files = nil
        itemID = nil
        image = nil
        show(item)
    }

    func show(_ item: PhotoItem?) {
        guard let item else {
            task?.cancel(); fullTask?.cancel()
            itemID = nil; image = nil; files = nil; failed = false
            return
        }
        if item.id == itemID, item.files == files { return }
        let sameItem = item.id == itemID
        itemID = item.id
        files = item.files
        task?.cancel()
        fullTask?.cancel()
        isLoadingFull = false
        if !sameItem { isFullResolution = false; failed = false }

        let files = item.files
        let px = Self.previewPixelSize
        let t0 = DispatchTime.now()
        // Size of the full-resolution representation so the preview occupies the same frame.
        if !sameItem { pixelSizeKnown = false }
        if !pixelSizeKnown, let s = item.exif?.orientedSize, s.width > 0 {
            pixelSize = CGSize(width: s.width, height: s.height)
            pixelSizeKnown = true
        }

        // Whatever is in memory right now, in the same frame.
        if let p = pipeline.cachedPreview(files.primary, maxPixel: px) {
            setImage(p, full: false, t0: t0)
        } else if let t = pipeline.cachedThumbnail(for: files)?.image {
            setImage(t, full: false, t0: nil)
        } else if !sameItem {
            image = nil
        }

        let pipeline = pipeline
        task = Task { [weak self] in
            async let size = Task.detached(priority: .userInitiated) { ImageDecoder.orientedPixelSize(of: files.fullResolutionSource.url) }.value
            if self?.image == nil, let t = await pipeline.thumbnail(for: files, priority: .veryHigh), !Task.isCancelled {
                if self?.image == nil { self?.setImage(t, full: false, t0: nil) }
            }
            let preview = await pipeline.preview(files.primary, maxPixel: px, priority: .veryHigh)
            let s = await size
            guard !Task.isCancelled, let self else { return }
            if let s { self.pixelSize = s; self.pixelSizeKnown = true }
            if let preview {
                if !self.isFullResolution { self.setImage(preview, full: false, t0: t0) }
            } else if self.image == nil {
                self.failed = true
            }
            if self.wantsFull { self.loadFull() }
        }
    }

    /// Turns the overlays on/off; they follow the shown image (preview → full resolution).
    func setOverlays(peaking p: Bool, clipping c: Bool) {
        guard p != wantPeaking || c != wantClipping else { return }
        wantPeaking = p
        wantClipping = c
        overlaySource = nil
        refreshOverlays()
    }

    private func refreshOverlays() {
        guard let img = image, wantPeaking || wantClipping else {
            overlayTask?.cancel()
            peaking = nil
            clipping = nil
            overlaySource = nil
            return
        }
        guard overlaySource !== img else { return }
        overlaySource = img
        overlayTask?.cancel()
        let p = wantPeaking, c = wantClipping
        overlayTask = Task { [weak self] in
            let (pk, cl) = await Offload.run {
                (p ? FocusOverlays.peaking(img) : nil, c ? FocusOverlays.clipping(img) : nil)
            }
            guard let self, !Task.isCancelled, self.image === img else { return }
            self.peaking = pk
            self.clipping = cl
        }
    }

    private func setImage(_ img: CGImage, full: Bool, t0: DispatchTime?) {
        image = img
        isFullResolution = full
        if !pixelSizeKnown { pixelSize = CGSize(width: img.width, height: img.height) }
        if let t0 { lastShowMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6 }
    }

    /// Called when the view zooms in/out: 100% needs the full-resolution decode.
    func setZoomed(_ zoomed: Bool) {
        wantsFull = zoomed
        if zoomed { loadFull() }
    }

    private func loadFull() {
        guard !isFullResolution, fullTask == nil || isLoadingFull == false, let files else { return }
        let id = itemID
        if let f = pipeline.cachedFullResolution(files.fullResolutionSource) {
            setImage(f, full: true, t0: nil)
            return
        }
        isLoadingFull = true
        let pipeline = pipeline
        fullTask = Task { [weak self] in
            let img = await pipeline.fullResolution(files.fullResolutionSource)
            guard let self, !Task.isCancelled, self.itemID == id else { return }
            self.isLoadingFull = false
            if let img {
                self.pixelSize = CGSize(width: img.width, height: img.height)
                self.pixelSizeKnown = true
                self.setImage(img, full: true, t0: nil)
            }
        }
    }
}
