import Foundation
import Observation

/// What Darkslide remembers across folders: the folders added to the library,
/// and a record of photos edited and exported. Kept as JSON in Application
/// Support; paths, since the app isn't sandboxed.
@MainActor
@Observable
final class Catalog {
    struct Export: Codable, Hashable {
        let file: String     // the exported file's path
        let format: String   // as the export panel names it
        let date: Date
    }

    struct Record: Codable {
        var edited: Date?    // last saved here, or first seen with a sidecar
        var exports: [Export] = []
        /// AI denoise's amount (1 to 100) when it's on; not in the sidecar,
        /// as darktable has nothing to read it with
        var aiDenoise: Double?
    }

    /// folders added to the library, in the order added
    private(set) var folders: [URL] = []
    /// by photo path
    private(set) var records: [String: Record] = [:]

    private struct Stored: Codable {
        var folders: [String]
        var records: [String: Record]
    }

    // CatalogPath: launch argument (-CatalogPath /path/catalog.json) for testing, so tests leave the real one alone
    private let file: URL? = UserDefaults.standard.string(forKey: "CatalogPath").map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Darkslide/catalog.json")
    private var saveTask: Task<Void, Never>?

    init() {
        guard let file, let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        folders = stored.folders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        records = stored.records
    }

    // MARK: Folders

    func addFolders(_ urls: [URL]) {
        for url in urls where !folders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            folders.append(url)
        }
        scheduleSave()
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        scheduleSave()
    }

    /// the added folder this path is in, if any
    func isInLibrary(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return folders.contains { path == $0.standardizedFileURL.path || path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    // MARK: Edits and exports

    func recordEdit(_ photo: URL, date: Date = .now) {
        records[photo.path, default: Record()].edited = date
        scheduleSave()
    }

    /// photos found with a sidecar join the record without moving their date
    func noteSidecar(_ photo: URL, date: Date) {
        guard records[photo.path]?.edited == nil else { return }
        records[photo.path, default: Record()].edited = date
        scheduleSave()
    }

    /// many at once, as one change: a folder scan can find thousands, and each
    /// change to the records redraws what shows them (the sidebar's counts)
    func noteSidecars(_ found: [(photo: URL, date: Date)]) {
        var updated = records
        var changed = false
        for (photo, date) in found where updated[photo.path]?.edited == nil {
            updated[photo.path, default: Record()].edited = date
            changed = true
        }
        guard changed else { return }
        records = updated
        scheduleSave()
    }

    func recordExport(_ photo: URL, file: URL, format: String) {
        records[photo.path, default: Record()].exports.append(Export(file: file.path, format: format, date: .now))
        scheduleSave()
    }

    func aiDenoise(of photo: URL) -> Double? { records[photo.path]?.aiDenoise }

    func setAIDenoise(_ amount: Double?, for photo: URL) {
        guard records[photo.path]?.aiDenoise != amount else { return }
        records[photo.path, default: Record()].aiDenoise = amount
        scheduleSave()
    }

    func exports(of photo: URL) -> [Export] { records[photo.path]?.exports ?? [] }

    /// edited after its latest export, so the export is out of date
    func modifiedSinceExport(_ photo: URL) -> Bool {
        guard let r = records[photo.path], let last = r.exports.map(\.date).max(), let edited = r.edited else { return false }
        return edited > last
    }

    var editedPhotos: [URL] {
        records.filter { $0.value.edited != nil }
            .sorted { ($0.value.edited ?? .distantPast) > ($1.value.edited ?? .distantPast) }
            .map { URL(fileURLWithPath: $0.key) }
    }

    var exportedPhotos: [URL] {
        records.filter { !$0.value.exports.isEmpty }
            .sorted { ($0.value.exports.map(\.date).max() ?? .distantPast) > ($1.value.exports.map(\.date).max() ?? .distantPast) }
            .map { URL(fileURLWithPath: $0.key) }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    func save() {
        guard let file else { return }
        let stored = Stored(folders: folders.map(\.path), records: records)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: file, options: .atomic) }
    }
}
