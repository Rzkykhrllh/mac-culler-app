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

final class ThumbnailCellView: NSView {
    var entry: DisplayEntry? { didSet { needsDisplay = true } }
    var item: PhotoItem?
    var image: CGImage? { didSet { needsDisplay = true } }
    var isSelectedCell = false { didSet { if oldValue != isSelectedCell { needsDisplay = true } } }
    var isCurrent = false { didSet { if oldValue != isCurrent { needsDisplay = true } } }
    var compareSlot: Int? { didSet { if oldValue != compareSlot { needsDisplay = true } } }
    var compact = false
    var onDoubleClick: (() -> Void)?
    var onStackBadge: (() -> Void)?
    private var stackBadgeRect: NSRect = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

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
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds.insetBy(dx: compact ? 2 : 4, dy: compact ? 2 : 4)
        let meta = item?.metadata ?? .empty

        // Stack members get a shared tinted background so a burst reads as a group.
        var bg = NSColor(white: 0.17, alpha: 1)
        if case .stackMember = entry?.kind { bg = NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.27, alpha: 1) }
        if isSelectedCell || isCurrent { bg = NSColor(white: 0.30, alpha: 1) }
        let card = NSBezierPath(roundedRect: b, xRadius: 6, yRadius: 6)
        if entry?.isCollapsedStack == true {
            // Layered "pile" look for collapsed stacks.
            NSColor(white: 0.24, alpha: 1).setFill()
            NSBezierPath(roundedRect: b.offsetBy(dx: 3, dy: -3), xRadius: 6, yRadius: 6).fill()
        }
        bg.setFill()
        card.fill()

        let inner = b.insetBy(dx: 6, dy: 6)
        let imageArea = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height - (compact ? 0 : 14))
        if let image {
            let r = aspectFit(CGSize(width: image.width, height: image.height), in: imageArea)
            ctx.saveGState()
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

        // Selection / current ring.
        if isSelectedCell || isCurrent {
            (isCurrent ? NSColor.controlAccentColor : NSColor.controlAccentColor.withAlphaComponent(0.6)).setStroke()
            card.lineWidth = isCurrent ? 2.5 : 1.5
            card.stroke()
        }
        if let s = compareSlot {
            drawBadge(["L", "R", "3", "4"][min(s, 3)], at: NSPoint(x: b.midX - 8, y: b.minY + 2), fill: .controlAccentColor)
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
                stackBadgeRect = drawBadge(text, at: pt, alignRight: true, fill: entry.isCollapsedStack ? .controlAccentColor : NSColor(white: 0.4, alpha: 0.9))
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
        var r = NSRect(x: p.x, y: p.y, width: size.width + 8, height: 14)
        if alignRight { r.origin.x -= r.width }
        fill.setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        (s as NSString).draw(at: NSPoint(x: r.minX + 4, y: r.minY + (14 - size.height) / 2), withAttributes: attrs)
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
