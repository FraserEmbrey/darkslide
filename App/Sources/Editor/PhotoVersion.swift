import Foundation

/// Versions of a photo, as Aperture called them: darktable's duplicates.
///
/// darktable keeps each duplicate's edit in a sidecar named for its version,
/// `photo_01.NEF.xmp` beside `photo.NEF` (`dt_image_path_append_version`). Here
/// a version's URL is the file that name implies, `photo_01.NEF`, which doesn't
/// exist: its sidecar is then `url.path + ".xmp"` like any photo's, and the
/// catalog, thumbnails and exports keep it apart without knowing about
/// versions. Whatever reads the image itself goes through `photoFile`.
enum PhotoVersion {
    /// the original and version number a version's URL stands for, nil for a real file
    static func parse(_ url: URL) -> (original: URL, number: Int)? {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        guard !ext.isEmpty, let us = stem.lastIndex(of: "_") else { return nil }
        let digits = stem[stem.index(after: us)...]
        guard digits.count >= 2, digits.allSatisfy(\.isASCII), let n = Int(digits), n > 0 else { return nil }
        let original = url.deletingLastPathComponent().appendingPathComponent(String(stem[..<us])).appendingPathExtension(ext)
        // a real file with a name like that is a photo of its own
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path), fm.fileExists(atPath: original.path) else { return nil }
        return (original, n)
    }

    /// version `n` of a photo, as darktable names it (`_%02d` before the extension)
    static func url(of original: URL, number n: Int) -> URL {
        guard n > 0 else { return original }
        let stem = original.deletingPathExtension().lastPathComponent
        return original.deletingLastPathComponent()
            .appendingPathComponent(stem + String(format: "_%02d", n))
            .appendingPathExtension(original.pathExtension)
    }

    /// The versions of the photos among `files`, from the sidecars beside them.
    static func versions(among files: [URL]) -> [URL] {
        let photos = Set(files.map(\.path))
        return files.compactMap { f -> URL? in
            guard f.pathExtension.lowercased() == "xmp" else { return nil }
            let v = f.deletingPathExtension()
            guard !photos.contains(v.path), let p = parse(v), photos.contains(p.original.path) else { return nil }
            return v
        }
    }

    /// the versions there are of a photo, its own number first
    static func all(of url: URL) -> [URL] {
        let original = url.photoFile
        let dir = original.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let prefix = original.deletingPathExtension().lastPathComponent + "_"
        let found = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".xmp") }
            .map { dir.appendingPathComponent(String($0.dropLast(4))) }
            .filter { parse($0)?.original.path == original.path }
        return [original] + found.sorted { $0.versionNumber < $1.versionNumber }
    }

    /// the next free version number of a photo
    static func nextNumber(for url: URL) -> Int {
        (all(of: url).map(\.versionNumber).max() ?? 0) + 1
    }
}

extension URL {
    /// the image file: the original, for a version
    var photoFile: URL { PhotoVersion.parse(self)?.original ?? self }
    /// darktable's version number, 0 for the original
    var versionNumber: Int { PhotoVersion.parse(self)?.number ?? 0 }
    var isVersion: Bool { PhotoVersion.parse(self) != nil }
}

// MARK: - Making and deleting versions

extension EditorModel {
    /// the photo open now can have versions: a file of its own, not from Photos
    var canMakeVersion: Bool { url != nil && photosAsset == nil && !showingLibrary }

    /// A new version with the edit as it is now, opened.
    func duplicateVersion() {
        guard canMakeVersion, let url else { return }
        Task {
            await save()
            let version = PhotoVersion.url(of: url.photoFile, number: PhotoVersion.nextNumber(for: url))
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: url.path + ".xmp") {
                    try fm.copyItem(atPath: url.path + ".xmp", toPath: version.path + ".xmp")
                } else {
                    try PhotoVersion.blankSidecar.write(toFile: version.path + ".xmp", atomically: true, encoding: .utf8)
                }
            } catch {
                errorMessage = "Couldn't make a version: \(error.localizedDescription)"
                return
            }
            // its stack open, so the new version shows beside the others
            library.openStack(of: url)
            library.rescan()
            await open(version)
        }
    }

    /// A new version from the original, unedited, opened: it gets the
    /// new-photo defaults as any unedited photo does.
    func newVersionFromOriginal() {
        guard canMakeVersion, let url else { return }
        Task {
            await save()
            let version = PhotoVersion.url(of: url.photoFile, number: PhotoVersion.nextNumber(for: url))
            do {
                try PhotoVersion.blankSidecar.write(toFile: version.path + ".xmp", atomically: true, encoding: .utf8)
            } catch {
                errorMessage = "Couldn't make a version: \(error.localizedDescription)"
                return
            }
            // its stack open, so the new version shows beside the others
            library.openStack(of: url)
            library.rescan()
            await open(version)
        }
    }

    /// Moves a version's sidecar to the Bin, which is all a version is.
    /// The original isn't a version, so it can't be deleted here.
    func deleteVersion(_ version: URL) {
        guard version.isVersion else { return }
        Task {
            if url == version {
                let next = library.neighbour(of: version, offset: -1) ?? version.photoFile
                await open(next)
            }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: version.path + ".xmp"), resultingItemURL: nil)
            } catch {
                errorMessage = "Couldn't delete the version: \(error.localizedDescription)"
            }
            library.rescan()
        }
    }
}

extension PhotoVersion {
    /// a sidecar with no edit: enough for the version to be found and opened
    static let blankSidecar = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="" xmlns:darktable="http://darktable.sf.net/" darktable:xmp_version="5"/>
     </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """
}
