import SwiftUI
import CullerKit

/// Settings window (spec §12).
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
            CompareSettings().tabItem { Label("Compare", systemImage: "rectangle.split.2x1") }
            CacheSettings().tabItem { Label("Cache", systemImage: "internaldrive") }
            RenamePresetsSettings().tabItem { Label("Rename", systemImage: "pencil") }
        }
        .frame(width: 540, height: 420)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var s = app.settings
        Form {
            Picker("RAW+JPEG", selection: Binding(get: { s.fileViewMode }, set: { m in
                if let session = app.session { session.setFileView(m) } else { s.fileViewMode = m }
            })) {
                ForEach(FileViewMode.allCases) { Text($0.title).tag($0) }
            }
            Text("“As One Photo” pairs files with the same name; marks apply to both. The other modes show each file on its own so RAW and JPEG can be marked separately.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Burst threshold") {
                HStack {
                    Slider(value: $s.burstThreshold, in: 0.1...5, step: 0.1)
                    Text(String(format: "%.1f s", s.burstThreshold)).monospacedDigit().frame(width: 44)
                }
            }
            .onChange(of: s.burstThreshold) {
                app.session?.rebuildStacks()
                app.session?.rebuildDisplay()
            }
            Picker("Stacks", selection: Binding(get: { app.stackChoice }, set: { app.setStackChoice($0) })) {
                ForEach(StackChoice.allCases) { Text($0.title).tag($0) }
            }
            LabeledContent("Similarity") {
                HStack {
                    Text("Strict").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { s.similarityThreshold }, set: { app.setSimilarityThreshold($0) }), in: 0.15...0.9)
                    Text("Loose").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Include subfolders by default", isOn: $s.includeSubfoldersByDefault)
            Stepper("Warn when a subfolder scan exceeds \(s.subfolderWarningThreshold.formatted()) photos",
                    value: $s.subfolderWarningThreshold, in: 500...100_000, step: 500)
            Toggle("Sync color labels to Finder tags", isOn: $s.syncFinderTags)
                .onChange(of: s.syncFinderTags) { app.applyWriteOptions() }
            Text("Only the app’s own color tags (Red, Yellow, Green, Blue, Purple) are added or removed; other tags are never touched.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct AppearanceSettings: View {
    @Bindable private var theme = ThemeStore.shared

    var body: some View {
        Form {
            Section("Accent color") {
                HStack(spacing: 14) {
                    ForEach(AccentPalette.allCases) { p in
                        let (a, b) = p.colors
                        Button { theme.accent = p } label: {
                            VStack(spacing: 5) {
                                Circle()
                                    .fill(LinearGradient(colors: [Color(nsColor: a), Color(nsColor: b)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(Color.white, lineWidth: theme.accent == p ? 2 : 0).padding(-4))
                                Text(p.title).font(.caption).foregroundStyle(theme.accent == p ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("\(p.title) accent: selection outlines, active buttons, highlights")
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Background") {
                HStack(spacing: 10) {
                    ForEach(BackdropStyle.allCases) { b in
                        Button { theme.backdrop = b } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(LinearGradient(colors: b.stops, startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(height: 44)
                                    .overlay(alignment: .bottomLeading) {
                                        Capsule().fill(Theme.accent).frame(width: 26, height: 6).padding(8)
                                    }
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.backdrop == b ? Color.white : Color.white.opacity(0.12), lineWidth: theme.backdrop == b ? 2 : 1))
                                Text(b.title).font(.caption.weight(.medium))
                            }
                        }
                        .buttonStyle(.plain)
                        .help(b.subtitle)
                    }
                }
                .padding(.vertical, 4)
                Text(theme.backdrop.subtitle).font(.caption).foregroundStyle(.secondary)
                Toggle("Soft glow in the window corners", isOn: $theme.glow)
            }
            Section {
                HStack {
                    Text("The interface stays dark on purpose: a bright surround changes how exposure and color look in photos.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { theme.reset() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CompareSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var s = app.settings
        Form {
            Picker("Default slot count", selection: $s.compareSlotCount) {
                Text("2").tag(2)
                Text("3").tag(3)
                Text("4 (2×2)").tag(4)
            }
            Toggle("Pin current best mode", isOn: $s.comparePinBest)
            Toggle("Sync zoom and pan by default", isOn: $s.compareSyncDefault)
            Text("Hold ⌥ while panning to move only the image under the pointer.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct CacheSettings: View {
    @Environment(AppModel.self) private var app
    @State private var usage: Int64?

    var body: some View {
        @Bindable var s = app.settings
        Form {
            LabeledContent("Thumbnail cache limit") {
                HStack {
                    Slider(value: $s.cacheLimitGB, in: 0.5...50, step: 0.5)
                    Text(String(format: "%.1f GB", s.cacheLimitGB)).monospacedDigit().frame(width: 60)
                }
            }
            .onChange(of: s.cacheLimitGB) {
                let bytes = s.cacheLimitBytes
                let disk = app.pipeline.diskCache
                Task.detached(priority: .utility) { disk?.setLimit(bytes) }
            }
            LabeledContent("Currently used") {
                Text(usage.map { ExifFormat.bytes($0) } ?? "…")
            }
            Button("Clear Cache") {
                app.clearCaches()
                usage = 0
            }
            Text("The cache and index only speed things up; your marks live in the photo files and XMP sidecars.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task {
            let disk = app.pipeline.diskCache
            usage = await Task.detached(priority: .utility) { disk?.currentSize() ?? 0 }.value
        }
    }
}

private struct RenamePresetsSettings: View {
    @Environment(AppModel.self) private var app
    @State private var selection: RenamePreset.ID?

    var body: some View {
        @Bindable var s = app.settings
        VStack(alignment: .leading) {
            List(selection: $selection) {
                ForEach($s.renamePresets) { $p in
                    HStack {
                        TextField("Name", text: $p.name).frame(width: 160)
                        TextField("Template", text: $p.template).font(.body.monospaced())
                    }
                    .tag(p.id)
                }
                .onMove { s.renamePresets.move(fromOffsets: $0, toOffset: $1) }
            }
            HStack {
                Button {
                    s.renamePresets.append(RenamePreset(name: "New preset", template: "{original}"))
                } label: { Image(systemName: "plus") }
                Button {
                    s.renamePresets.removeAll { $0.id == selection }
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                Spacer()
                Text("Tokens: " + RenameTemplate.availableTokens.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
