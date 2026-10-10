import AppKit
import SwiftUI

/// Zoom / pan state in resolution-independent terms, so images of different sizes align (spec §6.3).
struct Viewport: Equatable {
    /// Visible center, normalized to the image (0…1, origin top-left).
    var center: CGPoint
    /// Magnification relative to 100% (1.0 = one image pixel per screen pixel).
    var zoom: CGFloat
    var isFit: Bool

    static let fit = Viewport(center: CGPoint(x: 0.5, y: 0.5), zoom: 0, isFit: true)
}

/// Keeps the zoomable views of the loupe / compare slots together and synchronizes them.
@Observable
final class ViewportHub {
    private final class Weak { weak var view: ZoomScrollView?; init(_ v: ZoomScrollView) { view = v } }
    @ObservationIgnored private var views: [Int: Weak] = [:]
    /// Current zoom in percent of 100% (nil while fit), for the on-image Fit button.
    private(set) var zoomPercent: Int?
    /// Per-slot offset from the shared center, built up by ⌥-dragging (temporary independent pan).
    @ObservationIgnored private var offsets: [Int: CGPoint] = [:]
    @ObservationIgnored private var applying = false
    var sync = true
    /// Last viewport, re-applied when the image in a slot changes so zoom/position persist while culling a burst.
    @ObservationIgnored private(set) var lastViewport: Viewport = .fit {
        didSet {
            let p: Int? = lastViewport.isFit ? nil : Int((lastViewport.zoom * 100).rounded())
            if p != zoomPercent { zoomPercent = p }
        }
    }

    func register(_ v: ZoomScrollView, slot: Int) {
        views[slot] = Weak(v)
        v.slot = slot
        v.hub = self
    }

    func unregister(slot: Int, view: ZoomScrollView) {
        if views[slot]?.view === view { views[slot] = nil }
    }

    func view(slot: Int) -> ZoomScrollView? { views[slot]?.view }

    func toggleZoom(slot: Int) {
        view(slot: slot)?.toggleZoomAtPointer()
    }

    func resetOffsets() { offsets.removeAll() }

    /// ⌘0 / the Fit button: every slot back to the whole photo, and new photos open fit too.
    func fitAll() {
        offsets.removeAll()
        lastViewport = .fit
        applying = true
        for (_, w) in views { w.view?.apply(.fit) }
        applying = false
    }

    /// Zooms every given slot to its own point (e.g. each photo's eyes). Offsets are set so synced panning
    /// afterwards keeps each slot on its subject.
    func focus(on centers: [Int: CGPoint], active: Int, zoom: CGFloat) {
        guard let anchor = centers[active] ?? centers.values.first else { return }
        lastViewport = Viewport(center: anchor, zoom: zoom, isFit: false)
        applying = true
        for (slot, c) in centers {
            offsets[slot] = CGPoint(x: c.x - anchor.x, y: c.y - anchor.y)
            view(slot: slot)?.apply(Viewport(center: c, zoom: zoom, isFit: false))
        }
        applying = false
    }

    func offset(for slot: Int) -> CGPoint { offsets[slot] ?? .zero }

    /// Called by a view after the user zoomed or panned it.
    func viewportChanged(slot: Int, _ vp: Viewport, independent: Bool) {
        guard !applying else { return }
        if independent && sync {
            // ⌥ held: only this image moves; remember how far it is from the others.
            let shared = CGPoint(x: lastViewport.center.x, y: lastViewport.center.y)
            offsets[slot] = CGPoint(x: vp.center.x - shared.x, y: vp.center.y - shared.y)
            return
        }
        let off = offset(for: slot)
        lastViewport = Viewport(center: CGPoint(x: vp.center.x - off.x, y: vp.center.y - off.y), zoom: vp.zoom, isFit: vp.isFit)
        guard sync else { return }
        applying = true
        for (s, w) in views where s != slot {
            guard let v = w.view else { continue }
            v.apply(shifted(lastViewport, by: offset(for: s)))
        }
        applying = false
    }

    func shifted(_ vp: Viewport, by off: CGPoint) -> Viewport {
        Viewport(center: CGPoint(x: vp.center.x + off.x, y: vp.center.y + off.y), zoom: vp.zoom, isFit: vp.isFit)
    }

    /// Viewport a slot should adopt when it receives a new image.
    func viewportForNewImage(slot: Int) -> Viewport {
        if views.count > 1 && !sync { return .fit }
        return shifted(lastViewport, by: offset(for: slot))
    }
}

/// Clip view that centers a document smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}

/// Layer-backed view showing the image scaled to its frame (frame = image pixel size).
final class ImageCanvasView: NSView {
    var image: CGImage? {
        didSet { layer?.contents = image }
    }
    /// Focus-peaking / clipping overlays, stretched over the image like it.
    private let peakLayer = CALayer(), clipLayer = CALayer()
    var peaking: CGImage? { didSet { peakLayer.contents = peaking } }
    var clipping: CGImage? { didSet { clipLayer.contents = clipping } }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        peakLayer.frame = bounds
        clipLayer.frame = bounds
        CATransaction.commit()
    }
    weak var scrollView: ZoomScrollView?
    private var dragStart: NSPoint?
    private var dragOrigin: NSPoint = .zero
    private var dragged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .nearest
        layerContentsRedrawPolicy = .never
        for l in [clipLayer, peakLayer] {
            l.contentsGravity = .resize
            l.magnificationFilter = .nearest
            l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(l)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        guard let sv = scrollView else { return }
        addCursorRect(visibleRect, cursor: sv.isFit ? .crosshair : .openHand)
    }

    override func menu(for event: NSEvent) -> NSMenu? { scrollView?.menu(for: event) }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        dragOrigin = scrollView?.contentView.bounds.origin ?? .zero
        dragged = false
        scrollView?.onActivate?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let sv = scrollView, !sv.isFit else { return }
        let p = event.locationInWindow
        if !dragged, hypot(p.x - start.x, p.y - start.y) < 3 { return }
        dragged = true
        NSCursor.closedHand.set()
        let m = sv.magnification
        let origin = NSPoint(x: dragOrigin.x - (p.x - start.x) / m, y: dragOrigin.y - (p.y - start.y) / m)
        sv.contentView.scroll(to: sv.contentView.constrainBoundsRect(NSRect(origin: origin, size: sv.contentView.bounds.size)).origin)
        sv.reflectScrolledClipView(sv.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard let sv = scrollView else { return }
        if !dragged {
            // Click toggles between fit and 100% centered on the click (spec §6.2).
            sv.toggleZoom(at: convert(event.locationInWindow, from: nil))
        }
        window?.invalidateCursorRects(for: self)
    }
}

/// Zoomable, pannable image view (fit ↔ 100%, pinch, scroll), reporting its viewport to a `ViewportHub`.
final class ZoomScrollView: NSScrollView {
    let canvas = ImageCanvasView(frame: .zero)
    weak var hub: ViewportHub?
    var slot = 0
    var onActivate: (() -> Void)?
    var onZoomChange: ((Bool) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    /// A photo dragged from a filmstrip was dropped here.
    var onDropItem: ((ItemID) -> Void)?
    var onDragHover: ((Bool) -> Void)?
    private(set) var isFit = true
    private var reporting = true
    private(set) var pixelSize: CGSize = .zero
    private var lastClickPoint: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        documentView = canvas
        canvas.scrollView = self
        allowsMagnification = true
        hasHorizontalScroller = false
        hasVerticalScroller = false
        drawsBackground = false
        backgroundColor = .clear
        usesPredominantAxisScrolling = false
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        registerForDraggedTypes([.string])
    }

    // MARK: Drop target (filmstrip → slot)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onDropItem != nil, DragPayload.itemID(from: sender.draggingPasteboard) != nil else { return [] }
        onDragHover?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDropItem != nil && DragPayload.itemID(from: sender.draggingPasteboard) != nil ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onDragHover?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragHover?(false)
        guard let id = DragPayload.itemID(from: sender.draggingPasteboard), let onDropItem else { return false }
        onDropItem(id)
        return true
    }

    required init?(coder: NSCoder) { fatalError() }

    var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    var oneToOne: CGFloat { 1 / backingScale }

    var fitMagnification: CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return 1 }
        let s = contentView.frame.size
        guard s.width > 0, s.height > 0 else { return 1 }
        return min(s.width / pixelSize.width, s.height / pixelSize.height, 1)
    }

    /// Sets a new image. `pixelSize` is the full-resolution size, so a smaller preview fills the same frame.
    func setImage(_ image: CGImage?, pixelSize: CGSize, viewport: Viewport?) {
        let sizeChanged = pixelSize != self.pixelSize
        canvas.image = image
        guard sizeChanged || viewport != nil else { return }
        let keep = viewport ?? currentViewport
        self.pixelSize = pixelSize
        reporting = false
        canvas.frame = NSRect(origin: .zero, size: pixelSize)
        apply(keep, report: false)
        reporting = true
    }

    /// Swaps in a higher resolution version of the same image without touching zoom or position.
    func upgradeImage(_ image: CGImage) {
        canvas.image = image
    }

    var currentViewport: Viewport {
        guard pixelSize.width > 0 else { return .fit }
        let b = contentView.bounds
        let c = CGPoint(x: b.midX / pixelSize.width, y: 1 - b.midY / pixelSize.height)
        return Viewport(center: c, zoom: magnification / oneToOne, isFit: isFit)
    }

    func apply(_ vp: Viewport, report: Bool = false) {
        let was = reporting
        reporting = report
        defer { reporting = was }
        if vp.isFit || pixelSize.width == 0 {
            setFit()
            return
        }
        let mag = max(fitMagnification, min(vp.zoom * oneToOne, maxMagnification))
        isFit = false
        minMagnification = min(fitMagnification, oneToOne)
        magnification = mag
        center(onNormalized: vp.center)
        onZoomChange?(true)
        window?.invalidateCursorRects(for: canvas)
    }

    func setFit() {
        isFit = true
        minMagnification = min(fitMagnification, oneToOne) * 0.5
        maxMagnification = oneToOne * 8
        magnification = fitMagnification
        center(onNormalized: CGPoint(x: 0.5, y: 0.5))
        onZoomChange?(false)
        window?.invalidateCursorRects(for: canvas)
    }

    func center(onNormalized p: CGPoint) {
        let clip = contentView.bounds.size
        let origin = NSPoint(x: p.x * pixelSize.width - clip.width / 2, y: (1 - p.y) * pixelSize.height - clip.height / 2)
        contentView.scroll(to: contentView.constrainBoundsRect(NSRect(origin: origin, size: clip)).origin)
        reflectScrolledClipView(contentView)
    }

    func toggleZoom(at docPoint: CGPoint) {
        lastClickPoint = docPoint
        if isFit {
            let n = CGPoint(x: docPoint.x / max(1, pixelSize.width), y: 1 - docPoint.y / max(1, pixelSize.height))
            apply(Viewport(center: n, zoom: 1, isFit: false), report: true)
        } else {
            apply(.fit, report: true)
        }
        report(independent: false)
    }

    /// Keyboard zoom toggle: at the mouse pointer if it is over the image, else at the last click, else centered.
    func toggleZoomAtPointer() {
        guard let window else { return }
        let inWindow = window.mouseLocationOutsideOfEventStream
        let inCanvas = canvas.convert(inWindow, from: nil)
        if isFit, canvas.bounds.contains(inCanvas), contentView.convert(inWindow, from: nil).isInside(contentView.bounds) {
            toggleZoom(at: inCanvas)
        } else if isFit, let p = lastClickPoint {
            toggleZoom(at: p)
        } else {
            toggleZoom(at: CGPoint(x: pixelSize.width / 2, y: pixelSize.height / 2))
        }
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        let fit = fitMagnification
        if magnification <= fit * 1.001 {
            if !isFit { setFit() }
        } else if isFit {
            isFit = false
            onZoomChange?(true)
        }
        report(independent: NSEvent.modifierFlags.contains(.option))
    }

    override func layout() {
        super.layout()
        if isFit && pixelSize.width > 0 {
            reporting = false
            setFit()
            reporting = true
        }
    }

    @objc private func boundsChanged() {
        guard reporting else { return }
        report(independent: NSEvent.modifierFlags.contains(.option))
    }

    private func report(independent: Bool) {
        hub?.viewportChanged(slot: slot, currentViewport, independent: independent)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onActivate?()
        return contextMenuProvider?()
    }

    override func scrollWheel(with event: NSEvent) {
        // Trackpad two-finger scrolling pans when zoomed; when fit there is nothing to pan.
        guard !isFit else { return }
        super.scrollWheel(with: event)
    }
}

private extension CGPoint {
    func isInside(_ r: CGRect) -> Bool { r.contains(self) }
}

/// SwiftUI wrapper.
struct ZoomableImage: NSViewRepresentable {
    var image: CGImage?
    /// Full resolution pixel size (oriented).
    var pixelSize: CGSize
    /// Changes whenever a different photo is shown (zoom state is carried over via the hub).
    var contentID: String?
    /// True when `image` is the full-resolution decode of `contentID`.
    var isFullResolution: Bool
    var slot: Int
    var hub: ViewportHub
    var onActivate: () -> Void = {}
    var onZoomChange: (Bool) -> Void = { _ in }
    var contextMenu: () -> NSMenu? = { nil }
    var onDropItem: ((ItemID) -> Void)?
    var onDragHover: (Bool) -> Void = { _ in }
    var peaking: CGImage?
    var clipping: CGImage?

    final class Coordinator {
        var contentID: String?
        var hadImage = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ZoomScrollView {
        let v = ZoomScrollView(frame: .zero)
        hub.register(v, slot: slot)
        return v
    }

    func updateNSView(_ v: ZoomScrollView, context: Context) {
        v.onActivate = onActivate
        v.onZoomChange = onZoomChange
        v.contextMenuProvider = contextMenu
        v.onDropItem = onDropItem
        v.onDragHover = onDragHover
        if v.canvas.peaking !== peaking { v.canvas.peaking = peaking }
        if v.canvas.clipping !== clipping { v.canvas.clipping = clipping }
        if hub.view(slot: slot) !== v { hub.register(v, slot: slot) }
        let c = context.coordinator
        if c.contentID != contentID {
            c.contentID = contentID
            c.hadImage = image != nil
            v.setImage(image, pixelSize: pixelSize, viewport: hub.viewportForNewImage(slot: slot))
        } else if let image {
            if pixelSize != v.pixelSize {
                v.setImage(image, pixelSize: pixelSize, viewport: v.currentViewport)
            } else if isFullResolution || !c.hadImage || v.canvas.image == nil {
                v.upgradeImage(image)
            } else if v.canvas.image !== image {
                v.upgradeImage(image)
            }
            c.hadImage = true
        }
    }

    static func dismantleNSView(_ v: ZoomScrollView, coordinator: Coordinator) {
        v.hub?.unregister(slot: v.slot, view: v)
    }
}
