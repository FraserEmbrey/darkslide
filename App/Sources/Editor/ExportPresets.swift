import AppKit
import Foundation

/// A named set of export options, and where its files go, so a whole shoot
/// exports in one go: File › Export with Preset, as Lightroom's export
/// presets and Aperture's export presets did.
struct ExportPreset: Codable, Identifiable, Hashable {
    enum Destination: Codable, Hashable {
        /// a folder of this name beside the photos ("Exports")
        case subfolder(String)
        /// always this folder
        case folder(String)
        /// asked each time
        case ask
    }

    var id = UUID()
    var name: String
    var settings: ExportSettings
    var extras = ExportExtras()
    var destination = Destination.subfolder("Exports")
    /// unedited raws get Auto first, as the batch export option
    var autoAdjust = true
    var addToPhotos = false

    static func == (a: ExportPreset, b: ExportPreset) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var destinationTitle: String {
        switch destination {
        case .subfolder(let name): "a folder called \(name) beside the photos"
        case .folder(let path): URL(fileURLWithPath: path).lastPathComponent
        case .ask: "asked each time"
        }
    }

    // MARK: Stored

    private static let key = "ExportPresets"

    /// the presets, starting with a few useful ones
    static func load() -> [ExportPreset] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let presets = try? JSONDecoder().decode([ExportPreset].self, from: data) else { return starters }
        return presets
    }

    static func save(_ presets: [ExportPreset]) {
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: key) }
    }

    static let starters: [ExportPreset] = [
        ExportPreset(name: "Full Size JPEG", settings: ExportSettings(format: .jpeg, profile: .sRGB, quality: 90)),
        ExportPreset(name: "Web JPEG, 2048 px", settings: ExportSettings(format: .jpeg, profile: .sRGB, quality: 85, longEdge: 2048)),
        ExportPreset(name: "HDR HEIC", settings: ExportSettings(format: .heifGainMap, profile: .fromEdit, quality: 85)),
    ]
}

extension EditorModel {
    /// what Export with Preset exports: the photos selected in the library,
    /// or all those showing when one or none is; in the editor, the photo open
    var photosForPresetExport: [URL] {
        guard showingLibrary else { return url.map { [$0] } ?? [] }
        let selected = library.selectedInOrder
        return (selected.count > 1 ? selected : library.items.map(\.url)).filter { PhotosLibrary.assetID($0) == nil }
    }

    /// Exports the photos with a preset: its options, frame and watermark,
    /// into its destination. Several go through the batch export one by one.
    func export(_ photos: [URL], with preset: ExportPreset) {
        Task { await exportNow(photos, with: preset) }
    }

    /// As export(_:with:), finishing when the files are written; returns them
    /// (for Shortcuts), or nil when nothing was exported.
    @discardableResult
    func exportNow(_ photos: [URL], with preset: ExportPreset) async -> [URL]? {
        guard !photos.isEmpty, batchExport == nil else { return nil }
        let folder: URL
        switch preset.destination {
        case .subfolder(let name):
            // beside the first photo: a shoot is usually one folder
            folder = photos[0].deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        case .folder(let path):
            folder = URL(fileURLWithPath: path, isDirectory: true)
        case .ask:
            let panel = NSOpenPanel()
            panel.title = "Export with \(preset.name)"
            panel.prompt = "Export"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.directoryURL = photos[0].deletingLastPathComponent()
            guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
            folder = chosen
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Couldn't make the folder for the exports: \(error.localizedDescription)"
            return nil
        }
        // the export reads the frame and watermark from the saved ones
        let extras = ExportExtras.load()
        preset.extras.save()
        defer { extras.save() }
        let started = Date.now
        if photos.count == 1 {
            let photo = photos[0]
            if url?.standardizedFileURL != photo.standardizedFileURL { await open(photo) }
            await export(preset.settings, to: Self.freeName(folder.appendingPathComponent(
                photo.deletingPathExtension().lastPathComponent + "." + preset.settings.format.fileExtension)))
        } else {
            await exportPhotos(photos, settings: preset.settings, to: folder, autoAdjust: preset.autoAdjust,
                               toPhotos: preset.addToPhotos)
        }
        // what this export wrote: the folder's files made since it began
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { ((try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) >= started.addingTimeInterval(-1) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
