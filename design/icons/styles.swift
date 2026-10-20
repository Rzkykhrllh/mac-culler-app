import AppKit

let S: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let amberA = NSColor(calibratedRed: 1.00, green: 0.74, blue: 0.30, alpha: 1)
let amberB = NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.45, alpha: 1)
func grad(_ a: NSColor, _ b: NSColor) -> NSGradient { NSGradient(colors: [a, b])! }

func icon(_ name: String, bg: (CGRect) -> Void, _ draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor(white: 0, alpha: 0.35).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    bg(body)
    draw(ctx)
    ctx.restoreGState()
    ctx.addPath(shape); ctx.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor); ctx.setLineWidth(3); ctx.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: name + ".png"))
}

/// A photo with mountains and a sun; `style` controls the look.
enum PhotoStyle { case color, dim, flat(NSColor), line(NSColor), outline(NSColor), polaroid }
func photo(_ r: CGRect, _ style: PhotoStyle, radius: CGFloat = 26) {
    switch style {
    case .polaroid:
        let card = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill(); card.fill()
        let inner = CGRect(x: r.minX + 26, y: r.minY + 90, width: r.width - 52, height: r.height - 116)
        landscape(inner, radius: 6, sky: grad(NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.48, alpha: 1), NSColor(calibratedRed: 0.36, green: 0.52, blue: 0.80, alpha: 1)),
                  ground: NSColor(calibratedRed: 0.16, green: 0.24, blue: 0.36, alpha: 1))
    case .color:
        landscape(r, radius: radius, sky: grad(NSColor(calibratedRed: 0.45, green: 0.68, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.24, green: 0.40, blue: 0.70, alpha: 1)),
                  ground: NSColor(calibratedRed: 0.14, green: 0.24, blue: 0.40, alpha: 1))
        let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius); NSColor(white: 1, alpha: 0.9).setStroke(); p.lineWidth = 12; p.stroke()
    case .dim:
        landscape(r, radius: radius, sky: grad(NSColor(calibratedRed: 0.24, green: 0.32, blue: 0.44, alpha: 1), NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.30, alpha: 1)),
                  ground: NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.20, alpha: 1))
        let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius); NSColor(white: 1, alpha: 0.45).setStroke(); p.lineWidth = 10; p.stroke()
    case .outline(let c):
        let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius); c.setStroke(); p.lineWidth = 18; p.stroke()
    case .flat(let c):
        let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius); c.setFill(); p.fill()
    case .line(let c):
        let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        NSColor(calibratedRed: 0.08, green: 0.085, blue: 0.10, alpha: 1).setFill(); p.fill()
        c.setStroke(); p.lineWidth = 22; p.stroke()
        let m = mountains(r.insetBy(dx: 11, dy: 11)); m.lineWidth = 22; m.lineJoinStyle = .round; m.lineCapStyle = .round
        NSGraphicsContext.saveGraphicsState(); p.addClip(); m.stroke(); NSGraphicsContext.restoreGraphicsState()
    }
}
func mountains(_ r: CGRect) -> NSBezierPath {
    let m = NSBezierPath()
    m.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.26))
    m.line(to: CGPoint(x: r.minX + r.width * 0.34, y: r.minY + r.height * 0.60))
    m.line(to: CGPoint(x: r.minX + r.width * 0.56, y: r.minY + r.height * 0.38))
    m.line(to: CGPoint(x: r.minX + r.width * 0.72, y: r.minY + r.height * 0.52))
    m.line(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.24))
    return m
}
func landscape(_ r: CGRect, radius: CGFloat, sky: NSGradient, ground: NSColor) {
    let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    sky.draw(in: p, angle: -90)
    NSGraphicsContext.saveGraphicsState(); p.addClip()
    let m = mountains(r); m.line(to: CGPoint(x: r.maxX, y: r.minY)); m.line(to: CGPoint(x: r.minX, y: r.minY)); m.close()
    ground.setFill(); m.fill()
    NSGraphicsContext.restoreGraphicsState()
}

/// The fan: two photos behind (rotated), one in front, a check badge.
func fan(_ ctx: CGContext, back: PhotoStyle, front: PhotoStyle, badgeFill: (CGRect) -> Void, checkColor: NSColor,
         size: CGSize = CGSize(width: 500, height: 360), shadow: CGFloat = 0.55, badge: CGFloat = 196) {
    for (i, a) in [(0, 14.0), (1, -10.0)] {
        ctx.saveGState(); ctx.translateBy(x: S / 2, y: S / 2 - 10); ctx.rotate(by: a * .pi / 180)
        photo(CGRect(x: -size.width / 2 + CGFloat(i) * 12, y: -size.height / 2, width: size.width, height: size.height), back)
        ctx.restoreGState()
    }
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: NSColor(white: 0, alpha: shadow).cgColor)
    photo(CGRect(x: S / 2 - size.width / 2, y: S / 2 - size.height / 2 - 10, width: size.width, height: size.height), front)
    ctx.restoreGState()
    let b = CGRect(x: S / 2 + size.width / 2 - badge / 2 - 30, y: S / 2 + size.height / 2 - badge / 2 - 10, width: badge, height: badge)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 20, color: NSColor(white: 0, alpha: 0.4).cgColor)
    badgeFill(b); ctx.restoreGState()
    let c = NSBezierPath()
    c.move(to: CGPoint(x: b.minX + b.width * 0.27, y: b.midY + 2)); c.line(to: CGPoint(x: b.minX + b.width * 0.44, y: b.midY - b.height * 0.17))
    c.line(to: CGPoint(x: b.maxX - b.width * 0.24, y: b.midY + b.height * 0.21))
    checkColor.setStroke(); c.lineWidth = b.width * 0.135; c.lineCapStyle = .round; c.lineJoinStyle = .round; c.stroke()
}
func amberBadge(_ b: CGRect) { grad(amberA, amberB).draw(in: NSBezierPath(ovalIn: b), angle: -45) }
let ink = NSColor(white: 0.08, alpha: 1)

// 1 Dark glass
icon("style-1-dark", bg: { grad(NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.21, alpha: 1), NSColor(calibratedRed: 0.06, green: 0.065, blue: 0.08, alpha: 1)).draw(in: $0, angle: -90) }) { ctx in
    fan(ctx, back: .dim, front: .color, badgeFill: amberBadge, checkColor: ink)
}
// 2 Light
icon("style-2-light", bg: { grad(NSColor(calibratedWhite: 1, alpha: 1), NSColor(calibratedWhite: 0.90, alpha: 1)).draw(in: $0, angle: -90) }) { ctx in
    fan(ctx, back: .flat(NSColor(calibratedWhite: 0.80, alpha: 1)), front: .color, badgeFill: amberBadge, checkColor: .white, shadow: 0.25)
}
// 3 Sunset
icon("style-3-sunset", bg: { grad(amberA, amberB).draw(in: $0, angle: -60) }) { ctx in
    fan(ctx, back: .flat(NSColor(white: 1, alpha: 0.35)), front: .color, badgeFill: { NSColor.white.setFill(); NSBezierPath(ovalIn: $0).fill() }, checkColor: amberB, shadow: 0.35)
}
// 4 Flat
icon("style-4-flat", bg: { NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.17, alpha: 1).setFill(); NSBezierPath(rect: $0).fill() }) { ctx in
    fan(ctx, back: .flat(NSColor(white: 1, alpha: 0.22)), front: .flat(NSColor(calibratedWhite: 0.96, alpha: 1)), badgeFill: amberBadge, checkColor: ink, shadow: 0.0)
}
// 5 Polaroid
icon("style-5-polaroid", bg: { grad(NSColor(calibratedRed: 0.20, green: 0.17, blue: 0.16, alpha: 1), NSColor(calibratedRed: 0.09, green: 0.08, blue: 0.08, alpha: 1)).draw(in: $0, angle: -90) }) { ctx in
    fan(ctx, back: .polaroid, front: .polaroid, badgeFill: { b in
        // stamp: amber ring
        let o = NSBezierPath(ovalIn: b.insetBy(dx: 6, dy: 6)); amberB.setStroke(); o.lineWidth = 14; o.stroke()
    }, checkColor: amberB, size: CGSize(width: 400, height: 470), shadow: 0.5)
}
// 6 Line art
icon("style-6-line", bg: { grad(NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1), NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)).draw(in: $0, angle: -90) }) { ctx in
    fan(ctx, back: .outline(NSColor(white: 1, alpha: 0.22)), front: .line(NSColor(white: 0.95, alpha: 1)), badgeFill: amberBadge, checkColor: ink, shadow: 0.0)
}
