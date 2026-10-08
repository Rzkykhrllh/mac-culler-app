import SwiftUI
import CullerKit

/// Filter bar (spec §7). Every control writes to `session.filter`; filters combine with AND.
struct FilterBar: View {
    @Bindable var session: FolderSession
    @FocusState.Binding var focused: Bool
    @State private var showExif = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)

            HStack(spacing: 2) {
                flagToggle(.pick, "flag.fill", "Picks")
                flagToggle(.reject, "xmark.circle.fill", "Rejects")
                flagToggle(.none, "flag.slash", "Unflagged")
            }
            .focused($focused)

            Divider().frame(height: 18)

            Picker("", selection: $session.filter.ratingOperator) {
                ForEach(FilterState.RatingOperator.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 48)
            Picker("", selection: $session.filter.rating) {
                Text("Any ★").tag(Int?.none)
                ForEach(0...5, id: \.self) { r in Text(r == 0 ? "0 ★" : String(repeating: "★", count: r)).tag(Int?.some(r)) }
            }
            .labelsHidden()
            .frame(width: 90)

            Divider().frame(height: 18)

            HStack(spacing: 4) {
                ForEach(ColorLabel.allCases, id: \.self) { l in labelToggle(l) }
            }

            Divider().frame(height: 18)

            Menu {
                ForEach(FilterState.FileTypeFilter.allCases, id: \.self) { t in
                    Toggle(t.rawValue, isOn: setBinding(\.fileTypes, t))
                }
            } label: {
                Text(session.filter.fileTypes.isEmpty ? "All types" : session.filter.fileTypes.map(\.rawValue).sorted().joined(separator: ", "))
            }
            .fixedSize()

            Toggle(isOn: $session.filter.hasNote) { Image(systemName: "text.bubble") }
                .toggleStyle(.button)
                .help("Has note")

            Button {
                showExif.toggle()
            } label: {
                Label("EXIF", systemImage: session.filter.usesExif ? "camera.fill" : "camera")
            }
            .popover(isPresented: $showExif, arrowEdge: .bottom) { ExifFilterPopover(session: session) }

            Spacer()

            if let p = session.indexing {
                ProgressView(value: Double(p.done), total: Double(max(1, p.total)))
                    .frame(width: 80)
                Text("Indexing \(p.done)/\(p.total)").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(session.matchingCount) of \(session.items.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if session.filter.isActive {
                Button("Clear") { session.filter = FilterState() }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func flagToggle(_ f: Flag, _ symbol: String, _ help: String) -> some View {
        Toggle(isOn: setBinding(\.flags, f)) { Image(systemName: symbol) }
            .toggleStyle(.button)
            .help(help)
    }

    private func labelToggle(_ l: ColorLabel) -> some View {
        let on = session.filter.labels.contains(l)
        return Button {
            if on { session.filter.labels.remove(l) } else { session.filter.labels.insert(l) }
        } label: {
            ZStack {
                if l == .none {
                    Circle().strokeBorder(.secondary, lineWidth: 1)
                    Image(systemName: "slash.circle").font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Circle().fill(l.color)
                }
                if on { Circle().strokeBorder(Color.primary, lineWidth: 2) }
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .help(l == .none ? "No label" : "\(l.displayName) label")
    }

    private func setBinding<T: Hashable>(_ kp: WritableKeyPath<FilterState, Set<T>>, _ v: T) -> Binding<Bool> {
        Binding(get: { session.filter[keyPath: kp].contains(v) },
                set: { on in
                    if on { session.filter[keyPath: kp].insert(v) } else { session.filter[keyPath: kp].remove(v) }
                })
    }
}

/// Camera, lens, ISO / focal / aperture ranges and capture date range from the current folder.
struct ExifFilterPopover: View {
    @Bindable var session: FolderSession

    var body: some View {
        Form {
            if session.indexing != nil {
                Text("EXIF is still being indexed — lists fill in progressively.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Camera") { multiSelect(session.cameraNames, \.cameras) }
            Section("Lens") { multiSelect(session.lensNames, \.lenses) }
            Section("Ranges") {
                rangeRow("ISO", session.exifRange { $0.iso.map(Double.init) }, get: { session.filter.isoRange.map { Double($0.lowerBound)...Double($0.upperBound) } },
                         set: { session.filter.isoRange = $0.map { Int($0.lowerBound)...Int($0.upperBound) } })
                rangeRow("Focal length (mm)", session.exifRange { $0.focalLength }, get: { session.filter.focalRange }, set: { session.filter.focalRange = $0 })
                rangeRow("Aperture (f/)", session.exifRange { $0.aperture }, get: { session.filter.apertureRange }, set: { session.filter.apertureRange = $0 })
            }
            Section("Capture date") {
                if let r = session.exifRange({ $0.captureDate }) {
                    Toggle("Limit to range", isOn: Binding(get: { session.filter.dateRange != nil },
                                                          set: { session.filter.dateRange = $0 ? r : nil }))
                    if let dr = session.filter.dateRange {
                        DatePicker("From", selection: Binding(get: { dr.lowerBound }, set: { session.filter.dateRange = min($0, dr.upperBound)...dr.upperBound }))
                        DatePicker("To", selection: Binding(get: { dr.upperBound }, set: { session.filter.dateRange = dr.lowerBound...max($0, dr.lowerBound) }))
                    }
                } else {
                    Text("No capture dates yet").foregroundStyle(.secondary)
                }
            }
            Button("Clear EXIF filters") {
                session.filter.cameras = []
                session.filter.lenses = []
                session.filter.isoRange = nil
                session.filter.focalRange = nil
                session.filter.apertureRange = nil
                session.filter.dateRange = nil
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 520)
    }

    @ViewBuilder private func multiSelect(_ values: [String], _ kp: WritableKeyPath<FilterState, Set<String>>) -> some View {
        if values.isEmpty {
            Text("None found").foregroundStyle(.secondary)
        }
        ForEach(values, id: \.self) { v in
            Toggle(v, isOn: Binding(get: { session.filter[keyPath: kp].contains(v) },
                                    set: { on in if on { session.filter[keyPath: kp].insert(v) } else { session.filter[keyPath: kp].remove(v) } }))
        }
    }

    @ViewBuilder private func rangeRow(_ title: String, _ bounds: ClosedRange<Double>?, get: @escaping () -> ClosedRange<Double>?,
                                       set: @escaping (ClosedRange<Double>?) -> Void) -> some View {
        if let bounds, bounds.lowerBound < bounds.upperBound {
            VStack(alignment: .leading) {
                Toggle(title, isOn: Binding(get: { get() != nil }, set: { set($0 ? bounds : nil) }))
                if let r = get() {
                    HStack {
                        TextField("Min", value: Binding(get: { r.lowerBound }, set: { set(min($0, r.upperBound)...r.upperBound) }), format: .number)
                        Text("–")
                        TextField("Max", value: Binding(get: { r.upperBound }, set: { set(r.lowerBound...max($0, r.lowerBound)) }), format: .number)
                    }
                    .frame(width: 200)
                }
            }
        }
    }
}
