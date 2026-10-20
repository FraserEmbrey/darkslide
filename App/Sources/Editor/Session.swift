import Foundation

/// Where things were when Darkslide quit, so a relaunch goes back there: the
/// photo open, the library's folder or collection, whether the grid was
/// showing, and the photo selected in it.
struct Session: Codable {
    /// the open photo's path (a version's own, photo_01.NEF)
    var photo: String?
    var source: Source?
    var showingLibrary = false
    var selection: String?

    /// LibrarySource, as it's kept
    enum Source: Codable {
        case folder(String), edited, exported, map, photos(album: String?, title: String), photosPlaces, smart(UUID)

        init(_ s: LibrarySource) {
            switch s {
            case .folder(let url): self = .folder(url.path)
            case .edited: self = .edited
            case .exported: self = .exported
            case .map: self = .map
            case .photos(let album, let title): self = .photos(album: album, title: title)
            case .photosPlaces: self = .photosPlaces
            case .smart(let id): self = .smart(id)
            }
        }

        var librarySource: LibrarySource {
            switch self {
            case .folder(let path): .folder(URL(fileURLWithPath: path, isDirectory: true))
            case .edited: .edited
            case .exported: .exported
            case .map: .map
            case .photos(let album, let title): .photos(album: album, title: title)
            case .photosPlaces: .photosPlaces
            case .smart(let id): .smart(id)
            }
        }
    }

    /// TestSession: launch argument (-TestSession YES) for testing: keeps and
    /// restores the session under its own key, beside the real one
    private static var testing: Bool { UserDefaults.standard.bool(forKey: "TestSession") }
    private static var key: String { testing ? "TestSession.saved" : "Session" }

    /// Test runs (launch arguments starting -Test or -Start, or their own
    /// catalog) neither keep nor restore the session, but for TestSession.
    static var isTestRun: Bool {
        guard !testing else { return false }
        return UserDefaults.standard.string(forKey: "CatalogPath") != nil
            || ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-Test") || $0.hasPrefix("-Start") }
    }

    static func load() -> Session? {
        guard !isTestRun, let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    func save() {
        guard !Self.isTestRun, let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
