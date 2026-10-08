import AppKit
import CullerKit

/// Grid / filmstrip cell: thumbnail + flag, rating, label, note, pair and stack badges (spec §6.1).
final class ThumbnailCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailCell")

    var cellView: ThumbnailCellView { view as! ThumbnailCellView }
    private var loadTask: Task<Void, Never>?
    private(set) var representedID: ItemID?

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
        cellView.item = nil
        cellView.image = nil
        cellView.isCurrent = false
        cellView.compareSlot = nil
    }

    func configure(entry: DisplayEntry, item: PhotoItem, pipeline: ImagePipeline, compact: Bool,
                   isCurrent: Bool, compareSlot: Int?) {
        let changed = representedID != item.id
        representedID = item.id
        cellView.entry = entry
        cellView.item = item
        cellView.compact = compact
        cellView.isCurrent = isCurrent
        cellView.compareSlot = compareSlot
        cellView.observeItem()
        guard changed || cellView.image == nil else { return }
        let primary = item.files.primary
        if let img = pipeline.cachedThumbnail(primary) {
            cellView.image = img
            return
        }
        cellView.image = nil
        loadTask?.cancel()
        let id = item.id
        loadTask = Task { [weak self] in
            let img = await pipeline.thumbnail(primary, priority: .high)
            guard let self, !Task.isCancelled, self.representedID == id else { return }
            if img == nil { item.decodeFailed = true }
            self.cellView.image = img
        }
    }
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

final class ThumbnailCellView: NSView, NSDraggingSource {
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
    /// Filmstrips handle clicks themselves (click = pick on mouse-up) so a drag never changes the active slot.
    var manualClicks = false
    var onClick: (() -> Void)?
    private var stackBadgeRect: NSRect = .zero
    private var downPoint: NSPoint?
    private var dragStarted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
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

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: compact ? 2 : 4, dy: compact ? 2 : 4)
        let meta = item?.metadata ?? .empty

        // Card: soft translucent gradient; stack members get a cool tint so a burst reads as a group.
        let radius: CGFloat = compact ? 7 : 10
        let card = NSBezierPath(roundedRect: b, xRadius: radius, yRadius: radius)
        if entry?.isCollapsedStack == true {
            // Layered "pile" look for collapsed stacks.
            NSColor(white: 1, alpha: 0.05).setFill()
            NSBezierPath(roundedRect: b.offsetBy(dx: 4, dy: -4).insetBy(dx: 2, dy: 0), xRadius: radius, yRadius: radius).fill()
        }
        var top = NSColor(white: 1, alpha: 0.075), bottom = NSColor(white: 1, alpha: 0.03)
        if case .stackMember = entry?.kind {
            top = NSColor(calibratedRed: 0.55, green: 0.6, blue: 1, alpha: 0.12)
            bottom = NSColor(calibratedRed: 0.55, green: 0.6, blue: 1, alpha: 0.05)
        }
        if isSelectedCell || isCurrent {
            top = NSColor(white: 1, alpha: 0.14)
            bottom = NSColor(white: 1, alpha: 0.07)
        }
        NSGradient(starting: top, ending: bottom)?.draw(in: card, angle: -90)

        let inner = b.insetBy(dx: 6, dy: 6)
        let imageArea = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height - (compact ? 0 : 14))
        if let image {
            let r = aspectFit(CGSize(width: image.width, height: image.height), in: imageArea)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: compact ? 3 : 5, cornerHeight: compact ? 3 : 5, transform: nil))
            ctx.clip()
            ctx.translateBy(x: 0, y: r.maxY + r.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .medium
            ctx.setAlpha(meta.flag == .reject ? 0.35 : 1)
            ctx.draw(image, in: r)
            ctx.restoreGState()
        } else {
            let text = item?.decodeFailed == true ? "Unsupported\nformat" : ""
            drawCentered(text, in: imageArea, size: 10, color: .secondaryLabelColor)
        }

        // Color label strip (bottom edge).
        if let c = labelColor(meta.label) {
            c.setFill()
            NSBezierPath(roundedRect: NSRect(x: b.minX + 6, y: b.maxY - 5, width: b.width - 12, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Selection / current ring: warm gradient stroke.
        if isSelectedCell || isCurrent {
            ctx.saveGState()
            ctx.addPath(card.cgPath)
            ctx.setLineWidth(isCurrent ? 3 : 2)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            let alpha: CGFloat = isCurrent ? 1 : 0.65
            NSGradient(starting: Theme.nsAccentStart.withAlphaComponent(alpha), ending: Theme.nsAccentEnd.withAlphaComponent(alpha))?
                .draw(in: b, angle: -45)
            ctx.restoreGState()
        } else {
            NSColor(white: 1, alpha: 0.06).setStroke()
            card.lineWidth = 1
            card.stroke()
        }
        if let s = compareSlot {
            drawBadge(["L", "R", "3", "4"][min(s, 3)], at: NSPoint(x: b.midX - 8, y: b.minY + 2), fill: Theme.nsAccentEnd)
        }

        // Flag badge (top-left).
        switch meta.flag {
        case .pick: drawSymbol("flag.fill", at: NSPoint(x: inner.minX, y: inner.minY), color: .white)
        case .reject: drawSymbol("xmark.circle.fill", at: NSPoint(x: inner.minX, y: inner.minY), color: .systemRed)
        case .none: break
        }

        // Pair badge (top-right).
        if let item, item.files.isPair, !compact {
            drawBadge(item.files.badge, at: NSPoint(x: inner.maxX, y: inner.minY), alignRight: true, fill: NSColor(white: 0, alpha: 0.55))
        }

        // Footer: stars, note, stack badge.
        if !compact {
            let footerY = b.maxY - 19
            if meta.rating > 0 {
                let stars = String(repeating: "★", count: meta.rating) + String(repeating: "·", count: 5 - meta.rating)
                draw(stars, at: NSPoint(x: inner.minX, y: footerY), size: 10, color: NSColor(calibratedRed: 1, green: 0.8, blue: 0.3, alpha: 1))
            }
            if meta.hasNote {
                drawSymbol("text.bubble.fill", at: NSPoint(x: inner.minX + 62, y: footerY - 1), color: .secondaryLabelColor, size: 10)
            }
            if case .failed = item?.writeState {
                drawSymbol("exclamationmark.triangle.fill", at: NSPoint(x: inner.minX + 78, y: footerY - 1), color: .systemOrange, size: 10)
            }
        } else if meta.rating > 0 {
            drawBadge(String(repeating: "★", count: meta.rating), at: NSPoint(x: inner.minX, y: inner.maxY - 14), fill: NSColor(white: 0, alpha: 0.5))
        }
        stackBadgeRect = .zero
        if let entry {
            var text: String?
            switch entry.kind {
            case .collapsedStack(let m, let t): text = m == t ? "×\(t)" : "\(m)/\(t)"
            case .stackMember(let p, let c): text = "\(p)/\(c)"
            case .single: break
            }
            if let text {
                let pt = NSPoint(x: inner.maxX, y: compact ? inner.maxY - 14 : b.maxY - 21)
                stackBadgeRect = drawBadge(text, at: pt, alignRight: true, fill: entry.isCollapsedStack ? Theme.nsAccentEnd.withAlphaComponent(0.9) : NSColor(white: 0.35, alpha: 0.85))
                    .insetBy(dx: -4, dy: -4)
            }
        }
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

    private func draw(_ s: String, at p: NSPoint, size: CGFloat, color: NSColor) {
        (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color])
    }

    private func drawCentered(_ s: String, in r: NSRect, size: CGFloat, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: style]
        let h = (s as NSString).boundingRect(with: r.size, options: .usesLineFragmentOrigin, attributes: attrs).height
        (s as NSString).draw(in: NSRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h), withAttributes: attrs)
    }

    @discardableResult
    private func drawBadge(_ s: String, at p: NSPoint, alignRight: Bool = false, fill: NSColor) -> NSRect {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white]
        let size = (s as NSString).size(withAttributes: attrs)
        var r = NSRect(x: p.x, y: p.y, width: size.width + 10, height: 15)
        if alignRight { r.origin.x -= r.width }
        fill.setFill()
        NSBezierPath(roundedRect: r, xRadius: 7.5, yRadius: 7.5).fill()
        (s as NSString).draw(at: NSPoint(x: r.minX + 5, y: r.minY + (15 - size.height) / 2), withAttributes: attrs)
        return r
    }

    private func drawSymbol(_ name: String, at p: NSPoint, color: NSColor, size: CGFloat = 12) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .bold).applying(.init(paletteColors: [color]))) else { return }
        // Dark backdrop for legibility on bright photos.
        NSColor(white: 0, alpha: 0.45).setFill()
        let r = NSRect(origin: p, size: img.size).insetBy(dx: -2, dy: -2)
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        img.draw(in: NSRect(origin: p, size: img.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
