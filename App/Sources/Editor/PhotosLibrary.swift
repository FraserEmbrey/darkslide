import AppKit
import CoreLocation
import Foundation
import Photos
import Synchronization
import UniformTypeIdentifiers

/// Apple Photos as a library source, through PhotoKit.
///
/// Library items are files, so a Photos asset is addressed as
/// `photos://asset/<local identifier>`. Opening one writes its original (the
/// raw, where there is one) to a cache folder and edits that. Saving goes back
/// to Photos as its own edit of the original: a rendered JPEG, with the
/// darktable edit (the XMP sidecar) as the edit's adjustment data, so Photos
/// keeps the original and Revert to Original works, and reopening the photo
/// here restores every setting.
enum PhotosLibrary {
    static let scheme = "photos"
    /// identifies Darkslide's edits among Photos' adjustment data
    static let formatIdentifier = "me.frsr.darkslide"
    /// ours too: edits saved while the app was called Develop
    static let formatIdentifiers: Set<String> = [formatIdentifier, "me.frsr.develop"]
    static let formatVersion = "1"

    struct Album: Identifiable, Hashable {
        let id: String
        let title: String
        let count: Int
    }

    // MARK: addresses

    static func url(for assetID: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "asset"
        c.queryItems = [URLQueryItem(name: "id", value: assetID)]
        return c.url!
    }

    static func assetID(_ url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
    }

    static func asset(_ id: String) -> PHAsset? {
        if let a = known.withLock({ $0[id] }) { return a }
        let a = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        if let a { known.withLock { $0[id] = a } }
        return a
    }

    /// the assets of the last fetch, by identifier: a fetch per thumbnail
    /// (thousands, as a grid or map fills) loaded the whole Mac
    private static let known = Mutex<[String: PHAsset]>([:])

    // MARK: access

    static var authorised: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    static func authorise() async -> Bool {
        if authorised { return true }
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return s == .authorized || s == .limited
    }

    // MARK: collections

    /// Favourites, then the user's albums, by name. Counts are Photos'
    /// estimates (videos included): counting each album's photos meant a
    /// fetch per album, slow with hundreds of them.
    static func albums() -> [Album] {
        guard authorised else { return [] }
        var out: [Album] = []
        if let fav = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil).firstObject {
            out.append(Album(id: fav.localIdentifier, title: "Favourites", count: estimate(fav)))
        }
        let user = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var albums: [Album] = []
        user.enumerateObjects { c, _, _ in
            let n = estimate(c)
            if n != 0 { albums.append(Album(id: c.localIdentifier, title: c.localizedTitle ?? "Album", count: n)) }
        }
        return out + albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// -1 when Photos has no estimate
    private static func estimate(_ c: PHAssetCollection) -> Int {
        c.estimatedAssetCount == NSNotFound ? -1 : c.estimatedAssetCount
    }

    /// the photos of an album, or of the whole library, newest first
    static func assets(in albumID: String?) -> [(url: URL, title: String, edited: Bool)] {
        guard authorised else { return [] }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result: PHFetchResult<PHAsset>
        if let albumID, let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject {
            result = PHAsset.fetchAssets(in: album, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }
        lastFetch = result
        let format = DateFormatter()
        format.dateStyle = .medium
        format.timeStyle = .short
        var out: [(URL, String, Bool)] = []
        out.reserveCapacity(result.count)
        var byID: [String: PHAsset] = [:]
        byID.reserveCapacity(result.count)
        result.enumerateObjects { a, _, _ in
            byID[a.localIdentifier] = a
            out.append((url(for: a.localIdentifier), a.creationDate.map(format.string) ?? "Photo", a.hasAdjustments))
        }
        known.withLock { $0.merge(byID) { $1 } }
        return out
    }

    // MARK: locations

    /// where each photo was taken, as Photos has it, in one fetch
    static func locations(of urls: [URL]) -> [URL: CLLocationCoordinate2D] {
        let ids = urls.compactMap(assetID)
        guard authorised, !ids.isEmpty else { return [:] }
        var out: [URL: CLLocationCoordinate2D] = [:]
        func note(_ a: PHAsset) {
            if let c = a.location?.coordinate, CLLocationCoordinate2DIsValid(c), !(c.latitude == 0 && c.longitude == 0) {
                out[url(for: a.localIdentifier)] = c
            }
        }
        // the grid's fetch has them all already
        let cached = known.withLock { k in ids.compactMap { k[$0] } }
        cached.forEach(note)
        if cached.count < ids.count {
            let have = Set(cached.map(\.localIdentifier))
            PHAsset.fetchAssets(withLocalIdentifiers: ids.filter { !have.contains($0) }, options: nil).enumerateObjects { a, _, _ in note(a) }
        }
        return out
    }

    /// places a photo in Photos, or removes its place, as Photos' Info does
    static func setLocation(_ coordinate: CLLocationCoordinate2D?, for id: String) async throws {
        guard let asset = asset(id) else { throw PhotosError("This photo is no longer in Photos.") }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).location = coordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        }
    }

    // MARK: changes

    /// the fetch behind the grid, to tell what changed in it
    nonisolated(unsafe) static var lastFetch: PHFetchResult<PHAsset>?

    /// Tells the library when Photos changes: photos added, removed or edited
    /// (here, in Photos or on another device). `onChange` gets the addresses
    /// of photos whose picture changed, and whether the grid needs reloading.
    final class Observer: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
        let onChange: @Sendable ([URL], Bool) -> Void
        init(onChange: @escaping @Sendable ([URL], Bool) -> Void) {
            self.onChange = onChange
            super.init()
            PHPhotoLibrary.shared().register(self)
        }
        deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

        func photoLibraryDidChange(_ change: PHChange) {
            guard let fetch = PhotosLibrary.lastFetch, let details = change.changeDetails(for: fetch) else { return }
            PhotosLibrary.lastFetch = details.fetchResultAfterChanges
            // only photos whose picture changed (an edit), not the metadata
            // Photos updates all the time as it analyses the library
            let changed = details.changedObjects
                .filter { change.changeDetails(for: $0)?.assetContentChanged == true }
                .map { PhotosLibrary.url(for: $0.localIdentifier) }
            // photos added, removed or moved reload the grid; edits only redraw
            let reload = !details.hasIncrementalChanges || !details.insertedObjects.isEmpty
                || !details.removedObjects.isEmpty || details.hasMoves
            guard reload || !changed.isEmpty else { return }
            onChange(changed, reload)
        }
    }

    // MARK: thumbnails

    /// Thumbnails come from what Photos keeps on the Mac: allowing iCloud
    /// downloads here fetched thousands of photos as a grid or map filled.
    static func thumbnail(_ id: String, size: CGFloat) async -> CGImage? {
        guard let asset = asset(id) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        options.resizeMode = .fast
        return await withCheckedContinuation { c in
            imageManager.requestImage(for: asset, targetSize: CGSize(width: size, height: size),
                                                  contentMode: .aspectFit, options: options) { image, _ in
                c.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    private static let imageManager = PHCachingImageManager()

    // MARK: opening

    /// where originals are written to be edited
    static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Darkslide/photos", isDirectory: true)
    }

    /// The asset's original as a file: the raw of a raw (or raw and JPEG)
    /// photo, otherwise the photo as taken, before any edit. If Darkslide
    /// edited it before, the edit is written beside it as its XMP sidecar.
    static func original(_ id: String) async throws -> URL {
        guard let asset = asset(id) else { throw PhotosError("This photo is no longer in Photos.") }
        let resources = PHAssetResource.assetResources(for: asset)
        let raw = resources.first { $0.type == .alternatePhoto && UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }
            ?? resources.first { $0.type == .photo && UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }
        guard let resource = raw ?? resources.first(where: { $0.type == .photo }) ?? resources.first else {
            throw PhotosError("Photos has no original for this photo.")
        }
        let folder = cache.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(resource.originalFilename)
        if !FileManager.default.fileExists(atPath: file.path) {
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options)
        }
        // Darkslide's last edit, if the photo's edit in Photos is one of ours
        if let xmp = await developAdjustment(asset) {
            try xmp.write(to: URL(fileURLWithPath: file.path + ".xmp"))
        }
        return file
    }

    /// the darktable edit stored in the photo's Photos edit, if Darkslide made it
    private static func developAdjustment(_ asset: PHAsset) async -> Data? {
        guard asset.hasAdjustments else { return nil }
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { formatIdentifiers.contains($0.formatIdentifier) }
        return await withCheckedContinuation { c in
            asset.requestContentEditingInput(with: options) { input, _ in
                let data = input?.adjustmentData
                c.resume(returning: data.map { formatIdentifiers.contains($0.formatIdentifier) } == true ? data?.data : nil)
            }
        }
    }

    // MARK: saving

    /// The kind of file Photos wants for an edit's rendering (HEIC or JPEG).
    static func renderedType(for id: String) async throws -> (input: PHContentEditingInput, output: PHContentEditingOutput, url: URL, type: UTType) {
        guard let asset = asset(id) else { throw PhotosError("This photo is no longer in Photos.") }
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { formatIdentifiers.contains($0.formatIdentifier) }
        let input: PHContentEditingInput = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Handed<PHContentEditingInput>, Error>) in
            asset.requestContentEditingInput(with: options) { input, info in
                if let input { c.resume(returning: Handed(value: input)) } else {
                    c.resume(throwing: (info[PHContentEditingInputErrorKey] as? Error) ?? PhotosError("Photos wouldn't let the photo be edited."))
                }
            }
        }.value
        let output = PHContentEditingOutput(contentEditingInput: input)
        let type = output.defaultRenderedContentType ?? .jpeg
        let url = try output.renderedContentURL(for: type)
        return (input, output, url, type)
    }

    /// saves a rendering written to `output`'s URL, with the darktable edit
    static func commit(_ output: PHContentEditingOutput, for id: String, xmp: Data) async throws {
        guard let asset = asset(id) else { throw PhotosError("This photo is no longer in Photos.") }
        output.adjustmentData = PHAdjustmentData(formatIdentifier: formatIdentifier, formatVersion: formatVersion, data: xmp)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
    }

    /// passes a PhotoKit object out of its callback, which runs once
    struct Handed<T>: @unchecked Sendable { let value: T }

    struct PhotosError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}
