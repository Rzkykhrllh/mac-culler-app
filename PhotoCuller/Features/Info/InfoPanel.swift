import SwiftUI
import CullerKit

/// Full info panel (I): capture details and every file of the item (spec §6.4).
struct InfoPanel: View {
    let session: FolderSession

    var body: some View {
        Group {
            if let item = session.currentItem {
                Form {
                    Section("Marks") {
                        MarksView(metadata: item.metadata, writeState: item.writeState)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .glassCapsule()
                        if item.metadata.hasNote {
                            Text(item.metadata.note).textSelection(.enabled)
                        }
                        if case .failed(let msg) = item.writeState {
                            Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    if let e = item.exif {
                        Section("Capture") {
                            row("Date", ExifFormat.captureDate(e))
                            row("Camera", e.cameraName)
                            row("Serial", e.bodySerial)
                            row("Lens", e.lens)
                            row("Focal length", ExifFormat.focal(e.focalLength))
                            row("Aperture", ExifFormat.aperture(e.aperture))
                            row("Shutter", ExifFormat.shutter(e.shutter))
                            row("ISO", e.iso.map(String.init))
                            row("Exposure comp.", ExifFormat.exposureComp(e.exposureCompensation))
                            row("Program", ExifFormat.exposureProgram(e.exposureProgram))
                            row("Exposure mode", ExifFormat.exposureMode(e.exposureMode))
                            row("Dimensions", e.orientedSize.map { "\($0.width) × \($0.height)" })
                        }
                    } else {
                        Section("Capture") { Text("Reading EXIF…").foregroundStyle(.secondary) }
                    }
                    Section("Files") {
                        ForEach(item.files.allURLs, id: \.self) { url in
                            HStack {
                                Text(url.lastPathComponent).textSelection(.enabled)
                                Spacer()
                                Text(fileSize(url)).foregroundStyle(.secondary)
                            }
                        }
                        row("Total size", ExifFormat.bytes(item.totalSize))
                        row("Modified", ExifFormat.captureFormatter.string(from: item.files.primary.modificationDate))
                        if let sid = session.stackOf[item.id], let members = session.stackMembers[sid] {
                            row("Burst stack", "\((members.firstIndex(of: item.id) ?? 0) + 1) of \(members.count)")
                        }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.files.allURLs) }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("No Photo", systemImage: "info.circle")
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title) { Text(value).textSelection(.enabled) }
        }
    }

    private func fileSize(_ url: URL) -> String {
        let s = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ExifFormat.bytes(Int64(s))
    }
}

/// RGB histogram computed lazily from the screen preview, only while visible (spec §6.4).
struct HistogramView: View {
    let image: CGImage
    @State private var histogram: Histogram?

    var body: some View {
        Canvas { ctx, size in
            guard let h = histogram else { return }
            let peak = CGFloat(max(1, [h.red, h.green, h.blue].flatMap { $0.dropFirst().dropLast() }.max() ?? 1))
            for (bins, color) in [(h.red, Color.red), (h.green, Color.green), (h.blue, Color.blue)] {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in bins.enumerated() {
                    let x = CGFloat(i) / 255 * size.width
                    p.addLine(to: CGPoint(x: x, y: size.height - min(1, CGFloat(v) / peak) * size.height))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                ctx.fill(p, with: .color(color.opacity(0.45)))
            }
        }
        .padding(8)
        .glassCard(12)
        .task(id: ObjectIdentifier(image)) {
            let img = image
            histogram = await Task.detached(priority: .utility) { Histogram.compute(img) }.value
        }
    }
}
