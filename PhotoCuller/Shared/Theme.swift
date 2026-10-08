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

    /// Window backdrop: neutral graphite, so it never tints how photo colors are perceived.
    static let backdrop = LinearGradient(
        colors: [Color(white: 0.115), Color(white: 0.085), Color(white: 0.06)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Very soft warm light (matches the amber accent) layered over the backdrop.
    struct Glow: View {
        var body: some View {
            ZStack {
                RadialGradient(colors: [Color(red: 1.0, green: 0.72, blue: 0.35).opacity(0.07), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
                RadialGradient(colors: [Color(red: 1.0, green: 0.55, blue: 0.40).opacity(0.05), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 650)
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
            Text(text).monospacedDigit().lineLimit(1)
        }
        .fixedSize()
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.06), in: Capsule())
    }
}
