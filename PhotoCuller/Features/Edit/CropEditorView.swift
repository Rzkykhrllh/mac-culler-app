import SwiftUI
import CullerKit

/// Aspect-fit rect of `size` inside `bounds`.
func aspectFitRect(_ size: CGSize, in bounds: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
    let s = min(bounds.width / size.width, bounds.height / size.height)
    let w = size.width * s, h = size.height * s
    return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
}

/// Loupe crop / straighten editor. Edits `session.cropDraft`; Return / Done commits, Esc / Cancel discards.
struct CropEditorView: View {
    @Bindable var session: FolderSession
    let image: CGImage?
    let pixelSize: CGSize

    private enum Handle: CaseIterable, Hashable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
        var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
        var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }
    }

    @State private var dragStart: CropSpec?

    private var crop: CropSpec { session.cropDraft ?? .full }
    private var ratio: Double? { CropGeometry.ratio(for: crop.aspect, imageSize: pixelSize) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let area = CGRect(origin: .zero, size: geo.size)
                let fit = aspectFitRect(pixelSize, in: area.insetBy(dx: 36, dy: 30))
                let cr = viewRect(crop, fit)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.25)
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fit.width, height: fit.height)
                            .rotationEffect(.degrees(crop.angle))
                            .position(x: fit.midX, y: fit.midY)
                    }
                    Path { p in
                        p.addRect(area)
                        p.addRect(cr)
                    }
                    .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    frameLines(cr)
                    // Drag inside to move.
                    Rectangle().fill(Color.white.opacity(0.001))
                        .frame(width: cr.width, height: cr.height)
                        .position(x: cr.midX, y: cr.midY)
                        .gesture(dragGesture(nil, fit))
                    ForEach(Array(Handle.allCases), id: \.self) { h in
                        if h.isCorner || ratio == nil { handle(h, cr, fit) }
                    }
                }
                .clipped()
            }
            controls
        }
    }

    // MARK: Drawing

    private func viewRect(_ c: CropSpec, _ fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + c.x * fit.width, y: fit.minY + c.y * fit.height, width: c.width * fit.width, height: c.height * fit.height)
    }

    private func frameLines(_ r: CGRect) -> some View {
        Path { p in
            p.addRect(r)
            for i in 1...2 {
                let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.75), lineWidth: 1)
        .allowsHitTesting(false)
    }

    private func handle(_ h: Handle, _ r: CGRect, _ fit: CGRect) -> some View {
        let x = h.movesLeft ? r.minX : h.movesRight ? r.maxX : r.midX
        let y = h.movesTop ? r.minY : h.movesBottom ? r.maxY : r.midY
        return RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: h.isCorner ? 14 : (h.movesTop || h.movesBottom ? 26 : 6), height: h.isCorner ? 14 : (h.movesLeft || h.movesRight ? 26 : 6))
            .shadow(color: .black.opacity(0.5), radius: 2)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .position(x: x, y: y)
            .gesture(dragGesture(h, fit))
    }

    // MARK: Dragging

    private func dragGesture(_ h: Handle?, _ fit: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if dragStart == nil { dragStart = crop }
                guard let s = dragStart else { return }
                let dx = Double(v.translation.width / fit.width), dy = Double(v.translation.height / fit.height)
                session.cropDraft = h.map { resized(s, $0, dx, dy) } ?? moved(s, dx, dy)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func moved(_ s: CropSpec, _ dx: Double, _ dy: Double) -> CropSpec {
        func at(_ dx: Double, _ dy: Double) -> CropSpec {
            var c = s
            c.x = min(max(0, s.x + dx), 1 - s.width)
            c.y = min(max(0, s.y + dy), 1 - s.height)
            return c
        }
        // Slide along an edge when one direction is blocked.
        for c in [at(dx, dy), at(dx, 0), at(0, dy)] where CropGeometry.fits(c, imageSize: pixelSize) { return c }
        return crop
    }

    private func resized(_ s: CropSpec, _ h: Handle, _ dx: Double, _ dy: Double) -> CropSpec {
        let minN = 0.04
        var L = s.x, T = s.y, R = s.x + s.width, B = s.y + s.height
        if h.movesLeft { L = min(max(0, L + dx), R - minN) }
        if h.movesRight { R = max(min(1, R + dx), L + minN) }
        if h.movesTop { T = min(max(0, T + dy), B - minN) }
        if h.movesBottom { B = max(min(1, B + dy), T + minN) }
        if let r = ratio, h.isCorner {
            // Width leads; height follows the locked ratio (in pixels).
            let hN = (R - L) * Double(pixelSize.width) / (r * Double(pixelSize.height))
            if h.movesTop { T = B - hN } else { B = T + hN }
            guard T >= -0.0001, B <= 1.0001 else { return crop }
        }
        let c = CropSpec(x: L, y: T, width: R - L, height: B - T, angle: s.angle, aspect: s.aspect)
        return CropGeometry.fits(c, imageSize: pixelSize) ? c : crop
    }

    // MARK: Controls

    private var aspectBinding: Binding<String> {
        Binding(get: { crop.aspect ?? "free" }, set: { id in
            if id == "free" {
                var c = crop; c.aspect = nil
                session.cropDraft = c
            } else {
                session.cropDraft = CropGeometry.largest(ratio: CropGeometry.ratio(for: id, imageSize: pixelSize),
                                                         angle: crop.angle, imageSize: pixelSize, aspect: id)
            }
        })
    }

    private var angleBinding: Binding<Double> {
        Binding(get: { crop.angle }, set: { a in
            var c = crop
            c.angle = (a * 10).rounded() / 10
            session.cropDraft = CropGeometry.shrinkToFit(c, imageSize: pixelSize)
        })
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlRow(compact: false)
            VStack(spacing: 8) { aspectBar; HStack { straighten; Spacer(); buttons } }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(16)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func controlRow(compact: Bool) -> some View {
        HStack(spacing: 16) { aspectBar; straighten; Spacer(minLength: 8); buttons }
    }

    private var aspectBar: some View {
        ChoiceBar(options: CropGeometry.presets.map { p in
            .init(value: p.id, title: p.title, help: ExportSheet.ratioHints[p.id].map { "\(p.title) — \($0)" } ?? "Crop to \(p.title)")
        }, selection: aspectBinding)
    }

    private var straighten: some View {
        HStack(spacing: 8) {
            Image(systemName: "level").foregroundStyle(.secondary)
            Slider(value: angleBinding, in: -45...45)
                .frame(width: 150)
                .help("Straighten (rotate the photo); the crop stays inside it")
            Button(String(format: "%+.1f°", crop.angle)) { angleBinding.wrappedValue = 0 }
                .buttonStyle(.borderless)
                .monospacedDigit()
                .frame(width: 52)
                .help("Click: back to 0°")
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button("Reset") { session.cropDraft = .full }
                .help("Whole photo, not rotated")
            Button("Cancel") { session.cancelCrop() }
                .help("Discard changes (Esc)")
            Button("Done") { session.commitCrop() }
                .buttonStyle(.borderedProminent)
                .help("Apply the crop (Return). Undo with ⌘Z")
        }
    }
}

/// In the loupe (not zoomed): darkens what a photo's crop leaves out, so you see what will be exported.
struct CropPreviewOverlay: View {
    let crop: CropSpec
    let pixelSize: CGSize

    var body: some View {
        GeometryReader { geo in
            let fit = aspectFitRect(pixelSize, in: CGRect(origin: .zero, size: geo.size))
            let sx = fit.width / max(1, pixelSize.width), sy = fit.height / max(1, pixelSize.height)
            let pts = CropGeometry.sourceCorners(of: crop, imageSize: pixelSize).map { CGPoint(x: fit.minX + $0.x * sx, y: fit.minY + $0.y * sy) }
            ZStack {
                Path { p in
                    p.addRect(fit)
                    p.addLines(pts); p.closeSubpath()
                }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                Path { p in p.addLines(pts); p.closeSubpath() }
                    .stroke(Color.white.opacity(0.7), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}
