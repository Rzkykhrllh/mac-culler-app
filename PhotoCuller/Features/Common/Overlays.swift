import SwiftUI
import CullerKit

/// Big, brief confirmation of a mark — centered over the photos.
struct MarkHUDView: View {
    let hud: MarkHUD

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                if let s = hud.symbol {
                    Image(systemName: s).font(.system(size: 30, weight: .semibold)).foregroundStyle(color)
                }
                Text(hud.text)
                    .font(.system(size: hud.tint == .star ? 38 : 26, weight: .bold, design: .rounded))
                    .foregroundStyle(hud.tint == .star ? AnyShapeStyle(color) : AnyShapeStyle(.white))
            }
            if let d = hud.detail {
                Text(d).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .glassCard(22)
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }

    private var color: Color {
        switch hud.tint {
        case .neutral: return .white
        case .pick: return .white
        case .reject: return Color(red: 1, green: 0.35, blue: 0.35)
        case .star: return Color(red: 1, green: 0.8, blue: 0.3)
        case .label(let l): return l.color
        }
    }
}

/// Press ? : every shortcut, grouped, inside the window.
struct ShortcutSheet: View {
    let onClose: () -> Void

    private let groups: [(String, String, [(String, String)])] = [
        ("Mark", "flag", [("P / X / U", "Pick · Reject · Unflag"), ("0 – 5", "Rating"), ("6 7 8 9", "Red · Yellow · Green · Blue"),
                         ("⌥9 / ⌥0", "Purple · Clear label"), ("⇧ + key", "Mark and go to next"), ("Caps Lock", "Auto-advance"), ("M", "Note")]),
        ("Move around", "arrow.left.arrow.right", [("← →", "Previous · Next"), ("↑ ↓", "Row up · down (grid)"), ("⌥← ⌥→", "Previous · Next unflagged"),
                                                  ("⇧ + arrows", "Extend selection"), ("Return", "Open in loupe"), ("Esc", "Back to grid")]),
        ("View", "eye", [("G / E / C", "Grid · Loupe · Compare"), ("Z / Space", "100% zoom"), ("I / H", "Info panel · Histogram"),
                         ("⌘F", "Filter"), ("⌘= / ⌘−", "Thumbnail size"), ("⌥⌘1 – 4", "RAW+JPG · Separate · JPG · RAW")]),
        ("Focus", "scope", [("F", "Focus peaking"), ("J", "Clipping"), ("Y", "Zoom to eyes / face / animal"), ("B", "Sharpest in stack")]),
        ("Stacks & compare", "square.stack", [("S", "Expand / collapse"), ("⇧S / ⌥S", "Stacks on/off · Bursts ↔ Similar"), ("⌥[ / ⌥]", "Similarity stricter · looser"),
                                              ("Tab", "Next compare slot"), ("⌥Z / ⌥P", "Sync zoom · Pin best"), ("⌥2 – ⌥4", "Number of slots")]),
        ("Files & tabs", "folder", [("F2", "Rename"), ("⇧⌘M / ⇧⌘C", "Move · Copy"), ("⌘⌫ / ⇧⌘⌫", "Trash photo · all rejects"), ("⌘Z / ⇧⌘Z", "Undo · Redo"), ("⌘T / ⌘W", "New · Close tab"),
                                    ("⌘1 – 9", "Go to tab"), ("⌘↑ / ⌥⌘↓", "Enclosing · Next folder")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Keyboard shortcuts", systemImage: "keyboard").font(.title3.bold())
                Spacer()
                Text("? or Esc to close").font(.caption).foregroundStyle(.secondary)
                Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 18, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(groups, id: \.0) { title, symbol, rows in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(title, systemImage: symbol).font(.headline).foregroundStyle(Theme.accent)
                        ForEach(rows, id: \.0) { key, what in
                            HStack(alignment: .firstTextBaseline) {
                                Text(key).font(.system(.callout, design: .rounded).weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                                    .frame(minWidth: 86, alignment: .leading)
                                Text(what).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Text("Right-click any photo for the same actions. Hover a thumbnail to pick, reject or rate it with the mouse.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: 860)
        .glassCard(22)
        .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
        .padding(24)
    }
}
