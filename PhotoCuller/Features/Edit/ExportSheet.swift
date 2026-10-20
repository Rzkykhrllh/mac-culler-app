import SwiftUI
import UniformTypeIdentifiers
import CullerKit

/// ⇧⌘E: export the selected photos with their crop, a border or a fixed-ratio canvas, resized.
struct ExportSheet: View {
    @Bindable var session: FolderSession
    @Environment(\.dismiss) private var dismiss
    @State private var o = ExportSettings.last
    @State private var folder: URL?
    @State private var preview: CGImage?
    /// Canvas ratio typed in (Custom…).
    @State private var customRatio = false

    private enum Preset: String, CaseIterable, Identifiable {
        case canvas, border, custom
        var id: String { rawValue }
        var title: String { ["4:5 Canvas", "White Border", "Custom"][Self.allCases.firstIndex(of: self)!] }
    }

    private enum FrameKind: String, CaseIterable, Identifiable {
        case none, border, canvas
        var id: String { rawValue }
    }

    private var targets: [PhotoItem] { session.exportTargets.compactMap { session.items[$0] } }

    private var preset: Preset {
        if o.frame == ExportOptions.fourFiveCanvas.frame && o.size == ExportOptions.fourFiveCanvas.size { return .canvas }
        if o.frame == ExportOptions.whiteBorder.frame && o.size == ExportOptions.whiteBorder.size { return .border }
        return .custom
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                previewPane
                Form { settings }
                    .formStyle(.grouped)
                    .frame(width: 400)
            }
            .padding([.top, .horizontal], 16)
            HStack {
                Text(destinationText).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(targets.count == 1 ? "Export" : "Export \(targets.count) Photos") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(targets.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 740, height: 660)
        .task(id: o) { await renderPreview() }
    }

    // MARK: Settings

    @ViewBuilder private var settings: some View {
        Section {
            Picker("Preset", selection: Binding(get: { preset }, set: { p in
                let keep = o
                switch p {
                case .canvas: o = .fourFiveCanvas
                case .border: o = .whiteBorder
                case .custom: return
                }
                o.quality = keep.quality; o.stripLocation = keep.stripLocation; o.useRaw = keep.useRaw
            })) {
                ForEach(Preset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        Section("Frame") {
            Picker("Frame", selection: frameKind) {
                Text("None").tag(FrameKind.none)
                Text("Border").tag(FrameKind.border)
                Text("Canvas").tag(FrameKind.canvas)
            }
            .pickerStyle(.segmented)
            switch o.frame {
            case .none:
                Text("Only the crop, nothing added.").font(.caption).foregroundStyle(.secondary)
            case .border(let p):
                LabeledContent("Border") {
                    HStack {
                        Slider(value: Binding(get: { p }, set: { o.frame = .border(percent: $0.rounded()) }), in: 0...30)
                        Text("\(Int(p))%").monospacedDigit().frame(width: 40)
                    }
                }
                Text(borderExample(p)).font(.caption).foregroundStyle(.secondary)
            case .canvas(let w, let h, let m):
                Picker("Canvas", selection: Binding(get: {
                    let key = "\(fmt(w)):\(fmt(h))"
                    return customRatio || !Self.ratios.contains(key) ? "custom" : key
                }, set: { v in
                    if v == "custom" { customRatio = true; return }
                    customRatio = false
                    let parts = v.split(separator: ":").compactMap { Double($0) }
                    if parts.count == 2 { o.frame = .canvas(width: parts[0], height: parts[1], marginPercent: m) }
                })) {
                    ForEach(Self.ratios, id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("Custom…").tag("custom")
                }
                if customRatio || !Self.ratios.contains("\(fmt(w)):\(fmt(h))") {
                    LabeledContent("Ratio") {
                        HStack(spacing: 6) {
                            TextField("W", value: Binding(get: { w }, set: { o.frame = .canvas(width: max(0.1, $0), height: h, marginPercent: m) }),
                                      format: .number.precision(.fractionLength(0...2)))
                                .frame(width: 56).multilineTextAlignment(.trailing)
                            Text(":")
                            TextField("H", value: Binding(get: { h }, set: { o.frame = .canvas(width: w, height: max(0.1, $0), marginPercent: m) }),
                                      format: .number.precision(.fractionLength(0...2)))
                                .frame(width: 56)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
                LabeledContent("Margin") {
                    HStack {
                        Slider(value: Binding(get: { m }, set: { o.frame = .canvas(width: w, height: h, marginPercent: $0.rounded()) }), in: 0...20)
                        Text("\(Int(m))%").monospacedDigit().frame(width: 40)
                    }
                }
                Text("The photo is centered on the canvas; a photo cropped to the same ratio fills it.").font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Color") {
                HStack {
                    Picker("", selection: colorChoice) {
                        Text("White").tag("white"); Text("Black").tag("black"); Text("Custom").tag("custom")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    ColorPicker("", selection: customColor, supportsOpacity: false).labelsHidden()
                }
            }
            .disabled(o.frame == .none)
        }
        Section("Output") {
            Picker("Size", selection: sizeChoice) {
                Text("Original").tag("original")
                Text("Long edge 4096").tag("4096")
                Text("Long edge 2048").tag("2048")
                Text("Long edge 1080").tag("1080")
                Text("Width 1080").tag("w1080")
            }
            LabeledContent("Quality") {
                HStack {
                    Slider(value: $o.quality, in: 0.6...1)
                    Text("\(Int((o.quality * 100).rounded()))%").monospacedDigit().frame(width: 40)
                }
            }
            Toggle("Remove location (GPS)", isOn: $o.stripLocation)
            if targets.contains(where: { $0.files.isPair }) {
                Toggle("Render RAW (True RAW) instead of the camera JPEG", isOn: $o.useRaw)
            }
            LabeledContent("Save to") {
                HStack {
                    Text(folder?.lastPathComponent ?? "Exports folder next to the photos").lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseFolder() }
                    if folder != nil { Button("Reset") { folder = nil } }
                }
            }
        }
    }

    private var frameKind: Binding<FrameKind> {
        Binding(get: {
            switch o.frame { case .none: .none; case .border: .border; case .canvas: .canvas }
        }, set: { k in
            switch k {
            case .none: o.frame = .none
            case .border: o.frame = .border(percent: 10)
            case .canvas: o.frame = .canvas(width: 4, height: 5, marginPercent: 0); customRatio = false
            }
        })
    }

    private var colorChoice: Binding<String> {
        Binding(get: {
            if o.red > 0.99 && o.green > 0.99 && o.blue > 0.99 { return "white" }
            if o.red < 0.01 && o.green < 0.01 && o.blue < 0.01 { return "black" }
            return "custom"
        }, set: { v in
            switch v {
            case "white": (o.red, o.green, o.blue) = (1, 1, 1)
            case "black": (o.red, o.green, o.blue) = (0, 0, 0)
            default: (o.red, o.green, o.blue) = (0.96, 0.94, 0.90)
            }
        })
    }

    private var customColor: Binding<Color> {
        Binding(get: { Color(.sRGB, red: o.red, green: o.green, blue: o.blue) }, set: { c in
            if let n = NSColor(c).usingColorSpace(.sRGB) { (o.red, o.green, o.blue) = (n.redComponent, n.greenComponent, n.blueComponent) }
        })
    }

    private var sizeChoice: Binding<String> {
        Binding(get: {
            switch o.size {
            case .original: "original"
            case .longEdge(let l): "\(l)"
            case .width(let w): "w\(w)"
            case .exact: "exact"
            }
        }, set: { v in
            switch v {
            case "original": o.size = .original
            case "w1080": o.size = .width(1080)
            case "exact": break
            default: o.size = .longEdge(Int(v) ?? 2048)
            }
        })
    }

    static let ratios = ["4:5", "1:1", "5:4", "2:3", "3:2", "9:16", "16:9"]

    private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2g", v) }

    /// File name ending: what was done, e.g. "-4x5", "-border".
    private var suffix: String {
        switch o.frame {
        case .none: "-export"
        case .border: "-border"
        case .canvas(let w, let h, _): "-\(fmt(w))x\(fmt(h))"
        }
    }

    private func borderExample(_ p: Double) -> String {
        guard let first = targets.first else { return "" }
        let s = ImageDecoder.orientedPixelSize(of: first.files.primary.url) ?? .zero
        let photo = CropGeometry.outputSize(of: first.metadata.crop, imageSize: s)
        let px = Int((p / 100 * Double(min(photo.width, photo.height))).rounded())
        return "\(Int(p))% of the shorter side — \(px) px on each side of \(first.fileName) before resizing."
    }

    private var destinationText: String {
        folder.map { "Saving to \($0.path)" } ?? "Saving to an “Exports” folder next to each photo · names end in “\(suffix)”"
    }

    // MARK: Preview

    private var previewPane: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35))
                if let preview {
                    Image(decorative: preview, scale: 1).resizable().interpolation(.high).scaledToFit()
                        .shadow(color: .black.opacity(0.4), radius: 6)
                        .padding(14)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 270, height: 420)
            if let first = targets.first {
                Text(targets.count > 1 ? "\(first.fileName) and \(targets.count - 1) more" : first.fileName)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func renderPreview() async {
        guard let first = targets.first else { return }
        var p = o
        p.size = .longEdge(700)
        if case .width = o.size { p.size = .width(560) }
        if case .exact(let w, let h) = o.size {
            let s = 700.0 / Double(max(w, h))
            p.size = .exact(width: Int(Double(w) * s), height: Int(Double(h) * s))
        }
        let files = first.files, crop = first.metadata.crop, useRaw = o.useRaw
        let options = p
        let img = await Offload.run { () -> CGImage? in
            let file: FileRef = useRaw ? (files.raw ?? files.primary) : (files.files.first { $0.kind.isRaster } ?? files.primary)
            guard let src = ImageDecoder.preview(for: file, maxPixel: 1400, raw: useRaw ? .rendered : .embedded) else { return nil }
            return PhotoExporter.render(src, crop: crop, options: options)
        }
        if !Task.isCancelled { preview = img }
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        if panel.runModal() == .OK { folder = panel.url }
    }

    private func start() {
        o.suffix = suffix
        ExportSettings.last = o
        let ids = session.exportTargets, options = o, dest = folder
        dismiss()
        Task { await session.export(ids, options: options, to: dest) }
    }
}
