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
}

@MainActor
@Observable
final class ExportOptions {
    var settings: ExportSettings {
        didSet {
            if settings.format != oldValue.format {
                if !settings.format.bitDepths.contains(settings.bitDepth) { settings.bitDepth = settings.format.bitDepths.first ?? 8 }
                updateFileType()
            }
        }
    }
    /// a frame and watermark for exports, kept between them
    var extras = ExportExtras.load() {
        didSet { extras.save() }
    }
    weak var panel: NSSavePanel?
    let model: EditorModel

    init(model: EditorModel) {
        self.model = model
        var s = ExportSettings.load()
        // an HDR edit starts on HDR-capable settings
        if model.exportTarget.isHDR && !s.format.holdsHDR(bitDepth: s.bitDepth) {
            s.format = .jpegGainMap
            s.bitDepth = 8
        }
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
        let size = model.exportSize(longEdge: s.longEdge)
        VStack(spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    label("Format:")
                    Picker("Format", selection: $options.settings.format) {
                        ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    label("Colour Profile:")
                    Picker("Colour Profile", selection: $options.settings.profile) {
                        Text("From the edit (\(model.exportTarget.isHDR ? model.exportTarget.name : "SDR"))")
                            .tag(ExportProfile.fromEdit)
                        Divider()
                        ForEach(ExportProfile.sdr) { Text($0.title).tag($0) }
                        Divider()
                        ForEach(ExportProfile.hdr) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    label("Size:")
                    Picker("Size", selection: $options.settings.longEdge) {
                        ForEach(ExportSettings.sizes, id: \.self) { e in
                            Text(e == 0 ? "Original Size" : "Long edge \(e) px").tag(e)
                        }
                    }
                    .labelsHidden()
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
                if s.format.bitDepths.count > 1 {
                    GridRow {
                        label("Bit Depth:")
                        Picker("Bit Depth", selection: $options.settings.bitDepth) {
                            ForEach(s.format.bitDepths, id: \.self) { d in
                                Text(d == 32 ? "32-bit float" : "\(d)-bit").tag(d)
                            }
                        }
                        .labelsHidden()
                    }
                }
                if s.format == .jpegGainMap {
                    GridRow {
                        label("SDR Version:")
                        Picker("SDR Version", selection: $options.settings.sdrBase) {
                            ForEach(SDRBase.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
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

            VStack(spacing: 4) {
                Text("\(Int(size.width)) × \(Int(size.height)) px")
                    .foregroundStyle(.secondary)
                Text(s.format == .jpegGainMap ? s.sdrBase.detail : s.format.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if target.isHDR && !s.format.holdsHDR(bitDepth: s.bitDepth) {
                    Label("This edit is HDR. \(s.format.title) at \(s.bitDepth)-bit only covers standard brightness, so highlights brighter than white would be lost. Choose JPEG with HDR gain map, or HEIF or JPEG XL at 10-bit or more.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if s.format == .jpegGainMap && !target.isHDR {
                    Label("A gain map needs HDR: choose an HDR colour profile, or set one in the HDR card.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if s.format == .jpegGainMap && options.extras.any {
                    Label("Frames and watermarks aren't added to JPEG with HDR gain map yet; choose another format for them.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if target.isHDR && model.hdrLimitStops > 0 && s.format != .jpegGainMap {
                    Label("The HDR peak limit only applies to JPEG with HDR gain map. For \(s.format.title), lower your tone mapper's target white instead.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
    }

    static let positions = ["Top left", "Top", "Top right", "Left", "Centre", "Right", "Bottom left", "Bottom", "Bottom right"]

    private func label(_ text: String) -> some View {
        Text(text).gridColumnAlignment(.trailing)
    }
}
