import SwiftUI
import CullerKit

/// First-launch guide (Help ▸ Getting Started reopens it). Short pages, each with a small visual.
struct GettingStartedView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Page {
        var symbol: String
        var title: String
        var text: String
        var visual: AnyView
    }

    private var pages: [Page] {
        [
            Page(symbol: "camera.aperture", title: "Welcome to \(AppConstants.appName)",
                 text: "A fast way to go through a shoot: look at every photo, mark the keepers, compare bursts, and move or rename the result. Your marks are saved into the photo files (XMP), so Lightroom sees ratings and color labels too. Nothing is deleted unless you ask: ⌘⌫ (or ⇧⌘⌫ for all rejects) moves photos to the Trash, and ⌘Z brings them back.",
                 visual: AnyView(MarkRow())),
            Page(symbol: "sidebar.left", title: "Folders and tabs",
                 text: "The sidebar works like Finder. Locked folders need permission once: click one and choose Grant Access — granting your home folder unlocks everything below it. Each tab (⌘T) keeps its own folder, selection and view; ⌘-click a folder to open it in a new tab.",
                 visual: AnyView(FolderVisual())),
            Page(symbol: "square.stack.3d.down.right", title: "RAW + JPG",
                 text: "Many cameras save a RAW and a JPG of every shot. RAW+JPG shows them as one photo and marks both files. Separate shows each file on its own: a broken-chain badge marks files that have a partner, and the partner of each selected photo gets a white dashed outline and a white “PAIR” badge. JPG and RAW show only one kind. True RAW renders the RAW without the camera's look; Camera Preview shows the camera's own rendering.",
                 visual: AnyView(ModesVisual())),
            Page(symbol: "keyboard", title: "Mark with the keyboard",
                 text: "P pick, X reject, U unflag, 0–5 stars, 6–9 color labels, M note. Add ⇧ to jump to the next photo, or turn on Caps Lock to always advance. A big confirmation shows what you set. Orange outline = the selected photo; a lighter tile with buttons = under the mouse. With the mouse: hover a thumbnail to pick, reject or rate it, or right-click. Prefer other keys? Settings ▸ Shortcuts (there is a left-hand preset).",
                 visual: AnyView(KeysVisual())),
            Page(symbol: "square.stack", title: "Stacks and compare",
                 text: "Stacks group photos: Bursts (shot within a second) or Similar (photos that look alike). S expands a stack. C compares photos side by side — drag from the filmstrip onto a side, Tab switches sides, Z zooms both to 100% together.",
                 visual: AnyView(StacksVisual())),
            Page(symbol: "scope", title: "Check focus",
                 text: "F paints the sharp edges (focus peaking). J shows blown highlights and black shadows. Y zooms to 100% on the eyes, face or animal. B jumps to the sharpest frame of a stack — marked with a green ◎. They are hints: you always decide.",
                 visual: AnyView(FocusVisual())),
            Page(symbol: "questionmark.circle", title: "Help is one key away",
                 text: "Press ? any time for every shortcut. Hover any button or badge to see what it does. You can reopen this guide from Help ▸ Getting Started.",
                 visual: AnyView(KeyCap("?", big: true))),
        ]
    }

    var body: some View {
        let p = pages[page]
        VStack(spacing: 18) {
            HStack {
                Spacer()
                Button("Skip") { dismiss() }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Image(systemName: p.symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 70, height: 70)
                .glass(in: Circle())
            Text(p.title).font(.title2.bold())
            p.visual
                .frame(height: 96)
            Text(p.text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
            Spacer(minLength: 0)
            HStack {
                Button("Back") { withAnimation { page -= 1 } }
                    .disabled(page == 0)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Spacer()
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle().fill(i == page ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.2)))
                            .frame(width: 7, height: 7)
                            .onTapGesture { withAnimation { page = i } }
                    }
                }
                Spacer()
                if page < pages.count - 1 {
                    Button("Next") { withAnimation { page += 1 } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Start Culling") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(width: 640, height: 560)
        .background(Theme.backdrop)
        .preferredColorScheme(.dark)
        .tint(Theme.accentStart)
    }
}

// MARK: - Small visuals

private struct KeyCap: View {
    let key: String
    var big = false
    init(_ key: String, big: Bool = false) { self.key = key; self.big = big }
    var body: some View {
        Text(key)
            .font(.system(size: big ? 34 : 15, weight: .semibold, design: .rounded))
            .frame(minWidth: big ? 64 : 30, minHeight: big ? 64 : 30)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: big ? 14 : 7).fill(Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: big ? 14 : 7).stroke(Color.white.opacity(0.15)))
    }
}

private struct MarkRow: View {
    var body: some View {
        HStack(spacing: 14) {
            Label("Pick", systemImage: "flag.fill")
            Label("Reject", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            HStack(spacing: 2) { ForEach(0..<4, id: \.self) { _ in Image(systemName: "star.fill") } }.foregroundStyle(.yellow)
            Circle().fill(.green).frame(width: 12, height: 12)
            Image(systemName: "text.bubble.fill")
        }
        .font(.title3)
        .padding(14)
        .glassCapsule()
    }
}

private struct FolderVisual: View {
    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Pictures", systemImage: "photo.on.rectangle")
                Label("Documents", systemImage: "doc").overlay(alignment: .trailing) { Image(systemName: "lock.fill").font(.caption2).offset(x: 18) }
                Label("Shoot 26:09", systemImage: "folder.fill").foregroundStyle(Theme.accent)
            }
            .font(.callout)
            HStack(spacing: 4) {
                ForEach(["Odaiba", "Klandasan"], id: \.self) { t in
                    Label(t, systemImage: "folder").font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(t == "Odaiba" ? 0.14 : 0.06)))
                }
                Image(systemName: "plus").font(.caption)
            }
        }
    }
}

private struct ModesVisual: View {
    @State private var mode: FileViewMode = .combined
    var body: some View {
        VStack(spacing: 10) {
            ChoiceBar(options: FileViewMode.allCases.map { .init(value: $0, title: $0.segmentTitle, help: Explain.fileView($0)) }, selection: $mode)
            Text(Explain.fileView(mode).components(separatedBy: " ⌥⌘").first ?? "")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
        }
    }
}

private struct KeysVisual: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach(["P", "X", "U", "1", "2", "3", "4", "5", "6", "M"], id: \.self) { KeyCap($0) }
            Text("+ ⇧").font(.callout).foregroundStyle(.secondary).padding(.leading, 6)
        }
    }
}

private struct StacksVisual: View {
    var body: some View {
        HStack(spacing: 22) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12 + Double(i) * 0.08))
                        .frame(width: 60, height: 44).offset(x: CGFloat(i) * 5, y: CGFloat(-i) * 5)
                }
                Text("12").font(.caption.bold()).padding(4).background(Capsule().fill(Theme.accentEnd)).offset(x: 30, y: 16)
            }
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.18)).frame(width: 70, height: 52).overlay(Text("L").font(.caption.bold()))
                RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 2).frame(width: 70, height: 52).overlay(Text("R").font(.caption.bold()))
            }
        }
    }
}

private struct FocusVisual: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach([("F", "Peaking"), ("J", "Clipping"), ("Y", "Eyes"), ("B", "Sharpest")], id: \.0) { k, t in
                VStack(spacing: 4) { KeyCap(k); Text(t).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
