import AppKit
import SwiftUI

/// File › Export with Preset › Manage Presets: each preset's name and where
/// its files go. Its options are set in the export sheet, then saved from there.
struct ExportPresetsSheet: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Presets").font(.headline)
            if model.exportPresets.isEmpty {
                Text("Save one from the export sheet with Save as Preset.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($model.exportPresets) { $preset in
                        PresetRow(preset: $preset) { model.exportPresets.removeAll { $0.id == preset.id } }
                    }
                }
            }
            .frame(maxHeight: 420)
            Text("A preset's format, size, frame and watermark come from the export sheet: set them there and choose Save as Preset.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

private struct PresetRow: View {
    @Binding var preset: ExportPreset
    let delete: () -> Void

    private enum Where: Hashable { case beside, folder, ask }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: $preset.name)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete this preset")
            }
            Text(summary).font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Save to", selection: Binding(get: { kind }, set: { setKind($0) })) {
                    Text("A folder beside the photos").tag(Where.beside)
                    Text("A chosen folder").tag(Where.folder)
                    Text("Ask each time").tag(Where.ask)
                }
                .fixedSize()
                switch preset.destination {
                case .subfolder(let name):
                    TextField("Folder name", text: Binding(get: { name }, set: { preset.destination = .subfolder($0.isEmpty ? "Exports" : $0) }))
                        .textFieldStyle(.roundedBorder)
                case .folder(let path):
                    Button(URL(fileURLWithPath: path).lastPathComponent + "…") { chooseFolder() }
                        .help(path)
                case .ask:
                    EmptyView()
                }
            }
            Toggle("Auto unedited raws first", isOn: $preset.autoAdjust)
            Toggle("Add to Photos too", isOn: $preset.addToPhotos)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var summary: String {
        let s = preset.settings
        var parts = [s.format.title]
        if let e = s.enlargement { parts.append("\(e)× original size") }
        else { parts.append(s.longEdge == 0 ? "original size" : "long edge \(s.longEdge) px") }
        if s.format.usesQuality { parts.append("quality \(s.quality)") }
        if !s.format.isGainMap { parts.append(s.profile.title) }
        if preset.extras.frameOn { parts.append("frame") }
        if preset.extras.watermarkOn { parts.append("watermark") }
        return parts.joined(separator: ", ")
    }

    private var kind: Where {
        switch preset.destination {
        case .subfolder: .beside
        case .folder: .folder
        case .ask: .ask
        }
    }

    private func setKind(_ k: Where) {
        switch k {
        case .beside: preset.destination = .subfolder("Exports")
        case .ask: preset.destination = .ask
        case .folder: chooseFolder()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preset.destination = .folder(url.path)
    }
}
