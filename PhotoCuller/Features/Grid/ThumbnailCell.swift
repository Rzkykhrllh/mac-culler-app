import AppKit
import CullerKit

/// Grid / filmstrip cell: thumbnail + flag, rating, label, note, pair and stack badges (spec §6.1).
final class ThumbnailCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailCell")

    var cellView: ThumbnailCellView { view as! ThumbnailCellView }
    private var loadTask: Task<Void, Never>?
    private(set) var representedID: ItemID?
    private var representedKey: String?
    private var hasFinalImage = false

    override func loadView() {
        view = ThumbnailCellView(frame: .zero)
    }

    override var isSelected: Bool {
        didSet { cellView.isSelectedCell = isSelected }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        representedID = nil
        representedKey = nil
        hasFinalImage = false
        cellView.item = nil
        cellView.image = nil
        cellView.isCurrent = false
        cellView.compareSlot = nil
        cellView.resetHover()
        cellView.partnerName = nil
        cellView.isPartnerHighlighted = false
    }

    func configure(entry: DisplayEntry, item: PhotoItem, pipeline: ImagePipeline, compact: Bool,
                   isCurrent: Bool, compareSlot: Int?) {
        let key = pipeline.thumbnailKey(for: item.files)
        let changed = representedID != item.id || representedKey != key
        representedID = item.id
        representedKey = key
        cellView.entry = entry
        cellView.item = item
        cellView.compact = compact
        cellView.isCurrent = isCurrent
        cellView.compareSlot = compareSlot
        cellView.observeItem()
        guard changed || cellView.image == nil || !hasFinalImage else { return }
        let files = item.files
        if let c = pipeline.cachedThumbnail(for: files) {
            cellView.image = c.image
            hasFinalImage = c.isFinal
            if c.isFinal { return }
        } else {
            cellView.image = nil
            hasFinalImage = false
        }
        loadTask?.cancel()
        let id = item.id
        let weakCell = WeakCell(self)
        loadTask = Task { [weak self] in
            // Progressive: tiny embedded thumbnail / camera preview first, final image after.
            let img = await pipeline.thumbnail(for: files, priority: .high) { partial in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let cell = weakCell.value, cell.representedID == id, !cell.hasFinalImage else { return }
                        cell.cellView.image = partial
                    }
                }
            }
            guard let self, !Task.isCancelled, self.representedID == id else { return }
            if img == nil && self.cellView.image == nil { item.decodeFailed = true }
            if let img {
                self.cellView.image = img
                self.hasFinalImage = true
            }
        }
    }
}

private final class WeakCell: @unchecked Sendable {
    weak var value: ThumbnailCell?
    init(_ c: ThumbnailCell) { value = c }
}

/// Drag & drop payload for photos (filmstrip → compare slot; also drops the file into Finder etc.).
enum DragPayload {
    static let prefix = "photoculler-item:"

    static func pasteboardItem(for item: PhotoItem) -> NSPasteboardItem {
        let pb = NSPasteboardItem()
        pb.setString(prefix + item.id, forType: .string)
        pb.setString(item.files.primary.url.absoluteString, forType: .fileURL)
        return pb
    }

    static func itemID(from pasteboard: NSPasteboard) -> ItemID? {
        guard let s = pasteboard.string(forType: .string), s.hasPrefix(prefix) else { return nil }
        return String(s.dropFirst(prefix.count))
    }
}

final class ThumbnailCellView: NSView, NSDraggingSource, NSViewToolTipOwner {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    var entry: DisplayEntry? { didSet { needsDisplay = true } }
    var item: PhotoItem?
    var image: CGImage? { didSet { needsDisplay = true } }
    var isSelectedCell = false { didSet { if oldValue != isSelectedCell { needsDisplay = true } } }
    var isCurrent = false { didSet { if oldValue != isCurrent { needsDisplay = true } } }
    var compareSlot: Int? { didSet { if oldValue != compareSlot { needsDisplay = true } } }
    var compact = false
    var onDoubleClick: (() -> Void)?
    var onStackBadge: (() -> Void)?
    /// Hover bar actions (pick / reject / rating) — applied to this photo only.
    var onQuickMark: ((MarkCommand) -> Void)?
    /// Separate RAW/JPEG mode: file name of the other half of this shot (nil when not separated).
    var partnerName: String? { didSet { if oldValue != partnerName { needsDisplay = true } } }
    /// The other file of a selected photo (separate mode): drawn with a dashed outline.
    var isPartnerHighlighted = false { didSet { if oldValue != isPartnerHighlighted { needsDisplay = true } } }
    /// Badge rects → explanation, for tooltips.
    private var tips: [(NSRect, String)] = []
    /// Filmstrips handle clicks themselves (click = pick on mouse-up) so a drag never changes the active slot.
    var manualClicks = false
    var onClick: (() -> Void)?
    private var stackBadgeRect: NSRect = .zero
    private var downPoint: NSPoint?
    private var dragStarted = false

    // Hover
    private var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    private var hoverPoint: NSPoint? { didSet { if hoverControl(at: hoverPoint) != hoverControl(at: oldValue) { needsDisplay = true } } }
    private enum Control: Equatable { case pick, reject, star(Int) }
    private var controlRects: [(Control, NSRect)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addToolTip(bounds, owner: self, userData: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: Tooltips

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        if let tip = tips.first(where: { $0.0.contains(point) })?.1 { return tip }
        guard let item else { return "" }
        var lines = [item.fileName]
        if let e = item.exif, e.captureDate != nil { lines.append(ExifFormat.summary(e)) }
        return lines.joined(separator: "\n")
    }

    /// Forget hover when the cell is reused or scrolled away (mouseExited is not always delivered then).
    func resetHover() {
        isHovered = false
        hoverPoint = nil
    }

    private func syncHoverWithPointer() {
        guard let window else { resetHover(); return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let inside = visibleRect.contains(p)
        if inside != isHovered {
            isHovered = inside
            hoverPoint = inside ? p : nil
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
        // Scrolling moves cells under a still pointer without enter/exit events.
        syncHoverWithPointer()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        hoverPoint = convert(event.locationInWindow, from: nil)
    }
    override func mouseMoved(with event: NSEvent) {
        if !isHovered { isHovered = true }
        hoverPoint = convert(event.locationInWindow, from: nil)
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hoverPoint = nil
    }

    private func hoverControl(at p: NSPoint?) -> Control? {
        guard let p else { return nil }
        return controlRects.first { $0.1.contains(p) }?.0
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        var v: NSView? = superview
        while let s = v, !(s is NSCollectionView) { v = s.superview }
        return (v as? NSCollectionView)?.menu(for: event)
    }

    /// Re-draws when the item's marks change (fine-grained Observation, no global reload).
    func observeItem() {
        guard let item else { return }
        withObservationTracking {
            _ = item.metadata
            _ = item.writeState
            _ = item.decodeFailed
            _ = item.files
            _ = item.isSharpestInStack
        } onChange: { [weak self, weak item] in
            DispatchQueue.main.async {
                guard let self, let item, self.item === item else { return }
                self.needsDisplay = true
                self.observeItem()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if isHovered, let c = hoverControl(at: p), let item {
            // Quick actions toggle, like the keys: clicking the current value clears it.
            let m = item.metadata
            switch c {
            case .pick: onQuickMark?(.flag(m.flag == .pick ? .none : .pick))
            case .reject: onQuickMark?(.flag(m.flag == .reject ? .none : .reject))
            case .star(let n): onQuickMark?(.rating(m.rating == n ? 0 : n))
            }
            return
        }
        if stackBadgeRect.contains(p), entry?.isStack == true {
            onStackBadge?()
            return
        }
        if manualClicks {
            downPoint = event.locationInWindow
            dragStarted = false
            if event.clickCount == 2 { onDoubleClick?() }
            return
        }
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard manualClicks, let start = downPoint, !dragStarted else {
            if !manualClicks { super.mouseDragged(with: event) }
            return
        }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) >= 4, let item else { return }
        dragStarted = true
        let dragItem = NSDraggingItem(pasteboardWriter: DragPayload.pasteboardItem(for: item))
        dragItem.setDraggingFrame(bounds, contents: dragImage())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }
        guard manualClicks else { super.mouseUp(with: event); return }
        if downPoint != nil, !dragStarted { onClick?() }
    }

    private func dragImage() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage(size: bounds.size) }
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: Drawing

    private static let star = NSColor(calibratedRed: 1, green: 0.8, blue: 0.3, alpha: 1)
    private static let sharpGreen = NSColor(calibratedRed: 0.45, green: 1, blue: 0.55, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: compact ? 2 : 3, dy: compact ? 2 : 3)
        let meta = item?.metadata ?? .empty
        let radius: CGFloat = compact ? 7 : 10
        let card = NSBezierPath(roundedRect: b, xRadius: radius, yRadius: radius)
        controlRects = []
        tips = []

        // Card fill: quiet by default, brighter on hover / selection; stack members share a warm tint.
        var fill = NSColor(white: 1, alpha: 0.045)
        if case .stackMember = entry?.kind { fill = Theme.nsAccentStart.withAlphaComponent(0.07) }
        if isHovered { fill = NSColor(white: 1, alpha: 0.09) }
        if isSelectedCell || isCurrent { fill = NSColor(white: 1, alpha: 0.13) }
        fill.setFill()
        card.fill()

        // Cards peeking out behind the photo: a pile for a collapsed stack (A), a RAW card behind the JPG of a pair (E).
        var stackTotal = 0
        if case .collapsedStack(_, let t) = entry?.kind { stackTotal = t }
        let isPile = stackTotal > 1
        let isPairCard = !isPile && item?.files.isPair == true
        let layers = isPile ? (stackTotal >= 3 ? 2 : 1) : (isPairCard ? 1 : 0)
        let step: CGFloat = compact ? 4 : 8
        var area = b.insetBy(dx: compact ? 4 : 6, dy: compact ? 4 : 6)
        if layers > 0 {
            let inset = step * CGFloat(layers)
            area = NSRect(x: area.minX, y: area.minY + inset, width: area.width - inset, height: area.height - inset)
        }

        // Photo rect (placeholder shape while loading).
        let r = image.map { aspectFit(CGSize(width: $0.width, height: $0.height), in: area) }
            ?? area.insetBy(dx: area.width * 0.12, dy: area.height * 0.18)
        let corner: CGFloat = compact ? 3 : 5
        if layers > 0 {
            for i in stride(from: layers, through: 1, by: -1) {
                let back = r.offsetBy(dx: step * CGFloat(i), dy: -step * CGFloat(i))
                let path = NSBezierPath(roundedRect: back, xRadius: corner, yRadius: corner)
                if isPairCard {
                    NSColor(calibratedRed: 0.40, green: 0.43, blue: 0.48, alpha: 1).setFill()
                } else {
                    NSColor(white: i == 1 ? 0.40 : 0.28, alpha: 1).setFill()
                }
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: NSColor(white: 0, alpha: 0.4).cgColor)
                path.fill()
                ctx.restoreGState()
                NSColor(white: 1, alpha: 0.14).setStroke()
                path.lineWidth = 0.75
                path.stroke()
                tips.append((back, isPairCard
                    ? "RAW+JPG: this shot has a RAW file behind the JPEG you see. Marks apply to both files."
                    : "Stack of \(stackTotal) photos taken together — S or double-click to expand."))
                if isPairCard && !compact && r.width > 70 {
                    // "RAW" tab on the back card's top-right corner.
                    let tab = pill(text: "RAW", at: NSPoint(x: back.maxX + 2, y: back.minY - 7), alignRight: true,
                                   fill: NSColor(calibratedRed: 0.27, green: 0.29, blue: 0.33, alpha: 0.96))
                    tips.append((tab, "RAW+JPG: a RAW file and a JPEG of the same shot, shown as one photo. Marks apply to both files."))
                }
            }
        }

        // Photo, with a soft shadow, as large as the card allows.
        if let image {
            let path = CGPath(roundedRect: r, cornerWidth: compact ? 3 : 5, cornerHeight: compact ? 3 : 5, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor(white: 0, alpha: 0.5).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.translateBy(x: 0, y: r.maxY + r.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .medium
            ctx.setAlpha(meta.flag == .reject ? 0.35 : 1)
            ctx.draw(image, in: r)
            ctx.restoreGState()
        } else {
            // Loading placeholder.
            NSColor(white: 1, alpha: 0.04).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            if item?.decodeFailed == true {
                drawCentered("Unsupported\nformat", in: r, size: 10, color: .secondaryLabelColor)
            } else {
                drawSymbol("photo", centeredIn: r, color: NSColor(white: 1, alpha: 0.18), size: compact ? 14 : 22)
            }
        }

        // Border: selection gradient, else the color label, else a hairline.
        if isSelectedCell || isCurrent {
            if isCurrent {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 10, color: Theme.nsAccentEnd.withAlphaComponent(0.55).cgColor)
                Theme.nsAccentEnd.withAlphaComponent(0.6).setStroke()
                card.lineWidth = 1
                card.stroke()
                ctx.restoreGState()
            }
            ctx.saveGState()
            ctx.addPath(card.cgPath)
            ctx.setLineWidth(isCurrent ? 3 : 2)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            let alpha: CGFloat = isCurrent ? 1 : 0.7
            NSGradient(starting: Theme.nsAccentStart.withAlphaComponent(alpha), ending: Theme.nsAccentEnd.withAlphaComponent(alpha))?
                .draw(in: b, angle: -45)
            ctx.restoreGState()
        } else if let c = labelColor(meta.label) {
            c.withAlphaComponent(0.85).setStroke()
            card.lineWidth = 2
            card.stroke()
            tips.append((b, "\(meta.label.displayName) label"))
        } else {
            NSColor(white: 1, alpha: 0.06).setStroke()
            card.lineWidth = 1
            card.stroke()
        }

        let pad: CGFloat = compact ? 3 : 5
        let showHoverBar = isHovered && !compact && image != nil && r.width > 110

        // The other file of a selected photo (separate RAW/JPEG mode): white dashed outline + PAIR tag.
        // Deliberately not orange: orange always means "pointer / selected".
        if isPartnerHighlighted && !isCurrent && !isSelectedCell {
            let dashed = NSBezierPath(roundedRect: b.insetBy(dx: 1.5, dy: 1.5), xRadius: radius, yRadius: radius)
            dashed.lineWidth = 2
            dashed.setLineDash([7, 5], count: 2, phase: 0)
            NSColor(white: 1, alpha: 0.8).setStroke()
            dashed.stroke()
            if r.width > 70 {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: compact ? 8 : 9, weight: .bold),
                                                            .foregroundColor: NSColor.black, .kern: 0.6]
                let t = NSAttributedString(string: "PAIR", attributes: attrs)
                let ts = t.size()
                let tag = NSRect(x: b.midX - ts.width / 2 - 6, y: b.minY - 1, width: ts.width + 12, height: ts.height + 4)
                NSColor(white: 1, alpha: 0.9).setFill()
                NSBezierPath(roundedRect: tag, xRadius: tag.height / 2, yRadius: tag.height / 2).fill()
                t.draw(at: NSPoint(x: tag.minX + 6, y: tag.minY + 2))
                tips.append((tag, "The other file of the selected photo (same shot)"))
            }
        }

        // Top-left: flag, sharpest.
        var x = r.minX + pad
        switch meta.flag {
        case .pick:
            let pr = pill(symbol: "flag.fill", color: .white, at: NSPoint(x: x, y: r.minY + pad))
            tips.append((pr, "Pick (P) — a keeper"))
            x = pr.maxX + 3
        case .reject:
            let rr = pill(symbol: "xmark", color: NSColor(calibratedRed: 1, green: 0.35, blue: 0.35, alpha: 1), at: NSPoint(x: x, y: r.minY + pad))
            tips.append((rr, "Reject (X) — marked only; nothing is deleted"))
            x = rr.maxX + 3
        case .none: break
        }
        if item?.isSharpestInStack == true {
            let sr = pill(symbol: "scope", color: Self.sharpGreen, at: NSPoint(x: x, y: r.minY + pad))
            tips.append((sr, "Sharpest frame of this stack (B jumps here). A hint — you decide."))
        }
        // Top-right: RAW+JPG pair, or the broken-chain cue of a separated pair; compare slot.
        if let item, item.files.isPair, isPile, !compact, r.width > 90 {
            let pr = pill(text: item.files.badge, at: NSPoint(x: r.maxX - pad, y: r.minY + pad), alignRight: true)
            tips.append((pr, "\(item.files.badge): a RAW file and a JPEG of the same shot, shown as one photo. Marks apply to both files."))
        } else if let partner = partnerName, let item {
            let kind = item.files.primary.kind.isRaw ? "RAW" : "JPG"
            let pr = pill(text: compact ? nil : kind, symbol: "personalhotspot.slash", color: Theme.nsAccentStart,
                          at: NSPoint(x: r.maxX - pad, y: r.minY + pad), alignRight: true)
            tips.append((pr, "Separated pair: the other file of this shot is \(partner). Hover to see it outlined; switch to RAW+JPG to treat them as one photo."))
        }
        if let s = compareSlot {
            pill(text: ["L", "R", "3", "4"][min(s, 3)], at: NSPoint(x: r.midX - 8, y: r.minY + pad), fill: Theme.nsAccentEnd)
        }

        // Bottom-right: stack.
        stackBadgeRect = .zero
        if let entry, !showHoverBar {
            var text: String?
            switch entry.kind {
            case .collapsedStack(let m, let t): text = m == t ? "\(t)" : "\(m)/\(t)"
            case .stackMember(let p, let c): text = "\(p)/\(c)"
            case .single: break
            }
            if let text {
                let collapsed = entry.isCollapsedStack
                // Filmstrip cells are narrow: top-right (free there) so it never collides with the bottom info pill.
                let y = compact ? r.minY + pad : r.maxY - pad - pillHeight
                stackBadgeRect = pill(text: text, symbol: compact ? nil : "square.stack", at: NSPoint(x: r.maxX - pad, y: y), alignRight: true,
                                      fill: collapsed ? Theme.nsAccentEnd.withAlphaComponent(0.92) : NSColor(white: 0.12, alpha: 0.78))
                    .insetBy(dx: -4, dy: -4)
                tips.append((stackBadgeRect, collapsed
                    ? "Stack of \(text) photos taken together. Click, double-click or press S to expand."
                    : "Photo \(text) of an expanded stack. Click or press S to collapse."))
            }
        }

        // Bottom-left: label dot, stars, note, save problem.
        if !showHoverBar {
            var parts: [(String?, NSColor)] = []
            if meta.label != .none, let c = labelColor(meta.label) { parts.append(("circle.fill", c)) }
            if meta.rating > 0 { parts.append((nil, Self.star)) }
            if meta.hasNote { parts.append(("text.bubble.fill", .white)) }
            if case .failed = item?.writeState { parts.append(("exclamationmark.triangle.fill", .systemOrange)) }
            if !parts.isEmpty {
                let origin = NSPoint(x: r.minX + pad, y: r.maxY - pad - pillHeight)
                drawInfoPill(parts, rating: meta.rating, at: origin)
                var desc: [String] = []
                if meta.label != .none { desc.append("\(meta.label.displayName) label") }
                if meta.rating > 0 { desc.append("\(meta.rating) star\(meta.rating == 1 ? "" : "s")") }
                if meta.hasNote { desc.append("Note: \(meta.note)") }
                if case .failed(let msg) = item?.writeState { desc.append("Not saved: \(msg)") }
                tips.append((NSRect(x: origin.x, y: origin.y, width: 120, height: pillHeight), desc.joined(separator: " · ")))
            }
        } else {
            drawHoverBar(in: r, meta: meta)
        }
    }

    private var pillHeight: CGFloat { compact ? 13 : 17 }

    /// Small dark rounded pill with an optional symbol and text. Returns its rect.
    @discardableResult
    private func pill(text: String? = nil, symbol: String? = nil, color: NSColor = .white, at p: NSPoint, alignRight: Bool = false,
                      fill: NSColor = NSColor(white: 0.08, alpha: 0.72)) -> NSRect {
        let h = pillHeight
        let font = NSFont.systemFont(ofSize: compact ? 8.5 : 10, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = text.map { ($0 as NSString).size(withAttributes: attrs) } ?? .zero
        let img = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: compact ? 7.5 : 9, weight: .bold).applying(.init(paletteColors: [color]))) }
        let iconW = img?.size.width ?? 0
        let gap: CGFloat = (img != nil && text != nil) ? 3 : 0
        var rect = NSRect(x: p.x, y: p.y, width: max(h, iconW + gap + textSize.width + (compact ? 8 : 11)), height: h)
        if alignRight { rect.origin.x -= rect.width }
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill()
        var cx = rect.minX + (rect.width - (iconW + gap + textSize.width)) / 2
        if let img {
            img.draw(in: NSRect(x: cx, y: rect.midY - img.size.height / 2, width: img.size.width, height: img.size.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            cx += iconW + gap
        }
        if let text {
            (text as NSString).draw(at: NSPoint(x: cx, y: rect.midY - textSize.height / 2), withAttributes: attrs)
        }
        return rect
    }

    private func drawInfoPill(_ parts: [(String?, NSColor)], rating: Int, at p: NSPoint) {
        let h = pillHeight
        let size: CGFloat = compact ? 7.5 : 9
        var items: [NSImage] = []
        for (sym, color) in parts {
            if let sym, let i = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .bold).applying(.init(paletteColors: [color]))) {
                items.append(i)
            } else if sym == nil, let s = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .bold).applying(.init(paletteColors: [color]))) {
                // Small cells (filmstrip): one star + the number, so it never collides with the stack badge.
                items += compact ? [s] : Array(repeating: s, count: rating)
            }
        }
        let widths = items.map(\.size.width).reduce(0, +) + CGFloat(max(0, items.count - 1)) * 1.5
        let rect = NSRect(x: p.x, y: p.y, width: widths + (compact ? 8 : 11), height: h)
        let digit = compact && rating > 0 ? "\(rating)" as NSString : nil
        let digitAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8.5, weight: .bold), .foregroundColor: Self.star]
        let digitW = digit.map { $0.size(withAttributes: digitAttrs).width + 2 } ?? 0
        let full = NSRect(x: rect.minX, y: rect.minY, width: rect.width + digitW, height: rect.height)
        NSColor(white: 0.08, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: full, xRadius: h / 2, yRadius: h / 2).fill()
        var x = rect.minX + (compact ? 4 : 5.5)
        for (k, i) in items.enumerated() {
            i.draw(in: NSRect(x: x, y: rect.midY - i.size.height / 2, width: i.size.width, height: i.size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += i.size.width + 1.5
            // The rating digit goes right after the star (stars come after an optional label dot).
            if let digit, k == (parts.first?.0 == "circle.fill" ? 1 : 0) {
                digit.draw(at: NSPoint(x: x - 0.5, y: rect.midY - 6), withAttributes: digitAttrs)
                x += digitW
            }
        }
    }

    /// Hover: file name + clickable pick / reject / stars over a gradient at the bottom of the photo.
    private func drawHoverBar(in r: NSRect, meta: PhotoMetadata) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let barH: CGFloat = min(52, r.height * 0.45)
        let bar = NSRect(x: r.minX, y: r.maxY - barH, width: r.width, height: barH)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.clip()
        NSGradient(starting: NSColor(white: 0, alpha: 0), ending: NSColor(white: 0, alpha: 0.72))?.draw(in: bar, angle: 90)
        ctx.restoreGState()

        if let name = item?.fileName, r.width > 140 {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.85)]
            let s = name as NSString
            s.draw(with: NSRect(x: r.minX + 7, y: bar.minY + 4, width: r.width - 14, height: 14),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }

        let hovered = hoverControl(at: hoverPoint)
        let y = r.maxY - 21
        let pickRect = NSRect(x: r.minX + 6, y: y, width: 18, height: 16)
        let rejectRect = NSRect(x: pickRect.maxX + 2, y: y, width: 18, height: 16)
        icon(meta.flag == .pick ? "flag.fill" : "flag", in: pickRect, color: meta.flag == .pick ? .white : NSColor(white: 1, alpha: hovered == .pick ? 1 : 0.6))
        icon("xmark", in: rejectRect, color: meta.flag == .reject ? NSColor(calibratedRed: 1, green: 0.35, blue: 0.35, alpha: 1)
             : NSColor(white: 1, alpha: hovered == .reject ? 1 : 0.6))
        controlRects += [(.pick, pickRect), (.reject, rejectRect)]

        // Stars: hovering previews the rating.
        var preview = meta.rating
        if case .star(let n) = hovered { preview = n }
        let starW: CGFloat = 14
        let startX = r.maxX - 6 - starW * 5
        guard startX > rejectRect.maxX + 4 else { return }
        for n in 1...5 {
            let sr = NSRect(x: startX + CGFloat(n - 1) * starW, y: y, width: starW, height: 16)
            icon(n <= preview ? "star.fill" : "star", in: sr, color: n <= preview ? Self.star : NSColor(white: 1, alpha: 0.5), size: 10)
            controlRects.append((.star(n), sr))
        }
    }

    private func icon(_ name: String, in r: NSRect, color: NSColor, size: CGFloat = 11) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .bold).applying(.init(paletteColors: [color]))) else { return }
        img.draw(in: NSRect(x: r.midX - img.size.width / 2, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawSymbol(_ name: String, centeredIn r: NSRect, color: NSColor, size: CGFloat) {
        icon(name, in: r, color: color, size: size)
    }

    private func aspectFit(_ s: CGSize, in r: NSRect) -> NSRect {
        guard s.width > 0, s.height > 0 else { return r }
        let scale = min(r.width / s.width, r.height / s.height)
        let w = s.width * scale, h = s.height * scale
        return NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h).integral
    }

    private func labelColor(_ l: ColorLabel) -> NSColor? {
        switch l {
        case .none: return nil
        case .red: return .systemRed
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        }
    }


    private func drawCentered(_ s: String, in r: NSRect, size: CGFloat, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: style]
        let h = (s as NSString).boundingRect(with: r.size, options: .usesLineFragmentOrigin, attributes: attrs).height
        (s as NSString).draw(in: NSRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h), withAttributes: attrs)
    }


}
