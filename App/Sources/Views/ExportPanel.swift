import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// File › Export: the save panel with the export options underneath, as in
/// Pixelmator, Preview and Photos.
@MainActor
enum ExportPanel {
    static func present(model: EditorModel) {
        guard let photo = model.url,
              let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
        else { return }

        let options = ExportOptions(model: model)
        let panel = NSSavePanel()
        options.panel = panel
        panel.title = "Export"
        panel.prompt = "Export"
        panel.isExtensionHidden = false
        panel.canSelectHiddenExtension = false
        panel.nameFieldStringValue = photo.deletingPathExtension().lastPathComponent + "." + options.settings.format.fileExtension
        panel.directoryURL = model.lastExport?.deletingLastPathComponent() ?? photo.deletingLastPathComponent()
        options.updateFileType()

        let host = NSHostingView(rootView: ExportOptionsView(options: options).environment(model))
        host.sizingOptions = [.intrinsicContentSize]
        host.frame.size = host.fittingSize
        panel.accessoryView = host

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await model.export(options.settings, to: url) }
        }
    }

    /// File › Export Photos: several photos into a folder, each with its own
    /// edit, the options as for one.
    static func presentBatch(model: EditorModel, photos: [URL]) {
        guard photos.count > 1,
              let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
        else { return }
        let options = ExportOptions(model: model, batch: photos.count)
        let panel = NSOpenPanel()
        panel.title = "Export \(photos.count) Photos"
        panel.prompt = "Export"
        panel.message = "Choose a folder for the \(photos.count) photos."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = model.lastExport?.deletingLastPathComponent() ?? photos[0].deletingLastPathComponent()
        let host = NSHostingView(rootView: ExportOptionsView(options: options).environment(model))
        host.sizingOptions = [.intrinsicContentSize]
        host.frame.size = host.fittingSize
        panel.accessoryView = host
        panel.isAccessoryViewDisclosed = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            options.settings.save()
            Task {
                await model.exportPhotos(photos, settings: options.settings, to: folder, autoAdjust: options.autoAdjust,
                                         toPhotos: options.addToPhotos)
            }
        }
    }
}

@MainActor
@Observable
final class ExportOptions {
    var settings: ExportSettings {
        didSet {
            if settings.format != oldValue.format {
                if !settings.format.offeredBitDepths.contains(settings.bitDepth) { settings.bitDepth = settings.format.offeredBitDepths[0] }
                updateFileType()
            }
        }
    }
    /// a frame and watermark for exports, kept between them
    var extras = ExportExtras.load() {
        didSet { extras.save() }
    }
    /// whether the sheet's advanced options are open, kept between exports
    var showAdvanced = UserDefaults.standard.bool(forKey: "ExportShowAdvanced") {
        didSet {
            UserDefaults.standard.set(showAdvanced, forKey: "ExportShowAdvanced")
            if !showAdvanced && settings.format.bitDepthIsAdvanced { settings.bitDepth = 8 }
        }
    }
    weak var panel: NSSavePanel?
    let model: EditorModel
    /// how many photos, exporting several at once
    let batch: Int?
    /// exporting several: unedited raws get Auto first
    var autoAdjust = UserDefaults.standard.object(forKey: "BatchExportAuto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoAdjust, forKey: "BatchExportAuto") }
    }
    /// exporting several: the files go into Photos too
    var addToPhotos = UserDefaults.standard.bool(forKey: "BatchExportToPhotos") {
        didSet { UserDefaults.standard.set(addToPhotos, forKey: "BatchExportToPhotos") }
    }

    init(model: EditorModel, batch: Int? = nil) {
        self.model = model
        self.batch = batch
        var s = ExportSettings.load()
        // an HDR edit starts on the HDR kind of the last format, an SDR one on
        // the SDR kind; several photos keep the last format, as each is made
        // HDR for an HDR one
        if batch != nil {
        } else if model.exportTarget.isHDR {
            if s.format == .jpeg { s.format = .jpegGainMap } else if s.format == .heif { s.format = .heifGainMap }
        } else {
            if s.format == .jpegGainMap { s.format = .jpeg } else if s.format == .heifGainMap { s.format = .heif }
        }
        if !s.format.offeredBitDepths.contains(s.bitDepth) { s.bitDepth = s.format.offeredBitDepths[0] }
        // an advanced option only applies while it shows
        if s.format.bitDepthIsAdvanced && !UserDefaults.standard.bool(forKey: "ExportShowAdvanced") { s.bitDepth = 8 }
        settings = s
    }

    /// the panel's file type and the name's extension follow the format
    func updateFileType() {
        guard let panel else { return }
        let ext = settings.format.fileExtension
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + ext
    }

    /// the colour profile the export will actually use
    var effectiveTarget: HDRTarget {
        settings.profile == .fromEdit ? model.exportTarget : HDRTarget(darktableProfile: settings.profile.rawValue)
    }
}

struct ExportOptionsView: View {
    @Bindable var options: ExportOptions
    @Environment(EditorModel.self) private var model

    var body: some View {
        let s = options.settings
        let target = options.effectiveTarget
        let size = model.exportSize(longEdge: s.longEdge, enlarge: s.enlargement)
        VStack(spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    label("Preset:")
                    HStack {
                        Picker("Preset", selection: Binding(
                            get: { model.exportPresets.first { $0.settings == options.settings && $0.extras == options.extras }?.id },
                            set: { id in
                                guard let p = model.exportPresets.first(where: { $0.id == id }) else { return }
                                options.settings = p.settings
                                options.extras = p.extras
                            })) {
                            Text("Custom").tag(UUID?.none)
                            Divider()
                            ForEach(model.exportPresets) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button("Save as Preset…") { saveAsPreset() }
                    }
                }
                GridRow {
                    label("Format:")
                    Picker("Format", selection: $options.settings.format) {
                        Section("HDR") {
                            ForEach(ExportFormat.hdrFormats) { f in
                                Text(f.title).tag(f).selectionDisabled(options.batch == nil && !model.exportTarget.isHDR)
                            }
                        }
                        Section("SDR") {
                            ForEach(ExportFormat.sdrFormats) { Text($0.title).tag($0) }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help(options.batch != nil || model.exportTarget.isHDR ? "" : "HDR formats need an HDR edit: turn on HDR in the HDR card")
                }
                if s.format.usesQuality {
                    GridRow {
                        label("Quality:")
                        HStack {
                            Slider(value: Binding(get: { Double(options.settings.quality) },
                                                  set: { options.settings.quality = Int($0.rounded()) }),
                                   in: 50...100)
                            Text("\(s.quality)").monospacedDigit().frame(width: 30, alignment: .trailing)
                        }
                    }
                }
                GridRow {
                    label("Size:")
                    // enlargements as negative tags: -2 is 2×
                    Picker("Size", selection: Binding(
                        get: { options.settings.enlargement.map { -$0 } ?? options.settings.longEdge },
                        set: { v in
                            options.settings.enlarge = v < 0 ? -v : nil
                            options.settings.longEdge = max(v, 0)
                        })) {
                        ForEach(ExportSettings.sizes, id: \.self) { e in
                            Text(e == 0 ? "Original Size" : "Long edge \(e) px").tag(e)
                        }
                        if Upscaler.isAvailable {
                            Section("Enlarged") {
                                ForEach(Upscaler.factors, id: \.self) { f in
                                    Text("\(f)× Original Size").tag(-f)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if !s.format.isGainMap {
                    GridRow {
                        label("Colour Profile:")
                        Picker("Colour Profile", selection: $options.settings.profile) {
                            ForEach(ExportProfile.offered) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                if s.format.offeredBitDepths.count > 1 && !s.format.bitDepthIsAdvanced {
                    GridRow {
                        label("Bit Depth:")
                        bitDepthPicker
                    }
                }
                GridRow {
                    label("Frame:")
                    HStack {
                        Toggle("Add a frame", isOn: $options.extras.frameOn)
                        if options.extras.frameOn {
                            Picker("Shape", selection: $options.extras.frameShape) {
                                ForEach(ExportExtras.Shape.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                            Picker("Colour", selection: $options.extras.frameTone) {
                                ForEach(ExportExtras.Tone.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                }
                if options.extras.frameOn {
                    GridRow {
                        label("Width:")
                        HStack {
                            Slider(value: $options.extras.frameWidth, in: 1...15, step: 0.5)
                            Text("\(options.extras.frameWidth.formatted(.number.precision(.fractionLength(0...1))))%")
                                .monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                GridRow {
                    label("Watermark:")
                    HStack {
                        Toggle("Add text", isOn: $options.extras.watermarkOn)
                        if options.extras.watermarkOn {
                            TextField("Text", text: $options.extras.watermarkText)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                if options.extras.watermarkOn {
                    GridRow {
                        label("Position:")
                        HStack {
                            Picker("Position", selection: $options.extras.watermarkPosition) {
                                ForEach(0..<9) { Text(Self.positions[$0]).tag($0) }
                            }
                            .labelsHidden().fixedSize()
                            if !options.extras.frameOn {
                                Picker("Colour", selection: $options.extras.watermarkTone) {
                                    ForEach(ExportExtras.Tone.allCases) { Text($0.title).tag($0) }
                                }
                                .labelsHidden().fixedSize()
                            }
                        }
                    }
                    if options.extras.frameOn {
                        GridRow {
                            Text("")
                            Text("With a frame, the text sits in the bottom border, sized to it, in the frame's other colour.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        GridRow {
                            label("Size:")
                            HStack {
                                Slider(value: $options.extras.watermarkSize, in: 5...60, step: 1)
                                Text("\(Int(options.extras.watermarkSize))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                    GridRow {
                        label("Opacity:")
                        HStack {
                            Slider(value: $options.extras.watermarkOpacity, in: 10...100, step: 5)
                            Text("\(Int(options.extras.watermarkOpacity))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(width: 420)

            if s.format.bitDepthIsAdvanced {
                DisclosureGroup("Advanced", isExpanded: $options.showAdvanced) {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        GridRow {
                            label("Bit Depth:")
                            bitDepthPicker
                        }
                        GridRow {
                            Text("")
                            Text("10-bit keeps gradients smoother if you'll edit the file again. About twice the size, and some apps only read 8-bit.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 6)
                }
                .frame(width: 420)
            }

            VStack(spacing: 4) {
                Text(options.batch.map { n in
                    "\(n) photos" + (s.format.isGainMap ? ". Each is made HDR (HLG P3) for the export, and keeps that." : "")
                } ?? "\(Int(size.width)) × \(Int(size.height)) px" + (s.format.bitDepthIsAdvanced && s.bitDepth > 8 ? ", \(s.bitDepth)-bit" : ""))
                    .foregroundStyle(.secondary)
                Text(s.format.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if s.enlargement != nil {
                    Text("Enlarged with Apple's super resolution, which sharpens edges without inventing detail. Slow on large photos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if model.exportTarget.isHDR && !s.format.isGainMap {
                    Text("Standard brightness only: highlights brighter than white are brought within it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
            if options.batch != nil {
                Toggle("Auto-adjust raws that haven't been edited", isOn: $options.autoAdjust)
                    .help("Applies Auto (camera style, exposure, tone mapping) to each raw without an edit before exporting it; the edit is saved with the photo")
                Toggle("Add to Apple Photos", isOn: $options.addToPhotos)
                    .help("Adds each exported file to Photos, in an album named after the photos' folder; the files stay in the export folder too")
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
    }

    static let positions = ["Top left", "Top", "Top right", "Left", "Centre", "Right", "Bottom left", "Bottom", "Bottom right"]

    private var bitDepthPicker: some View {
        Picker("Bit Depth", selection: $options.settings.bitDepth) {
            ForEach(options.settings.format.offeredBitDepths, id: \.self) { d in
                Text(d == 32 ? "32-bit float" : "\(d)-bit").tag(d)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    /// the options as they are, named, for File › Export with Preset
    private func saveAsPreset() {
        let alert = NSAlert()
        alert.messageText = "Save Export Preset"
        alert.informativeText = "Its files go in a folder called Exports beside the photos. Change that in File › Export with Preset › Manage Presets."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        model.exportPresets.append(ExportPreset(name: name.isEmpty ? "\(options.settings.format.title) Preset" : name,
                                                settings: options.settings, extras: options.extras,
                                                autoAdjust: options.autoAdjust, addToPhotos: options.addToPhotos))
    }

    private func label(_ text: String) -> some View {
        Text(text).gridColumnAlignment(.trailing)
    }
}
