import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Composite: other photos blended into this one with one blend mode, kept to
/// the subject or the background if wanted, and a plain or gradient backdrop
/// behind the subject.
struct CompositeCard: View {
    @Environment(EditorModel.self) private var model
    @State private var isExpanded = true

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardTitle(title: "Composite", isExpanded: $isExpanded)
                Button { model.choosingCompositePhotos = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add photos to blend in")
            }
            if isExpanded {
                if !model.composite.isActive {
                    Text("Blend other photos into this one, as a multiple exposure, or cut the subject out onto a plain or gradient background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Add Photos…") { model.choosingCompositePhotos = true }
                        Spacer()
                        Button("Cut Out Subject") { model.composite.backdrop = .colour }
                    }
                } else {
                    if model.viewHDR {
                        HStack(alignment: .firstTextBaseline) {
                            Label("Composites show and export in SDR for now.", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("View SDR") { model.viewHDR = false }.controlSize(.small)
                        }
                    }
                    if !model.composite.layers.isEmpty { layers }
                    Divider()
                    backdrop
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var layers: some View {
        @Bindable var model = model
        Picker("Blend", selection: $model.composite.blend) {
            ForEach(CompositeSettings.Blend.allCases) { Text($0.title).tag($0) }
        }
        Text(model.composite.blend.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Picker("Where", selection: $model.composite.region) {
            ForEach(CompositeSettings.Region.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        if model.composite.region == .subject {
            Text("Inside the subject's outline, as a silhouette double exposure. A white backdrop below makes the classic look.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach($model.composite.layers) { $layer in
            CompositeLayerRow(layer: $layer) {
                model.composite.layers.removeAll { $0.id == layer.id }
            }
        }
    }

    @ViewBuilder private var backdrop: some View {
        @Bindable var model = model
        Picker("Backdrop", selection: $model.composite.backdrop) {
            ForEach(CompositeSettings.Backdrop.allCases) { Text($0.title).tag($0) }
        }
        if model.composite.backdrop != .none {
            HStack {
                ColorPicker(model.composite.backdrop == .gradient ? "From" : "Colour",
                            selection: colour(\.colour), supportsOpacity: false)
                if model.composite.backdrop == .gradient {
                    Spacer()
                    ColorPicker("To", selection: colour(\.colour2), supportsOpacity: false)
                }
            }
            if model.composite.backdrop == .gradient {
                LabeledSlider(title: "Angle", value: $model.composite.angle, range: -180...180, format: "%.0f°")
            }
            Text("Everything but the subject, as macOS finds it, is replaced.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if model.composite.isActive {
            Button("Remove Composite", role: .destructive) { model.composite = CompositeSettings() }
                .controlSize(.small)
        }
    }

    private func colour(_ key: WritableKeyPath<CompositeSettings, [Double]>) -> Binding<Color> {
        Binding(
            get: {
                let c = model.composite[keyPath: key] + [0, 0, 0]
                return Color(.sRGB, red: c[0], green: c[1], blue: c[2])
            },
            set: { new in
                guard let ns = NSColor(new).usingColorSpace(.sRGB) else { return }
                model.composite[keyPath: key] = [Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent)]
            })
    }
}

/// One photo in the composite: its thumbnail and name, opacity, and where it sits.
private struct CompositeLayerRow: View {
    @Environment(EditorModel.self) private var model
    @Binding var layer: CompositeSettings.Layer
    let remove: () -> Void
    @State private var placing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                thumbnail
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(layer.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button { placing.toggle() } label: { Image(systemName: "arrow.up.and.down.and.arrow.left.and.right") }
                    .buttonStyle(.borderless)
                    .help("Size and position")
                Button(action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove from the composite")
            }
            LabeledSlider(title: "Opacity", value: Binding(get: { layer.opacity * 100 }, set: { layer.opacity = $0 / 100 }),
                          range: 0...100, format: "%.0f%%")
            if placing {
                LabeledSlider(title: "Size", value: Binding(get: { layer.scale * 100 }, set: { layer.scale = $0 / 100 }),
                              range: 100...400, format: "%.0f%%")
                LabeledSlider(title: "Across", value: Binding(get: { layer.x * 100 }, set: { layer.x = $0 / 100 }),
                              range: -50...50, format: "%.0f%%")
                LabeledSlider(title: "Down", value: Binding(get: { layer.y * 100 }, set: { layer.y = $0 / 100 }),
                              range: -50...50, format: "%.0f%%")
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = model.library.thumbnails[layer.url] {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: layer.path)).resizable()
        }
    }
}

/// A slider with its name and value above it, as the module cards show them.
private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

/// Choosing photos to blend in: the current folder's photos, several at a
/// time, or any from Finder.
struct CompositePhotosSheet: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: [URL] = []

    private var items: [LibraryItem] { model.library.items.filter { $0.url != model.url } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Photos to the Composite").font(.headline)
            Text("Each is blended in with its own edit. Choose several to layer them.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(items) { item in
                        let on = chosen.contains(item.url)
                        Thumbnail(item: item, fill: true)
                            .frame(height: 90)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(on ? Color.accentColor : .clear, lineWidth: 3)
                            }
                            .overlay(alignment: .topTrailing) {
                                if on {
                                    Image(systemName: "checkmark.circle.fill")
                                        .symbolRenderingMode(.multicolor)
                                        .padding(4)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if on { chosen.removeAll { $0 == item.url } } else { chosen.append(item.url) }
                            }
                            .help(item.url.lastPathComponent)
                            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 280)
            HStack {
                Button("Other Photos…") { chooseInFinder() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count > 1 ? "Add \(chosen.count) Photos" : "Add") {
                    model.addCompositeLayers(chosen)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }

    private func chooseInFinder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .rawImage]
        panel.directoryURL = model.url?.deletingLastPathComponent()
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        model.addCompositeLayers(panel.urls)
        dismiss()
    }
}
