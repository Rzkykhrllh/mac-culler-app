import SwiftUI
import CullerKit

/// Always-visible marks for the current item + minimal EXIF (spec §6.4).
struct StatusOverlay: View {
    let session: FolderSession
    let item: PhotoItem
    var minimal = false
    var showsPosition = true

    var body: some View {
        // Narrow slots (compare with 3–4 photos) drop the details instead of wrapping over the photo.
        ViewThatFits(in: .horizontal) {
            card(detail: 2)
            card(detail: 1)
            card(detail: 0)
        }
    }

    private func card(detail: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            MarksView(metadata: item.metadata, writeState: item.writeState)
            if !minimal, detail >= 1 {
                HStack(spacing: 10) {
                    Text(item.fileName).fontWeight(.semibold).lineLimit(1)
                    Text(kindBadge).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.white.opacity(0.15), in: Capsule())
                    if showsPosition, let i = session.currentIndex, item.id == session.currentID {
                        Text("\(i + 1) / \(session.display.count)").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .fixedSize()
            }
            if detail >= 2, let e = item.exif {
                Text(ExifFormat.summary(e)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
            }
            if detail >= 2, item.metadata.hasNote, !minimal {
                Text(item.metadata.note).font(.caption).lineLimit(2).frame(maxWidth: 360, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassCard(14)
        .foregroundStyle(.white)
        .fixedSize(horizontal: true, vertical: false)
    }
}

extension StatusOverlay {
    /// "RAW · True RAW", "RAW · Camera preview", "JPG", "RAW+JPG".
    var kindBadge: String {
        let f = item.files
        if f.isPair { return f.badge }
        guard f.primary.kind.isRaw else { return f.primary.kind.badge }
        return f.primary.kind.badge + (session.app.settings.rawRendering == .rendered ? " · True RAW" : " · Camera preview")
    }
}

/// Flag, stars, label, note and save state.
struct MarksView: View {
    let metadata: PhotoMetadata
    var writeState: PhotoItem.WriteState = .saved

    var body: some View {
        HStack(spacing: 8) {
            switch metadata.flag {
            case .pick: Image(systemName: "flag.fill").foregroundStyle(.white).help("Pick")
            case .reject: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Reject")
            case .none: Image(systemName: "flag").foregroundStyle(.white.opacity(0.35)).help("Unflagged")
            }
            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { i in
                    Image(systemName: i <= metadata.rating ? "star.fill" : "star")
                        .foregroundStyle(i <= metadata.rating ? Color.yellow : Color.white.opacity(0.3))
                }
            }
            .font(.caption)
            if metadata.label != .none {
                Circle().fill(metadata.label.color).frame(width: 10, height: 10).help("\(metadata.label.displayName) label")
            }
            if metadata.hasNote { Image(systemName: "text.bubble.fill").font(.caption).help("Has note") }
            switch writeState {
            case .saved: EmptyView()
            case .pending: Image(systemName: "arrow.triangle.2.circlepath").font(.caption2).foregroundStyle(.secondary).help("Saving…")
            case .failed(let msg): Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).help("Not saved: \(msg)")
            }
        }
    }
}

extension ColorLabel {
    var color: Color {
        switch self {
        case .none: return .clear
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }
}
