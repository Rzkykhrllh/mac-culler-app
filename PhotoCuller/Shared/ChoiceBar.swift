import SwiftUI
import CullerKit

/// Segmented control with a tooltip per option (SwiftUI's segmented Picker can't show per-segment help).
struct ChoiceBar<T: Hashable>: View {
    struct Option {
        var value: T
        var title: String
        var symbol: String? = nil
        var help: String
    }

    let options: [Option]
    @Binding var selection: T
    /// Icons only (when an option has a symbol).
    var compact = false
    /// Toolbar look: equal icon segments in one glass capsule (the toolbar's own item background is hidden,
    /// so there is exactly one container and the selected pill has the same margin on every side).
    var toolbar = false

    var body: some View {
        if toolbar { toolbarBar } else { inlineBar }
    }

    private var toolbarBar: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                let selected = o.value == selection
                Button {
                    selection = o.value
                } label: {
                    Image(systemName: o.symbol ?? "circle")
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.black.opacity(0.85) : Color.primary.opacity(0.75))
                        .frame(width: 34, height: 24)
                        .background {
                            if selected { Capsule().fill(Theme.accent) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(o.help)
                .accessibilityLabel(o.title.isEmpty ? o.help : o.title)
            }
        }
        .padding(3)
        .glassCapsule()
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        .fixedSize()
        .animation(.smooth(duration: 0.15), value: selection)
    }

    private var inlineBar: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                let selected = o.value == selection
                Button {
                    selection = o.value
                } label: {
                    Group {
                        if compact, let s = o.symbol {
                            Image(systemName: s).frame(width: 18)
                        } else if let s = o.symbol, !compact, o.title.isEmpty {
                            Image(systemName: s)
                        } else {
                            Text(o.title).lineLimit(1)
                        }
                    }
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .padding(.horizontal, compact ? 6 : 10)
                    .padding(.vertical, 3.5)
                    .foregroundStyle(selected ? Color.black.opacity(0.85) : Color.primary.opacity(0.85))
                    .background {
                        if selected { Capsule().fill(Theme.accent) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(o.help)
                .accessibilityLabel(o.title.isEmpty ? o.help : o.title)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: Capsule())
        .fixedSize()
        .animation(.smooth(duration: 0.15), value: selection)
    }
}

/// Explanations shown as tooltips (and in the guide), in one place.
enum Explain {
    static func fileView(_ m: FileViewMode) -> String {
        switch m {
        case .combined: return "RAW+JPG — a RAW and the JPEG with the same name are one photo. Marks go to both files; you see the JPEG (the camera's look). ⌥⌘1"
        case .both: return "Separate — every file is its own photo, so RAW and JPEG can be marked differently. A broken-chain badge links the two files of a shot. ⌥⌘2"
        case .jpegOnly: return "JPG — only JPEG / HEIC / TIFF / PNG files, each on its own. ⌥⌘3"
        case .rawOnly: return "RAW — only RAW files, each on its own. ⌥⌘4"
        }
    }

    static func stacks(_ c: StackChoice) -> String {
        switch c {
        case .off: return "No stacks — every photo on its own. ⇧S"
        case .bursts: return "Bursts — frames taken within 1 second of each other (same camera) are stacked. ⌥S switches to Similar."
        case .similar: return "Similar — consecutive photos that look alike are stacked, even seconds apart. The slider sets how alike. ⌥S switches to Bursts."
        }
    }

    static func rawLook(_ r: RawRendering) -> String {
        switch r {
        case .rendered: return "True RAW — rendered from the sensor data: no film simulation or in-camera look. A bit slower the first time. ⌥⌘R"
        case .embedded: return "Camera preview — the JPEG the camera stored inside the RAW: the camera's look (e.g. film simulation), fastest. ⌥⌘R"
        }
    }

    static func viewMode(_ m: ViewMode) -> String {
        switch m {
        case .grid: return "Grid — all photos as thumbnails (G)"
        case .loupe: return "Loupe — one photo large with a filmstrip below (E). Z zooms to 100%."
        case .compare: return "Compare — 2 to 4 photos side by side (C). Drag from the filmstrip onto a side."
        }
    }
}
