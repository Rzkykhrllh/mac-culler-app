import AppKit

let S: CGFloat = 1024
func icon(_ name: String, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS icon grid: 824 body, 100 margin, squircle-ish radius.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor(white: 0, alpha: 0.45).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 1), NSColor(calibratedRed: 0.06, green: 0.065, blue: 0.08, alpha: 1)])!
    bg.draw(in: NSBezierPath(rect: body), angle: -90)
    draw(ctx)
    ctx.restoreGState()
    // subtle rim
    ctx.addPath(shape); ctx.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor); ctx.setLineWidth(3); ctx.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: name + ".png"))
}

let amberA = NSColor(calibratedRed: 1.00, green: 0.74, blue: 0.30, alpha: 1)
let amberB = NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.45, alpha: 1)
func accent(_ rect: CGRect, angle: CGFloat = -45) -> NSGradient { NSGradient(colors: [amberA, amberB])! }

func photo(_ r: CGRect, _ ctx: CGContext, dim: CGFloat = 1, radius: CGFloat = 22) {
    let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    NSGradient(colors: [NSColor(calibratedRed: 0.40 * dim, green: 0.62 * dim, blue: 0.86 * dim, alpha: 1),
                        NSColor(calibratedRed: 0.22 * dim, green: 0.36 * dim, blue: 0.62 * dim, alpha: 1)])!.draw(in: p, angle: -90)
    // mountains
    NSGraphicsContext.saveGraphicsState(); p.addClip()
    let m = NSBezierPath()
    m.move(to: CGPoint(x: r.minX, y: r.minY)); m.line(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.28))
    m.line(to: CGPoint(x: r.minX + r.width * 0.36, y: r.minY + r.height * 0.58))
    m.line(to: CGPoint(x: r.minX + r.width * 0.58, y: r.minY + r.height * 0.36))
    m.line(to: CGPoint(x: r.minX + r.width * 0.74, y: r.minY + r.height * 0.50))
    m.line(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.22)); m.line(to: CGPoint(x: r.maxX, y: r.minY)); m.close()
    NSColor(calibratedRed: 0.12 * dim + 0.05, green: 0.20 * dim + 0.05, blue: 0.30 * dim + 0.05, alpha: 1).setFill(); m.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 1, alpha: 0.85 * dim).setStroke(); p.lineWidth = 10; p.stroke()
}

// 1. Contact sheet with a grease-pencil circle.
icon("1-contact-sheet") { ctx in
    let cols = 3, rows = 3
    let w: CGFloat = 196, h: CGFloat = 140, gx: CGFloat = 34, gy: CGFloat = 52
    let x0 = (S - (CGFloat(cols) * w + CGFloat(cols - 1) * gx)) / 2, y0 = (S - (CGFloat(rows) * h + CGFloat(rows - 1) * gy)) / 2
    for r in 0..<rows { for c in 0..<cols {
        let rect = CGRect(x: x0 + CGFloat(c) * (w + gx), y: y0 + CGFloat(r) * (h + gy), width: w, height: h)
        photo(rect, ctx, dim: (r == 1 && c == 1) ? 1 : 0.45, radius: 10)
    } }
    // grease pencil loop around the center frame
    let center = CGRect(x: x0 + w + gx, y: y0 + h + gy, width: w, height: h).insetBy(dx: -38, dy: -42)
    let loop = NSBezierPath(ovalIn: center)
    var t = AffineTransform(); t.translate(x: center.midX, y: center.midY); t.rotate(byDegrees: -8); t.translate(x: -center.midX, y: -center.midY)
    loop.transform(using: t)
    ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 18, color: amberB.withAlphaComponent(0.6).cgColor)
    amberB.setStroke(); loop.lineWidth = 26; loop.lineCapStyle = .round; loop.stroke()
    ctx.restoreGState()
}

// 2. Fan of picks with a check badge.
icon("2-fan") { ctx in
    for (i, a) in [(0, 14.0), (1, -10.0)] {
        ctx.saveGState(); ctx.translateBy(x: S / 2, y: S / 2 - 10); ctx.rotate(by: a * .pi / 180)
        photo(CGRect(x: -250 + CGFloat(i) * 12, y: -180, width: 500, height: 360), ctx, dim: 0.45 + CGFloat(i) * 0.15)
        ctx.restoreGState()
    }
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: NSColor(white: 0, alpha: 0.6).cgColor)
    photo(CGRect(x: S / 2 - 250, y: S / 2 - 190, width: 500, height: 360), ctx)
    ctx.restoreGState()
    let badge = CGRect(x: S / 2 + 140, y: S / 2 + 90, width: 190, height: 190)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 20, color: NSColor(white: 0, alpha: 0.5).cgColor)
    accent(badge).draw(in: NSBezierPath(ovalIn: badge), angle: -45); ctx.restoreGState()
    let c = NSBezierPath(); c.move(to: CGPoint(x: badge.minX + 52, y: badge.midY + 2)); c.line(to: CGPoint(x: badge.minX + 84, y: badge.midY - 32)); c.line(to: CGPoint(x: badge.maxX - 46, y: badge.midY + 40))
    NSColor(white: 0.08, alpha: 1).setStroke(); c.lineWidth = 26; c.lineCapStyle = .round; c.lineJoinStyle = .round; c.stroke()
}

// 3. Picture glyph whose sun is a check.
icon("3-picture-check") { ctx in
    let r = CGRect(x: 214, y: 270, width: 596, height: 480)
    let frame = NSBezierPath(roundedRect: r, xRadius: 64, yRadius: 64)
    NSColor(white: 1, alpha: 0.06).setFill(); frame.fill()
    NSColor(white: 0.93, alpha: 1).setStroke(); frame.lineWidth = 34; frame.stroke()
    NSGraphicsContext.saveGraphicsState(); frame.addClip()
    let m = NSBezierPath(); m.move(to: CGPoint(x: r.minX, y: r.minY)); m.line(to: CGPoint(x: r.minX, y: r.minY + 120))
    m.line(to: CGPoint(x: r.minX + 220, y: r.minY + 290)); m.line(to: CGPoint(x: r.minX + 360, y: r.minY + 150))
    m.line(to: CGPoint(x: r.minX + 450, y: r.minY + 220)); m.line(to: CGPoint(x: r.maxX, y: r.minY + 100)); m.line(to: CGPoint(x: r.maxX, y: r.minY)); m.close()
    NSColor(white: 0.93, alpha: 1).setFill(); m.fill()
    NSGraphicsContext.restoreGraphicsState()
    let sun = CGRect(x: r.maxX - 230, y: r.maxY - 220, width: 170, height: 170)
    accent(sun).draw(in: NSBezierPath(ovalIn: sun), angle: -45)
    let c = NSBezierPath(); c.move(to: CGPoint(x: sun.minX + 44, y: sun.midY + 2)); c.line(to: CGPoint(x: sun.minX + 74, y: sun.midY - 30)); c.line(to: CGPoint(x: sun.maxX - 40, y: sun.midY + 36))
    NSColor(white: 0.08, alpha: 1).setStroke(); c.lineWidth = 22; c.lineCapStyle = .round; c.lineJoinStyle = .round; c.stroke()
}

// 4. P whose bowl is a photo frame.
icon("4-p-frame") { ctx in
    let stem = NSBezierPath(roundedRect: CGRect(x: 300, y: 210, width: 120, height: 600), xRadius: 60, yRadius: 60)
    accent(stem.bounds).draw(in: stem, angle: -60)
    let bowl = CGRect(x: 360, y: 470, width: 380, height: 340)
    let p = NSBezierPath(roundedRect: bowl, xRadius: 80, yRadius: 80)
    NSGraphicsContext.saveGraphicsState(); p.addClip()
    photo(bowl.insetBy(dx: 30, dy: 30), ctx, radius: 40)
    NSGraphicsContext.restoreGraphicsState()
    let ring = NSBezierPath(roundedRect: bowl.insetBy(dx: 30, dy: 30), xRadius: 56, yRadius: 56)
    ring.lineWidth = 60
    NSGraphicsContext.saveGraphicsState()
    let outer = NSBezierPath(roundedRect: bowl, xRadius: 80, yRadius: 80); outer.append(NSBezierPath(roundedRect: bowl.insetBy(dx: 58, dy: 58), xRadius: 40, yRadius: 40)); outer.windingRule = .evenOdd
    outer.addClip(); accent(bowl).draw(in: bowl, angle: -60)
    NSGraphicsContext.restoreGraphicsState()
}
