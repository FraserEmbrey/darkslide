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
        /// other photos blended into this one, and its backdrop (Compositor)
        var composite: CompositeSettings?
        /// things painted out with Remove Objects (CleanUp.swift)
        var cleanUp: [CleanUpMark]?
    }

    /// folders added to the library, in the order added
    private(set) var folders: [URL] = []
    /// by photo path
    private(set) var records: [String: Record] = [:]

    /// saved searches over the library's folders
    var smartAlbums: [SmartAlbum] = [] { didSet { scheduleSave() } }
    /// the version each stack shows when closed, by the original's path (PhotoVersion);
    /// a stack not here shows its original
    private(set) var stackPicks: [String: String] = [:]

    func stackPick(_ stack: String) -> String? { stackPicks[stack] }

    /// photos stacked together (Auto-Stack, or Stack): each a list of
    /// originals' paths, the first its key, as an original keys its versions' stack
    private(set) var bursts: [[String]] = [] { didSet { burstOf = Self.index(bursts) } }
    private var burstOf: [String: String] = [:]
    var hasBursts: Bool { !bursts.isEmpty }

    private static func index(_ bursts: [[String]]) -> [String: String] {
        var out: [String: String] = [:]
        for b in bursts { for m in b { out[m] = b[0] } }
        return out
    }

    /// the key of the stack an original is in, if it's in one with other photos
    func burst(containing original: String) -> String? { burstOf[original] }

    func burstMembers(of original: String) -> [String]? {
        burstOf[original].flatMap { key in bursts.first { $0[0] == key } }
    }

    /// a new stack of originals, replacing any they were in; returns its key
    @discardableResult
    func addBurst(_ members: [String]) -> String {
        let set = Set(members)
        bursts.removeAll { !set.isDisjoint(with: $0) }
        bursts.append(members)
        scheduleSave()
        return members[0]
    }

    func removeBurst(containing original: String) {
        guard let key = burstOf[original] else { return }
        bursts.removeAll { $0[0] == key }
        stackPicks[key] = nil
        scheduleSave()
    }

    func setStackPick(_ pick: String?, for stack: String) {
        stackPicks[stack] = pick
        scheduleSave()
    }

    private struct Stored: Codable {
        var folders: [String]
        var records: [String: Record]
        var remount: [String: String]?
        var smartAlbums: [SmartAlbum]?
        var stackPicks: [String: String]?
        var bursts: [[String]]?
    }

    // CatalogPath: launch argument (-CatalogPath /path/catalog.json) for testing, so tests leave the real one alone.
    // A headless export keeps none: its photos are temporary copies.
    private let file: URL? = HeadlessExport.requested ? nil : UserDefaults.standard.string(forKey: "CatalogPath").map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Darkslide/catalog.json")
    private var saveTask: Task<Void, Never>?

    init() {
        guard let file, let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        folders = stored.folders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        records = stored.records
        remount = stored.remount ?? [:]
        smartAlbums = stored.smartAlbums ?? []
        stackPicks = stored.stackPicks ?? [:]
        bursts = stored.bursts ?? []
        burstOf = Self.index(bursts)   // didSet doesn't run in init
    }

    // MARK: Folders

    func addFolders(_ urls: [URL]) {
        for url in urls where !folders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            folders.append(url)
        }
        noteRemountURLs()
        scheduleSave()
    }

    /// For each folder on a network share, the share's address, as macOS
    /// gives it for remounting (smb://server/share), so an offline folder
    /// can be reconnected. Kept only in this catalog, on this Mac.
    private var remount: [String: String] = [:]

    /// notes the addresses of the folders that are online now
    func noteRemountURLs() {
        let folders = self.folders
        Task.detached(priority: .utility) {
            var found: [String: String] = [:]
            for f in folders where FileManager.default.fileExists(atPath: f.path) {
                if let url = (try? f.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting {
                    found[f.standardizedFileURL.path] = url.absoluteString
                }
            }
            await MainActor.run {
                let merged = self.remount.merging(found) { _, new in new }
                guard merged != self.remount else { return }
                self.remount = merged
                self.scheduleSave()
            }
        }
    }

    /// the network share a folder (or a folder inside one) is on, if known
    func remountURL(for folder: URL) -> URL? {
        let path = folder.standardizedFileURL.path
        let root = remount.keys.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        return root.flatMap { remount[$0] }.flatMap(URL.init(string:))
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

    func cleanUp(of photo: URL) -> [CleanUpMark] { records[photo.path]?.cleanUp ?? [] }

    func setCleanUp(_ marks: [CleanUpMark], for photo: URL) {
        records[photo.path, default: Record()].cleanUp = marks.isEmpty ? nil : marks
        scheduleSave()
    }

    func composite(of photo: URL) -> CompositeSettings? { records[photo.path]?.composite }

    func setComposite(_ settings: CompositeSettings?, for photo: URL) {
        guard records[photo.path]?.composite != settings else { return }
        records[photo.path, default: Record()].composite = settings
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
        let stored = Stored(folders: folders.map(\.path), records: records, remount: remount, smartAlbums: smartAlbums,
                            stackPicks: stackPicks, bursts: bursts)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: file, options: .atomic) }
    }
}
