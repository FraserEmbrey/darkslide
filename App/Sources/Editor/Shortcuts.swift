import AppIntents
import Foundation

// Shortcuts: Darkslide's actions in the Shortcuts app, Spotlight and Siri.
// The intents run in the app, which they open, with the editor's model from
// AppDependencyManager (registered in DarkslideApp). build-app.sh extracts
// their metadata (Metadata.appintents) as Xcode would, from the compiler's
// constant values: without it, Shortcuts doesn't list them.

struct ExportPresetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Export Preset"
    static let defaultQuery = ExportPresetQuery()
    let id: UUID
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ preset: ExportPreset) { id = preset.id; name = preset.name }
}

struct ExportPresetQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ExportPresetEntity] {
        ExportPreset.load().filter { identifiers.contains($0.id) }.map(ExportPresetEntity.init)
    }
    func suggestedEntities() async throws -> [ExportPresetEntity] {
        ExportPreset.load().map(ExportPresetEntity.init)
    }
}

struct SmartAlbumEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Smart Album"
    static let defaultQuery = SmartAlbumQuery()
    let id: UUID
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct SmartAlbumQuery: EntityQuery {
    @Dependency private var model: EditorModel

    func entities(for identifiers: [UUID]) async throws -> [SmartAlbumEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    @MainActor func suggestedEntities() async throws -> [SmartAlbumEntity] {
        model.catalog.smartAlbums.map { SmartAlbumEntity(id: $0.id, name: $0.name) }
    }
}

/// waits for the engine, which starts with the app, so an intent that opened it can use it
@MainActor private func engineReady(_ model: EditorModel) async throws {
    for _ in 0..<300 where !model.engineReady { try await Task.sleep(for: .milliseconds(100)) }
    guard model.engineReady else { throw IntentError.engineNotReady }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case engineNotReady, nothingExported, noSuchPreset
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .engineNotReady: "Darkslide's engine didn't start."
        case .nothingExported: "Nothing was exported."
        case .noSuchPreset: "That export preset no longer exists."
        }
    }
}

struct ExportWithPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Photos with Preset"
    static let description = IntentDescription("Exports raws and images with a Darkslide export preset, each with its own edit, and returns the exported files.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Photos", supportedContentTypes: [.image])
    var photos: [IntentFile]

    @Parameter(title: "Preset")
    var preset: ExportPresetEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Export \(\.$photos) with \(\.$preset)")
    }

    @Dependency private var model: EditorModel

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try await Self.run(photos.compactMap(\.fileURL), preset: preset.id, model: model).map { IntentFile(fileURL: $0) })
    }

    @MainActor
    static func run(_ photos: [URL], preset id: UUID, model: EditorModel) async throws -> [URL] {
        try await engineReady(model)
        guard let p = model.exportPresets.first(where: { $0.id == id }) else { throw IntentError.noSuchPreset }
        guard let written = await model.exportNow(photos, with: p), !written.isEmpty else { throw IntentError.nothingExported }
        return written
    }
}

struct OpenPhotoIntent: AppIntent {
    static let title: LocalizedStringResource = "Open in Darkslide"
    static let description = IntentDescription("Opens a photo to edit, or a folder in the library.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Photo or Folder", supportedContentTypes: [.image, .folder])
    var file: IntentFile

    @Dependency private var model: EditorModel

    @MainActor
    func perform() async throws -> some IntentResult {
        try await engineReady(model)
        if let url = file.fileURL { await model.openDropped([url]) }
        return .result()
    }
}

struct ShowSmartAlbumIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Smart Album"
    static let description = IntentDescription("Shows one of Darkslide's smart albums in the library.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Smart Album")
    var album: SmartAlbumEntity

    @Dependency private var model: EditorModel

    @MainActor
    func perform() async throws -> some IntentResult {
        model.showSource(.smart(album.id))
        await model.showLibrary()
        return .result()
    }
}

struct DarkslideShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ExportWithPresetIntent(),
                    phrases: ["Export photos with \(.applicationName)", "Export with a \(.applicationName) preset"],
                    shortTitle: "Export with Preset", systemImageName: "square.and.arrow.up")
        AppShortcut(intent: ShowSmartAlbumIntent(),
                    phrases: ["Show \(\.$album) in \(.applicationName)", "Show a smart album in \(.applicationName)"],
                    shortTitle: "Show Smart Album", systemImageName: "gearshape.2")
    }
}

/// for the TestShortcuts launch argument: the export action's work, as Shortcuts runs it
enum DarkslideShortcutsTest {
    @MainActor static func export(_ photos: [URL], preset: ExportPreset, model: EditorModel) async -> String {
        do {
            return "\(try await ExportWithPresetIntent.run(photos, preset: preset.id, model: model).map(\.lastPathComponent))"
        } catch {
            return "error \(error)"
        }
    }
}
