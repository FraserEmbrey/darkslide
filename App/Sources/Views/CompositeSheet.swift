import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// New Composite: other photos blended into a base photo with one blend
/// mode, kept to the subject or the background if wanted, and a plain or
/// gradient backdrop behind the subject, previewed live and made into a new
/// photo. The photos it's made from aren't changed.
struct CompositeSheet: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: CompositeSettings
    @State private var preview: CGImage?
    @State private var failure: String?
    @State private var choosing = false

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.85)
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                } else if let failure {
                    Text(failure).foregroundStyle(.secondary).padding()
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("New Composite").font(.headline)
                        Text("Makes a new photo, next to the base. The photos it's made from aren't changed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        photos
                        if !draft.layers.isEmpty {
                            Divider()
                            blend
                        }
                        Divider()
                        backdrop
                    }
                    .padding(16)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Create") {
                        let d = draft
                        dismiss()
                        Task { await model.createComposite(d) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isActive)
                }
                .padding(16)
            }
            .frame(width: 320)
        }
        .frame(width: 1000, height: 660)
        // re-rendered a moment after each change, so a slider drag isn't a queue of renders
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            do {
                preview = try await model.compositePreview(draft)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
        }
        .sheet(isPresented: $choosing) {
            CompositePhotosSheet(exclude: [draft.base] + draft.layers.map(\.path)) { urls in
                draft.layers += urls.map { CompositeSettings.Layer(path: $0.path) }
            }
        }
    }

    @ViewBuilder private var photos: some View {
        HStack {
            Text("Photos").font(.subheadline.weight(.semibold))
            Spacer()
            Button { choosing = true } label: { Label("Add", systemImage: "plus") }
                .controlSize(.small)
        }
        HStack(spacing: 8) {
            PhotoThumb(url: draft.baseURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(draft.baseURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text("Base: sets the size and shape").font(.caption).foregroundStyle(.secondary)
            }
        }
        ForEach($draft.layers) { $layer in
            CompositeLayerRow(layer: $layer,
                              makeBase: {
                                  let old = draft.base
                                  draft.base = layer.path
                                  layer.path = old
                              },
                              remove: { draft.layers.removeAll { $0.id == layer.id } })
        }
        if draft.layers.isEmpty {
            Text("Add photos to blend in, or use the backdrop below on its own to cut the subject out.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var blend: some View {
        Picker("Blend", selection: $draft.blend) {
            ForEach(CompositeSettings.Blend.allCases) { Text($0.title).tag($0) }
        }
        Text(draft.blend.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text("Where")
        Picker("Where", selection: $draft.region) {
            ForEach(CompositeSettings.Region.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        if draft.region == .subject {
            Text("Inside the base photo's subject, as a silhouette double exposure. A white backdrop below gives the classic look.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var backdrop: some View {
        Picker("Backdrop", selection: $draft.backdrop) {
            ForEach(CompositeSettings.Backdrop.allCases) { Text($0.title).tag($0) }
        }
        if draft.backdrop != .none {
            HStack {
                ColorPicker(draft.backdrop == .gradient ? "From" : "Colour", selection: colour(\.colour), supportsOpacity: false)
                if draft.backdrop == .gradient {
                    Spacer()
                    ColorPicker("To", selection: colour(\.colour2), supportsOpacity: false)
                }
            }
            if draft.backdrop == .gradient {
                LabeledSlider(title: "Angle", value: $draft.angle, range: -180...180, format: "%.0f°")
            }
            Text("Everything but the base photo's subject, as macOS finds it, is replaced.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func colour(_ key: WritableKeyPath<CompositeSettings, [Double]>) -> Binding<Color> {
        Binding(
            get: {
                let c = draft[keyPath: key] + [0, 0, 0]
                return Color(.sRGB, red: c[0], green: c[1], blue: c[2])
            },
            set: { new in
                guard let ns = NSColor(new).usingColorSpace(.sRGB) else { return }
                draft[keyPath: key] = [Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent)]
            })
    }
}

/// a photo's library thumbnail, or its file icon
private struct PhotoThumb: View {
    @Environment(EditorModel.self) private var model
    let url: URL

    var body: some View {
        Group {
            if let image = model.library.thumbnails[url] {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .onAppear { model.library.requestThumbnail(for: url) }
    }
}

/// One photo in the composite: its thumbnail and name, opacity, and where it sits.
private struct CompositeLayerRow: View {
    @Binding var layer: CompositeSettings.Layer
    let makeBase: () -> Void
    let remove: () -> Void
    @State private var placing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PhotoThumb(url: layer.url)
                Text(layer.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button { placing.toggle() } label: { Image(systemName: "arrow.up.and.down.and.arrow.left.and.right") }
                    .buttonStyle(.borderless)
                    .help("Size and position")
                Menu {
                    Button("Make Base", action: makeBase)
                    Button("Remove", role: .destructive, action: remove)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
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
    /// paths already in the composite
    let exclude: [String]
    let add: ([URL]) -> Void
    @State private var chosen: [URL] = []

    private var items: [LibraryItem] { model.library.items.filter { !exclude.contains($0.url.path) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Photos").font(.headline)
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
                    add(chosen)
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
        panel.directoryURL = exclude.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        add(panel.urls.filter { !exclude.contains($0.path) })
        dismiss()
    }
}
