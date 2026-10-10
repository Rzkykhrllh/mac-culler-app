import SwiftUI

/// Shown on the photo while it is zoomed: the zoom level, and a click back to fit (⌘0, or Z / Space).
struct FitButton: View {
    let hub: ViewportHub

    var body: some View {
        if let p = hub.zoomPercent {
            Button { withAnimation(.smooth(duration: 0.2)) { hub.fitAll() } } label: {
                HStack(spacing: 6) {
                    Text("\(p)%").monospacedDigit().foregroundStyle(.secondary)
                    Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassCapsule()
            }
            .buttonStyle(.plain)
            .help("Back to the whole photo (⌘0 — or Z / Space)")
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}
