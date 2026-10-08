import SwiftUI
import AppKit
import CullerKit

/// Visual language: deep gradient backdrop, warm amber→coral accent, glass surfaces.
enum Theme {
    static let accentStart = Color(red: 1.00, green: 0.74, blue: 0.30)
    static let accentEnd = Color(red: 1.00, green: 0.42, blue: 0.45)
    static let accent = LinearGradient(colors: [accentStart, accentEnd], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let nsAccentStart = NSColor(red: 1.00, green: 0.74, blue: 0.30, alpha: 1)
    static let nsAccentEnd = NSColor(red: 1.00, green: 0.42, blue: 0.45, alpha: 1)

    /// Window backdrop behind the grid / loupe.
    static let backdrop = LinearGradient(
        colors: [Color(red: 0.07, green: 0.07, blue: 0.11), Color(red: 0.09, green: 0.08, blue: 0.14), Color(red: 0.05, green: 0.06, blue: 0.08)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Soft colored glows layered over the backdrop.
    struct Glow: View {
        var body: some View {
            ZStack {
                RadialGradient(colors: [Color(red: 0.36, green: 0.28, blue: 0.75).opacity(0.28), .clear], center: .topLeading, startRadius: 0, endRadius: 650)
                RadialGradient(colors: [Color(red: 1.0, green: 0.45, blue: 0.35).opacity(0.16), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 600)
            }
            .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Glass surface: Liquid Glass on macOS 26+, translucent material before.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    func glassCapsule(tint: Color? = nil) -> some View { glass(in: Capsule(), tint: tint) }

    func glassCard(_ radius: CGFloat = 14, tint: Color? = nil) -> some View {
        glass(in: RoundedRectangle(cornerRadius: radius, style: .continuous), tint: tint)
    }

    /// The app backdrop: gradient + glows.
    func appBackdrop() -> some View {
        background {
            ZStack {
                Theme.backdrop
                Theme.Glow()
            }
            .ignoresSafeArea()
        }
    }
}

/// Small rounded chip used in bars and overlays.
struct Chip: View {
    var systemImage: String?
    var text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.06), in: Capsule())
    }
}
