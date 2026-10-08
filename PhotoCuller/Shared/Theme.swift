import SwiftUI
import AppKit
import CullerKit

/// Accent color pairs (gradient start → end). Picked in Settings ▸ Appearance.
enum AccentPalette: String, CaseIterable, Identifiable {
    case amber, ocean, mint, lime, rose, violet, mono
    var id: String { rawValue }

    var title: String {
        switch self {
        case .amber: "Amber"
        case .ocean: "Ocean"
        case .mint: "Mint"
        case .lime: "Lime"
        case .rose: "Rose"
        case .violet: "Violet"
        case .mono: "Mono"
        }
    }

    var colors: (NSColor, NSColor) {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(red: r, green: g, blue: b, alpha: 1) }
        switch self {
        case .amber: return (c(1.00, 0.74, 0.30), c(1.00, 0.42, 0.45))
        case .ocean: return (c(0.38, 0.80, 1.00), c(0.25, 0.47, 1.00))
        case .mint: return (c(0.45, 0.95, 0.78), c(0.12, 0.72, 0.70))
        case .lime: return (c(0.85, 0.95, 0.35), c(0.38, 0.82, 0.38))
        case .rose: return (c(1.00, 0.60, 0.75), c(0.95, 0.30, 0.55))
        case .violet: return (c(0.78, 0.62, 1.00), c(0.52, 0.40, 0.98))
        case .mono: return (c(0.96, 0.96, 0.96), c(0.68, 0.70, 0.73))
        }
    }
}

/// Window background. All stay dark and low-saturation so they don't change how photo colors look.
enum BackdropStyle: String, CaseIterable, Identifiable {
    case graphite, midnight, slate, warm
    var id: String { rawValue }

    var title: String {
        switch self {
        case .graphite: "Graphite"
        case .midnight: "Midnight"
        case .slate: "Slate"
        case .warm: "Warm"
        }
    }

    var subtitle: String {
        switch self {
        case .graphite: "Neutral grey — best for judging color"
        case .midnight: "Near black, maximum contrast"
        case .slate: "Cool blue-grey"
        case .warm: "Soft brown-grey"
        }
    }

    /// Top-left → bottom-right gradient stops.
    var stops: [Color] {
        switch self {
        case .graphite: [Color(white: 0.115), Color(white: 0.085), Color(white: 0.06)]
        case .midnight: [Color(white: 0.05), Color(white: 0.03), Color(white: 0.015)]
        case .slate: [Color(red: 0.10, green: 0.115, blue: 0.14), Color(red: 0.07, green: 0.08, blue: 0.10), Color(red: 0.045, green: 0.05, blue: 0.065)]
        case .warm: [Color(red: 0.135, green: 0.115, blue: 0.10), Color(red: 0.095, green: 0.082, blue: 0.072), Color(red: 0.065, green: 0.056, blue: 0.05)]
        }
    }
}

/// The chosen look, saved in UserDefaults. SwiftUI views re-render through Observation;
/// AppKit-drawn views (thumbnails) listen for `.themeChanged`.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()
    private static let accentKey = "theme.accent", backdropKey = "theme.backdrop", glowKey = "theme.glow"

    var accent: AccentPalette { didSet { save(); NotificationCenter.default.post(name: .themeChanged, object: nil) } }
    var backdrop: BackdropStyle { didSet { save() } }
    /// Soft accent-colored light in the corners of the window.
    var glow: Bool { didSet { save() } }

    private init() {
        let d = UserDefaults.standard
        accent = d.string(forKey: Self.accentKey).flatMap(AccentPalette.init) ?? .amber
        backdrop = d.string(forKey: Self.backdropKey).flatMap(BackdropStyle.init) ?? .graphite
        glow = d.object(forKey: Self.glowKey) as? Bool ?? true
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(accent.rawValue, forKey: Self.accentKey)
        d.set(backdrop.rawValue, forKey: Self.backdropKey)
        d.set(glow, forKey: Self.glowKey)
    }

    func reset() { accent = .amber; backdrop = .graphite; glow = true }
}

extension Notification.Name {
    static let themeChanged = Notification.Name("PhotoCuller.themeChanged")
}

/// Visual language: deep gradient backdrop, an accent gradient (user-selectable), glass surfaces.
enum Theme {
    static var nsAccentStart: NSColor { ThemeStore.shared.accent.colors.0 }
    static var nsAccentEnd: NSColor { ThemeStore.shared.accent.colors.1 }
    static var accentStart: Color { Color(nsColor: nsAccentStart) }
    static var accentEnd: Color { Color(nsColor: nsAccentEnd) }
    static var accent: LinearGradient { LinearGradient(colors: [accentStart, accentEnd], startPoint: .topLeading, endPoint: .bottomTrailing) }

    /// Window backdrop (Settings ▸ Appearance). Graphite by default, so it never tints how photo colors are perceived.
    static var backdrop: LinearGradient {
        LinearGradient(colors: ThemeStore.shared.backdrop.stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Very soft light in the accent color, layered over the backdrop.
    struct Glow: View {
        var body: some View {
            if ThemeStore.shared.glow {
                ZStack {
                    RadialGradient(colors: [Theme.accentStart.opacity(0.07), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
                    RadialGradient(colors: [Theme.accentEnd.opacity(0.05), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 650)
                }
                .allowsHitTesting(false)
            }
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
