import SwiftUI
import CullerKit

/// App ▸ About: version and credits.
struct AboutView: View {
    static let website = URL(string: "https://dev.byairu.com")!
    static let github = URL(string: "https://github.com/Rzkykhrllh")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "–"
        let b = info?["CFBundleVersion"] as? String ?? "–"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .shadow(color: Theme.accentEnd.opacity(0.35), radius: 18)
            VStack(spacing: 3) {
                Text(AppConstants.appName).font(.title.bold())
                Text(version).font(.caption).foregroundStyle(.secondary)
            }
            Text("A fast, keyboard-first photo culler for macOS.")
                .font(.callout).foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("MADE BY").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.tertiary)
                Text("Rizky Khairullah").font(.title3.weight(.semibold))
                HStack(spacing: 10) {
                    Link(destination: Self.website) {
                        Label("dev.byairu.com", systemImage: "globe")
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .help(Self.website.absoluteString)
                    Link(destination: Self.github) {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Color.white.opacity(0.1), in: Capsule())
                    }
                    .help(Self.github.absoluteString)
                }
                .font(.callout.weight(.medium))
                .buttonStyle(.plain)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08)))

            VStack(spacing: 2) {
                Text("Built with Swift, SwiftUI, ImageIO, Core Image and Vision.")
                Text("Uses GRDB.swift (MIT License) by Gwendal Roué.")
            }
            .font(.caption2).foregroundStyle(.tertiary)
            Text("© 2026 Rizky Khairullah").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 400)
        .background(Theme.backdrop)
        .preferredColorScheme(.dark)
        .tint(Theme.accentStart)
    }
}
