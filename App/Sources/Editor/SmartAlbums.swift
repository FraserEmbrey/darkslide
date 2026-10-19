import Foundation
import ImageIO

/// A saved search over the library's folders, as Aperture's and Photos' smart
/// albums: photos matching all (or any) of its rules, gathered whenever it's shown.
struct SmartAlbum: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = "Smart Album"
    var matchAll = true
    var rules: [SmartRule] = [SmartRule()]

    func matches(_ p: PhotoFacts) -> Bool {
        let live = rules.filter(\.isComplete)
        guard !live.isEmpty else { return true }
        return matchAll ? live.allSatisfy { $0.matches(p) } : live.contains { $0.matches(p) }
    }
}

struct SmartRule: Codable, Identifiable, Hashable {
    enum Field: String, Codable, CaseIterable, Identifiable {
        case rating, keyword, camera, lens, taken, edited, exported, raw, fileName, folder, version
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rating: "Rating"
            case .keyword: "Keyword"
            case .camera: "Camera"
            case .lens: "Lens"
            case .taken: "Date Taken"
            case .edited: "Edited"
            case .exported: "Exported"
            case .raw: "Raw"
            case .fileName: "File Name"
            case .folder: "Folder"
            case .version: "Version"
            }
        }
        var kind: Kind {
            switch self {
            case .rating: .rating
            case .taken: .date
            case .edited, .exported, .raw, .version: .flag
            default: .text
            }
        }
        /// what a yes-or-no rule calls each side
        var flagNames: (yes: String, no: String) {
            switch self {
            case .edited: ("is edited", "isn't edited")
            case .exported: ("is exported", "isn't exported")
            case .raw: ("is a raw", "isn't a raw")
            default: ("is a version", "is an original")
            }
        }
    }
    enum Kind { case rating, text, date, flag }

    enum Op: String, Codable, CaseIterable, Identifiable {
        // rating
        case atLeast, exactly, below, rejected
        // text
        case contains, notContains, `is`
        // date
        case after, before, lastDays
        // flag
        case yes, no
        var id: String { rawValue }

        static func ops(for kind: Kind) -> [Op] {
            switch kind {
            case .rating: [.atLeast, .exactly, .below, .rejected]
            case .text: [.contains, .notContains, .is]
            case .date: [.lastDays, .after, .before]
            case .flag: [.yes, .no]
            }
        }

        func title(for field: Field) -> String {
            switch self {
            case .atLeast: "is at least"
            case .exactly: "is"
            case .below: "is below"
            case .rejected: "is rejected"
            case .contains: "contains"
            case .notContains: "doesn't contain"
            case .is: "is"
            case .after: "is after"
            case .before: "is before"
            case .lastDays: "is in the last"
            case .yes: field.flagNames.yes
            case .no: field.flagNames.no
            }
        }
    }

    var id = UUID()
    var field = Field.rating
    var op = Op.atLeast
    var text = ""
    var number = 3.0
    var date = Date.now

    /// a text rule with nothing typed yet is left out, rather than matching everything or nothing
    var isComplete: Bool { field.kind != .text || !text.trimmingCharacters(in: .whitespaces).isEmpty }

    mutating func setField(_ f: Field) {
        field = f
        if !Op.ops(for: f.kind).contains(op) { op = Op.ops(for: f.kind)[0] }
        if f.kind == .date, op == .lastDays { number = 30 }
        if f.kind == .rating { number = 3 }
    }

    func matches(_ p: PhotoFacts) -> Bool {
        func text(_ values: [String]) -> Bool {
            let want = self.text.trimmingCharacters(in: .whitespaces)
            let hit = values.contains {
                op == .is ? $0.compare(want, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                          : $0.range(of: want, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            return op == .notContains ? !hit : hit
        }
        switch field {
        case .rating:
            switch op {
            case .rejected: return p.rating < 0
            case .exactly: return p.rating == Int(number)
            case .below: return p.rating >= 0 && p.rating < Int(number)
            default: return p.rating >= Int(number)
            }
        case .keyword: return text(p.keywords)
        case .camera: return text([p.camera].compactMap { $0 })
        case .lens: return text([p.lens].compactMap { $0 })
        case .fileName: return text([p.name])
        case .folder: return text([p.folder])
        case .taken:
            guard let taken = p.taken else { return false }
            switch op {
            case .after: return taken >= Calendar.current.startOfDay(for: date)
            case .before: return taken < Calendar.current.startOfDay(for: date)
            default: return taken >= Date.now.addingTimeInterval(-number * 86400)
            }
        case .edited: return p.edited == (op == .yes)
        case .exported: return p.exported == (op == .yes)
        case .raw: return p.isRaw == (op == .yes)
        case .version: return (p.version > 0) == (op == .yes)
        }
    }
}

/// What smart albums look at in a photo: from the file's EXIF (ImageIO, which
/// reads raws), its sidecar, and the catalog.
struct PhotoFacts: Codable, Sendable {
    var name = ""
    var folder = ""
    var camera: String?
    var lens: String?
    var taken: Date?
    var keywords: [String] = []
    var rating = 0
    var isRaw = false
    var version = 0
    var edited = false
    var exported = false
    /// the file's and the sidecar's modification dates when read, to know when to read again
    var stamp = ""
}

/// Every photo's facts, kept on disk between launches: a library of thousands
/// of raws takes a while to read, and most don't change.
actor PhotoIndex {
    static let shared = PhotoIndex()
    private var entries: [String: PhotoFacts] = [:]
    private var loaded = false
    private var dirty = false

    private static let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Darkslide/photo-index.json")

    /// the facts for each photo, reading the ones new or changed since last time
    func facts(for urls: [URL]) async -> [URL: PhotoFacts] {
        if !loaded {
            loaded = true
            if let data = try? Data(contentsOf: Self.file),
               let stored = try? JSONDecoder().decode([String: PhotoFacts].self, from: data) { entries = stored }
        }
        var out: [URL: PhotoFacts] = [:]
        var todo: [(URL, String)] = []
        for url in urls {
            let stamp = Self.stamp(url)
            if let e = entries[url.path], e.stamp == stamp { out[url] = e } else { todo.append((url, stamp)) }
        }
        // read in parallel: each reads the start of a raw file
        let read = await withTaskGroup(of: (URL, PhotoFacts).self) { group in
            var results: [(URL, PhotoFacts)] = []
            var next = 0
            for _ in 0..<min(8, todo.count) {
                let (u, s) = todo[next]; next += 1
                group.addTask { (u, Self.read(u, stamp: s)) }
            }
            while let r = await group.next() {
                results.append(r)
                if next < todo.count {
                    let (u, s) = todo[next]; next += 1
                    group.addTask { (u, Self.read(u, stamp: s)) }
                }
            }
            return results
        }
        for (u, f) in read { entries[u.path] = f; out[u] = f }
        if !read.isEmpty { dirty = true; save() }
        return out
    }

    private func save() {
        guard dirty, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
        dirty = false
    }

    private static func stamp(_ url: URL) -> String {
        func date(_ path: String) -> Double {
            ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
        }
        return "\(date(url.photoFile.path))|\(date(url.path + ".xmp"))"
    }

    private static func read(_ url: URL, stamp: String) -> PhotoFacts {
        var f = PhotoFacts()
        f.stamp = stamp
        f.name = url.photoFile.lastPathComponent
        f.folder = url.deletingLastPathComponent().lastPathComponent
        f.isRaw = Library.isRaw(url)
        f.version = url.versionNumber
        if let src = CGImageSourceCreateWithURL(url.photoFile as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
            let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
            let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
            f.camera = CameraNames.display(make: make, model: model)
            f.lens = exif[kCGImagePropertyExifLensModel] as? String ?? aux[kCGImagePropertyExifAuxLensModel] as? String
            if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.dateFormat = "yyyy:MM:dd HH:mm:ss"
                f.taken = df.date(from: s)
            }
        }
        f.rating = Sidecar.rating(of: url)
        if let xmp = try? String(contentsOf: Sidecar.url(for: url), encoding: .utf8) {
            f.keywords = Sidecar.keywords(inXMP: xmp)
        }
        return f
    }
}

extension Sidecar {
    /// the user's keywords: dc:subject, less darktable's own automatic tags
    static func keywords(inXMP xmp: String) -> [String] {
        func items(in tag: String) -> [String] {
            guard let start = xmp.range(of: "<\(tag)>"), let end = xmp.range(of: "</\(tag)>", range: start.upperBound..<xmp.endIndex) else { return [] }
            let block = xmp[start.upperBound..<end.lowerBound]
            var found: [String] = []
            var rest = block[...]
            while let a = rest.range(of: "<rdf:li>"), let b = rest.range(of: "</rdf:li>", range: a.upperBound..<rest.endIndex) {
                found.append(String(rest[a.upperBound..<b.lowerBound])
                    .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
                    .replacingOccurrences(of: "&amp;", with: "&"))
                rest = rest[b.upperBound...]
            }
            return found
        }
        let automatic = Set(items(in: "lr:hierarchicalSubject").filter { $0.hasPrefix("darktable|") }
            .flatMap { $0.split(separator: "|").map(String.init) })
        return items(in: "dc:subject").filter { !automatic.contains($0) }
    }
}
