import AppKit
import CoreLocation
import CoreImage
import CryptoKit
import ImageIO
import NetFS
import Observation
import UniformTypeIdentifiers

/// One photo in the library folder.
struct LibraryItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    /// a name for items that aren't files (Photos assets: their date)
    var title: String? = nil
    var name: String { title ?? url.lastPathComponent }
    var folderName: String { PhotosLibrary.assetID(url) != nil ? "Photos" : url.deletingLastPathComponent().lastPathComponent }
    /// its XMP sidecar holds an edit (here or in darktable), not only a rating
    var hasEdit: Bool
}

/// What the grid and filmstrip show: a folder, or a collection gathered
/// from the catalog across folders.
enum LibrarySource: Hashable {
    case folder(URL)
    case edited
    case exported
    /// every photo in the library's folders, on a map
    case map
    /// Apple Photos: an album, or the whole library
    case photos(album: String?, title: String)
    /// every photo in Apple Photos, on a map
    case photosPlaces

    /// from Apple Photos rather than the folders on this Mac
    var isPhotos: Bool {
        switch self {
        case .photos, .photosPlaces: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .folder(let url): url.lastPathComponent
        case .edited: "Edited"
        case .exported: "Exported"
        case .map: "Places"
        case .photos(_, let title): title
        case .photosPlaces: "Places"
        }
    }
}

/// The photos being worked through: the grid and the filmstrip.
/// Thumbnails start as the camera's embedded preview (fast, via ImageIO);
/// once a photo is edited, its thumbnail is the render, cached on disk and
/// reused while the sidecar is unchanged.
@MainActor
@Observable
final class Library {
    private(set) var source: LibrarySource?
    /// what's showing: the source's photos, less any the rating filter hides
    private(set) var items: [LibraryItem] = []
    /// all of the source's photos
    private var allItems: [LibraryItem] = [] { didSet { applyFilter() } }
    /// every photo of the source, whatever the filter
    var allPhotos: [URL] { allItems.map(\.url) }

    // MARK: Ratings

    /// each photo's rating: 1 to 5 stars, 0 none, -1 rejected; read from the
    /// sidecars (or the camera's own) after a scan
    private(set) var ratings: [URL: Int] = [:]

    enum RatingFilter: String, CaseIterable, Identifiable {
        case all, notRejected, unrated, picked, best, rejected
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .notRejected: "Hide Rejected"
            case .unrated: "Unrated"
            case .picked: "Rated"
            case .best: "★★★ and Up"
            case .rejected: "Rejected"
            }
        }
        func shows(_ rating: Int) -> Bool {
            switch self {
            case .all: true
            case .notRejected: rating >= 0
            case .unrated: rating == 0
            case .picked: rating > 0
            case .best: rating >= 3
            case .rejected: rating < 0
            }
        }
    }

    /// kept across launches, so rejects stay hidden while editing
    var ratingFilter = RatingFilter(rawValue: UserDefaults.standard.string(forKey: "LibraryRatingFilter") ?? "") ?? .all {
        didSet {
            guard ratingFilter != oldValue else { return }
            UserDefaults.standard.set(ratingFilter.rawValue, forKey: "LibraryRatingFilter")
            applyFilter()
        }
    }

    func rating(of url: URL) -> Int { ratings[url] ?? 0 }

    /// shown at once; the sidecar is written by the caller
    func noteRating(_ value: Int, for urls: [URL]) {
        var updated = ratings
        for u in urls { updated[u] = value }
        ratings = updated
    }

    /// Photos the filter would hide stay while they're the current photo, so
    /// rating one doesn't pull it from under you; they go on the next change.
    private func applyFilter() {
        guard ratingFilter != .all else { items = allItems; return }
        items = allItems.filter { ratingFilter.shows(ratings[$0.url] ?? 0) || $0.url == selection }
    }

    /// Reads every photo's rating, off the main thread.
    private func loadRatings(_ urls: [URL], generation: Int) {
        let files = urls.filter { PhotosLibrary.assetID($0) == nil }
        Task.detached(priority: .utility) {
            var found: [URL: Int] = [:]
            for u in files { found[u] = Sidecar.rating(of: u) }
            await MainActor.run {
                guard generation == self.scanGeneration else { return }
                self.ratings = found
                self.applyFilter()
            }
        }
    }
    /// tells a Photos source when Photos changes
    private var photosObserver: PhotosLibrary.Observer?
    private(set) var thumbnails: [URL: CGImage] = [:]
    /// photos that hold HDR (a gain map, HLG or PQ), found as thumbnails load
    private(set) var hdrPhotos: Set<URL> = []
    private(set) var isScanning = false
    /// a folder shows the photos in its subfolders too
    var includeSubfolders = UserDefaults.standard.bool(forKey: "LibraryIncludeSubfolders") {
        didSet {
            UserDefaults.standard.set(includeSubfolders, forKey: "LibraryIncludeSubfolders")
            if case .folder = source { rescan() }
        }
    }

    /// the grid of thumbnails, the photos on a map, or one at a time for culling
    enum ViewMode: String { case grid, map, cull }
    var viewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "LibraryViewMode") ?? "") ?? .grid {
        didSet {
            UserDefaults.standard.set(viewMode.rawValue, forKey: "LibraryViewMode")
            if showsMap { loadLocations() }
        }
    }
    /// where each photo was taken, for those with GPS data; filled by loadLocations
    private(set) var locations: [URL: CLLocationCoordinate2D] = [:]
    private var locationsChecked: Set<URL> = []
    private(set) var isLoadingLocations = false

    let catalog: Catalog
    private var loading: Set<URL> = []
    private var scanGeneration = 0
    /// a folder with more photos than this beneath it stops there
    nonisolated private static let scanLimit = 5000
    nonisolated private static let thumbnailPixels = 360
    /// whether a file is a camera raw: by its type, or by extension for raws
    /// macOS doesn't know, such as Nikon's pixel shift merges (.nefx)
    nonisolated static func isRaw(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
            || (UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) ?? false)
    }

    nonisolated private static let rawExtensions: Set<String> = [
        "3fr", "ari", "arw", "bay", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "iiq", "k25", "kdc",
        "mef", "mos", "mrw", "nef", "nefx", "nrw", "orf", "pef", "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw", "x3f",
    ]
    nonisolated private static let imageExtensions: Set<String> = ["jpg", "jpeg", "tif", "tiff", "png", "heic", "heif", "jxl", "avif", "webp"]

    init(catalog: Catalog) {
        self.catalog = catalog
        // a share or drive coming or going: which folders are reachable, and
        // the folder showing rescanned if it's on it
        let centre = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkFolders() }
            }
        }
        checkFolders()
    }

    // MARK: Offline folders

    /// the library's folders (and the folder last shown) that can't be reached
    /// now: on a network share that isn't connected, or a drive that's out
    private(set) var offlineFolders: Set<URL> = []

    /// whether a folder is in, or is, an offline one
    func isOffline(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        return offlineFolders.contains { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    /// Looks again at which folders are reachable. A folder that's come back
    /// is listed again, and noted for reconnecting another time.
    func checkFolders() {
        let candidates = (catalog.folders + (lastFolder.map { [$0] } ?? [])).map(\.standardizedFileURL)
        Task.detached(priority: .utility) {
            let missing = Set(candidates.filter { !FileManager.default.fileExists(atPath: $0.path) })
            await MainActor.run {
                guard missing != self.offlineFolders else { return }
                let back = self.offlineFolders.subtracting(missing)
                self.offlineFolders = missing
                if !back.isEmpty {
                    FolderCache.shared.forget()
                    self.catalog.noteRemountURLs()
                }
                if case .folder = self.source { self.rescan() }
                else if self.source == .map || self.source == .edited || self.source == .exported { self.rescan() }
            }
        }
    }

    /// Mounts an offline folder's network share again, asking for a password
    /// only if the keychain doesn't have one. The mount notification brings
    /// its photos back.
    func reconnect(_ folder: URL) {
        guard let address = catalog.remountURL(for: folder) else { return }
        reconnecting.insert(folder)
        // as Finder's Connect to Server, without opening a Finder window
        let open = NSMutableDictionary(dictionary: [kNAUIOptionKey: kNAUIOptionAllowUI])
        var request: AsyncRequestID?
        let started = NetFSMountURLAsync(address as CFURL, nil, nil, nil, open, nil, &request, .main) { [weak self] status, _, _ in
            MainActor.assumeIsolated {
                self?.reconnecting.remove(folder)
                // cancelled at the password prompt, or failed: Finder can say why
                if status != 0, status != Int32(ECANCELED) { NSWorkspace.shared.open(address) }
                self?.checkFolders()
            }
        }
        if started != 0 {
            reconnecting.remove(folder)
            NSWorkspace.shared.open(address)
        }
    }

    /// offline folders being reconnected now
    private(set) var reconnecting: Set<URL> = []

    func canReconnect(_ folder: URL) -> Bool { catalog.remountURL(for: folder) != nil }

    /// Watches what's showing, so photos added to or removed from its folders
    /// appear and go without reopening it.
    @ObservationIgnored private lazy var watcher = FolderWatcher { [weak self] in self?.rescan(watching: false) }

    private func watchSource() {
        let folders: [URL] = switch source {
        case .folder(let f): [f]
        case .map: catalog.folders + (lastFolder.map { [$0] } ?? [])
        // a collection's photos are spread across folders: watch those
        case .edited, .exported: Array(Set(items.map { $0.url.deletingLastPathComponent() }))
        case .photos, .photosPlaces: []
        case nil: []
        }
        watcher.watch(folders)
    }

    nonisolated static func isPhoto(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return rawExtensions.contains(ext) || imageExtensions.contains(ext)
    }

    /// the folder being shown, if it's a folder
    var folder: URL? {
        if case .folder(let url) = source { return url }
        return nil
    }

    /// the current photo in the grid, map or strip (the metadata window shows
    /// it, arrows move it); setting it selects that photo alone
    var selection: URL? {
        didSet {
            if !extending { selected = selection.map { [$0] } ?? [] }
            // a photo the filter hides goes once you move off it
            if ratingFilter != .all, selection != oldValue { applyFilter() }
        }
    }
    /// every selected photo: ⌘-click adds or removes one, ⇧-click a range
    private(set) var selected: Set<URL> = []
    private var extending = false

    /// a click in the grid, with the keys held
    func click(_ url: URL, command: Bool, shift: Bool) {
        if shift, let anchor = selection,
           let a = items.firstIndex(where: { $0.url == anchor }), let b = items.firstIndex(where: { $0.url == url }) {
            let range = items[min(a, b)...max(a, b)].map(\.url)
            extending = true
            selected = command ? selected.union(range) : Set(range)
            extending = false
        } else if command {
            extending = true
            if selected.contains(url) {
                selected.remove(url)
                // the current photo moves to another selected one, if it was this
                if selection == url { selection = items.first { selected.contains($0.url) }?.url }
            } else {
                selected.insert(url)
                selection = url
            }
            extending = false
        } else {
            selection = url
        }
    }

    func selectAll() {
        extending = true
        selected = Set(items.map(\.url))
        if selection == nil { selection = items.first?.url }
        extending = false
    }

    /// the selected photos in the grid's order
    var selectedInOrder: [URL] { items.map(\.url).filter(selected.contains) }

    /// the folder shown most recently, which stays in the sidebar and on the
    /// map, across launches too
    /// One on a volume that's away (a network share or a drive) is kept, and shows as offline.
    private(set) var lastFolder: URL? = UserDefaults.standard.string(forKey: "LibraryLastFolder")
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        .flatMap { FileManager.default.fileExists(atPath: $0.path) || $0.path.hasPrefix("/Volumes/") ? $0 : nil } {
        didSet {
            // a test run with its own catalog (-CatalogPath) leaves the real setting alone
            guard UserDefaults.standard.string(forKey: "CatalogPath") == nil else { return }
            UserDefaults.standard.set(lastFolder?.path, forKey: "LibraryLastFolder")
        }
    }

    /// whether the photos show on the map: the Map source, or another in map view
    var showsMap: Bool { source == .map || source == .photosPlaces || viewMode == .map }

    /// Shows a folder or collection. Nothing happens if it's already showing,
    /// so opening a photo from it keeps the thumbnails.
    func show(_ source: LibrarySource) {
        guard source != self.source else { return }
        self.source = source
        if case .folder(let url) = source { lastFolder = url }
        allItems = []
        ratings = [:]
        rescan()
    }

    func show(folder: URL) { show(.folder(folder.standardizedFileURL)) }

    func contains(_ url: URL) -> Bool { index(of: url) != nil }

    func rescan() { rescan(watching: true) }

    private func rescan(watching: Bool) {
        guard let source else { return }
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        let recursive = includeSubfolders
        if source.isPhotos {
            var album: String? = nil
            if case .photos(let a, _) = source { album = a }
            Task.detached(priority: .userInitiated) {
                let found = PhotosLibrary.assets(in: album).map { LibraryItem(url: $0.url, title: $0.title, hasEdit: $0.edited) }
                await MainActor.run {
                    guard generation == self.scanGeneration else { return }
                    self.allItems = found
                    self.isScanning = false
                    if let sel = self.selection, !self.items.contains(where: { $0.url == sel }) { self.selection = nil }
                    if self.showsMap { self.loadLocations() }
                    self.watchPhotos()
                }
            }
            return
        }
        let collection: [URL]? = switch source {
        case .folder, .map, .photos, .photosPlaces: nil
        case .edited: catalog.editedPhotos
        case .exported: catalog.exportedPhotos
        }
        // the map covers the library's folders, and the folder open now
        var mapFolders = catalog.folders
        if let current = lastFolder, !catalog.isInLibrary(current) { mapFolders.append(current) }
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var urls: [URL]
            switch source {
            case .folder(let folder):
                urls = recursive ? Self.photos(beneath: folder) : Self.photos(in: folder)
                urls.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            case .map:
                var seen = Set<String>()
                urls = []
                for folder in mapFolders where urls.count < Self.scanLimit {
                    for url in Self.photos(beneath: folder) where seen.insert(url.standardizedFileURL.path).inserted {
                        urls.append(url)
                    }
                }
                urls = Array(urls.prefix(Self.scanLimit))
            default:
                urls = (collection ?? []).filter { fm.fileExists(atPath: $0.path) }
            }
            let found = urls.map { url -> (LibraryItem, Date?) in
                let xmp = url.path + ".xmp"
                // a sidecar that only rates or tags the photo isn't an edit
                let date = ((try? fm.attributesOfItem(atPath: xmp)[.modificationDate]) as? Date)
                    .flatMap { Sidecar.hasEdit(url) ? $0 : nil }
                return (LibraryItem(url: url, hasEdit: date != nil), date)
            }
            await MainActor.run {
                guard generation == self.scanGeneration else { return }
                self.allItems = found.map(\.0)
                self.loadRatings(found.map(\.0.url), generation: generation)
                self.isScanning = false
                if watching { self.watchSource() }
                if let sel = self.selection, !self.items.contains(where: { $0.url == sel }) { self.selection = nil }
                if self.showsMap { self.loadLocations() }
                // sidecars from darktable, or from before the catalog, join Edited
                self.catalog.noteSidecars(found.compactMap { item, date in date.map { (item.url, $0) } })
            }
        }
    }

    nonisolated private static func photos(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return files.filter(isPhoto)
    }

    nonisolated private static func photos(beneath folder: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walk where isPhoto(url) {
            found.append(url)
            if found.count >= scanLimit { break }
        }
        return found
    }

    /// subfolders, for the sidebar
    nonisolated static func subfolders(of folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries.filter {
            let v = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return v?.isDirectory == true && v?.isPackage != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func index(of url: URL?) -> Int? {
        guard let url else { return nil }
        // a Photos address is never a file path to tidy
        if PhotosLibrary.assetID(url) != nil { return items.firstIndex { $0.url == url } }
        let path = url.standardizedFileURL.path
        return items.firstIndex { $0.url.standardizedFileURL.path == path }
    }

    func neighbour(of url: URL?, offset: Int) -> URL? {
        guard let i = index(of: url) else { return items.first?.url }
        let j = i + offset
        return items.indices.contains(j) ? items[j].url : nil
    }

    func noteEdited(_ url: URL) {
        if let i = allItems.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { allItems[i].hasEdit = true }
    }

    /// Reads the GPS position of every photo not yet checked: the sidecar's
    /// first (darktable's map view geotags there), then the file's own EXIF.
    func loadLocations() {
        var todo = items.map(\.url).filter { !locationsChecked.contains($0) }
        // Photos has its photos' places already: no files read, but tens of
        // thousands of them take a moment, so off the main thread
        let fromPhotos = todo.filter { PhotosLibrary.assetID($0) != nil }
        if !fromPhotos.isEmpty {
            fromPhotos.forEach { locationsChecked.insert($0) }
            isLoadingLocations = true
            Task.detached(priority: .userInitiated) {
                let found = PhotosLibrary.locations(of: fromPhotos)
                await MainActor.run {
                    if self.locations.isEmpty { self.locations = found } else { self.locations.merge(found) { $1 } }
                    self.isLoadingLocations = false
                }
            }
            todo.removeAll { PhotosLibrary.assetID($0) != nil }
        }
        guard !todo.isEmpty, !isLoadingLocations else { return }
        isLoadingLocations = true
        Task.detached(priority: .utility) {
            let found = await withTaskGroup(of: (URL, CLLocationCoordinate2D?).self) { group in
                var results: [(URL, CLLocationCoordinate2D?)] = []
                var next = 0
                // a few at a time: each reads the start of a raw file
                for _ in 0..<min(8, todo.count) {
                    let url = todo[next]; next += 1
                    group.addTask { (url, Self.location(of: url)) }
                }
                while let r = await group.next() {
                    results.append(r)
                    if next < todo.count {
                        let url = todo[next]; next += 1
                        group.addTask { (url, Self.location(of: url)) }
                    }
                }
                return results
            }
            await MainActor.run {
                for (url, coordinate) in found {
                    self.locationsChecked.insert(url)
                    if let coordinate { self.locations[url] = coordinate }
                }
                self.isLoadingLocations = false
                // items may have changed while this ran
                if self.items.contains(where: { !self.locationsChecked.contains($0.url) }) { self.loadLocations() }
            }
        }
    }

    /// Keeps a Photos source current: photos added or removed reload the grid,
    /// and photos edited (here, in Photos or on another device) get new
    /// thumbnails and places.
    private func watchPhotos() {
        guard photosObserver == nil else { return }
        photosObserver = PhotosLibrary.Observer { [weak self] changed, reload in
            Task { @MainActor in
                guard let self, self.source?.isPhotos == true else { return }
                // in one go: a change per photo redrew the grid each time, and
                // Photos reports thousands at once while it analyses the library
                let stale = changed.filter { self.thumbnails[$0] != nil }
                if !stale.isEmpty {
                    var thumbnails = self.thumbnails
                    stale.forEach { thumbnails[$0] = nil }
                    self.thumbnails = thumbnails
                }
                if !changed.isEmpty { self.locationsChecked.subtract(changed) }
                if reload { self.rescan() } else if self.showsMap, !changed.isEmpty { self.loadLocations() }
            }
        }
    }

    /// after placing a photo on the map
    func setLocation(_ coordinate: CLLocationCoordinate2D?, for url: URL) {
        locations[url] = coordinate
        locationsChecked.insert(url)
        // a file has a sidecar now; a Photos photo was placed in Photos
        if PhotosLibrary.assetID(url) == nil { noteEdited(url) }
    }

    /// a file's location: its sidecar's, else its EXIF GPS
    nonisolated static func locationOf(_ url: URL) -> CLLocationCoordinate2D? { location(of: url) }

    nonisolated private static func location(of url: URL) -> CLLocationCoordinate2D? {
        sidecarLocation(of: url) ?? exifLocation(of: url)
    }

    nonisolated private static func exifLocation(of url: URL) -> CLLocationCoordinate2D? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              var lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              var lon = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = -lon }
        return valid(lat, lon)
    }

    /// XMP stores positions as degrees and decimal minutes: exif:GPSLatitude="51,30.1234N"
    nonisolated private static func sidecarLocation(of url: URL) -> CLLocationCoordinate2D? {
        guard let xmp = try? String(contentsOfFile: url.path + ".xmp", encoding: .utf8) else { return nil }
        func value(_ name: String) -> Double? {
            guard let range = xmp.range(of: "exif:\(name)=\"") else { return nil }
            let rest = xmp[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            let text = rest[..<end]
            guard let hemisphere = text.last, "NSEW".contains(hemisphere) else { return nil }
            let parts = text.dropLast().split(separator: ",").compactMap { Double($0) }
            guard let degrees = parts.first else { return nil }
            let minutes = parts.count > 1 ? parts[1] : 0
            let seconds = parts.count > 2 ? parts[2] : 0
            let v = degrees + minutes / 60 + seconds / 3600
            return "SW".contains(hemisphere) ? -v : v
        }
        guard let lat = value("GPSLatitude"), let lon = value("GPSLongitude") else { return nil }
        return valid(lat, lon)
    }

    nonisolated private static func valid(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D? {
        // cameras without a fix often write zeros
        guard abs(lat) <= 90, abs(lon) <= 180, !(lat == 0 && lon == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Loads a thumbnail when a cell first appears.
    func requestThumbnail(for url: URL) {
        guard thumbnails[url] == nil, !loading.contains(url) else { return }
        loading.insert(url)
        if let id = PhotosLibrary.assetID(url) {
            Task {
                let image = await PhotosLibrary.thumbnail(id, size: CGFloat(Self.thumbnailPixels))
                self.loading.remove(url)
                if let image { self.thumbnails[url] = image }
            }
            return
        }
        Task.detached(priority: .utility) {
            var image = Self.cachedRender(for: url)
            let isRaw = Self.rawExtensions.contains(url.pathExtension.lowercased())
            var hdr = isRaw ? AppleRawFallback.rawHasGainMap(url) : AppleRawFallback.isHDR(url)
            if image == nil {
                image = Self.embeddedPreview(for: url)
                // a NEF shot in the HLG tone mode has only a tiny preview macOS can
                // read; its HDR preview, tone mapped, instead
                if isRaw, Self.isTiny(image), let hlg = NikonHDRPreview.sdrPicture(in: url, maxPixels: Self.thumbnailPixels) {
                    image = hlg
                    hdr = true
                }
            } else if isRaw, url.pathExtension.lowercased() == "nef", NikonHDRPreview.isHLG(url) {
                hdr = true
            }
            await MainActor.run {
                self.loading.remove(url)
                if let image { self.thumbnails[url] = image }
                if hdr { self.hdrPhotos.insert(url) }
            }
        }
    }

    /// After editing: the render becomes the thumbnail, here and on disk.
    func updateThumbnail(for url: URL, from frame: CGImage) {
        guard let small = Self.downscale(frame) else { return }
        thumbnails[url] = small
        Task.detached(priority: .utility) { Self.storeRender(small, for: url) }
    }

    // MARK: Thumbnail sources

    /// What the canvas shows while a photo opens, before darktable's first
    /// render. `quick` is the stored render of a photo edited here, else the
    /// camera's preview at thumbnail size; otherwise the camera's preview at
    /// screen size. A photo with a sidecar but no stored render (edited in
    /// darktable) gets nothing: the camera's look would misstate its edits.
    nonisolated static func openingPreview(for url: URL, quick: Bool, maxPixels: Int) -> CGImage? {
        if let stored = cachedRender(for: url) { return quick ? stored : nil }
        if FileManager.default.fileExists(atPath: url.path + ".xmp") { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            // the embedded preview only: decoding the raw itself is darktable's job
            kCGImageSourceCreateThumbnailFromImageIfAbsent: !rawExtensions.contains(url.pathExtension.lowercased()),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: quick ? thumbnailPixels : maxPixels,
        ]
        let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        // an HLG NEF's HDR preview, when macOS finds only a tiny one
        if isTiny(preview), rawExtensions.contains(url.pathExtension.lowercased()),
           let hlg = NikonHDRPreview.sdrPicture(in: url, maxPixels: quick ? thumbnailPixels : maxPixels) {
            return hlg
        }
        return preview
    }

    /// missing, or too small to show at thumbnail size
    nonisolated static func isTiny(_ image: CGImage?) -> Bool {
        guard let image else { return true }
        return max(image.width, image.height) < thumbnailPixels / 2
    }

    nonisolated private static func embeddedPreview(for url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // camera orientation
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Rendered thumbnails live in Caches, named for the photo's path and keyed
    /// to its sidecar's modification date, so an edit elsewhere invalidates them.
    nonisolated private static func cacheURL(for url: URL) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let xmp = (try? FileManager.default.attributesOfItem(atPath: url.path + ".xmp")[.modificationDate] as? Date)
            .map { "\($0.timeIntervalSince1970)" } ?? "none"
        let digest = SHA256.hash(data: Data((url.path + "|" + xmp).utf8)).map { String(format: "%02x", $0) }.joined()
        return caches.appendingPathComponent("Darkslide/thumbnails/\(digest.prefix(32)).jpg")
    }

    nonisolated private static func cachedRender(for url: URL) -> CGImage? {
        guard let file = cacheURL(for: url),
              let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    nonisolated private static func storeRender(_ image: CGImage, for url: URL) {
        guard let file = cacheURL(for: url) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// to sRGB 8-bit at thumbnail size; HDR frames are tone mapped to SDR
    nonisolated private static func downscale(_ image: CGImage) -> CGImage? {
        let scale = Double(thumbnailPixels) / Double(max(image.width, image.height))
        var ci = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if image.contentHeadroom > 1 {
            let map = CIFilter(name: "CIToneMapHeadroom")
            map?.setValue(ci, forKey: kCIInputImageKey)
            map?.setValue(image.contentHeadroom, forKey: "inputSourceHeadroom")
            map?.setValue(1, forKey: "inputTargetHeadroom")
            ci = map?.outputImage ?? ci
        }
        return CIContext().createCGImage(ci, from: ci.extent.integral, format: .RGBA8,
                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
