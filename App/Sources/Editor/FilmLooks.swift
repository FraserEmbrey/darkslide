import Foundation

/// The film looks in a folder of LUTs: Hald CLUT images (.png, .tif) and
/// .cube and .3dl files, in folders by kind and maker, as in the RawTherapee
/// film simulation pack. Files of one film pushed and pulled ("Kodak Portra 400
/// 1 -", "… 2", "… 3 +", "… 4 ++") are gathered as variants of it.
struct FilmLook: Hashable, Identifiable {
    let path: String            // relative to the folder, as darktable's LUT 3D stores it
    let group: [String]         // the folders it's in, e.g. ["Color", "Kodak"]
    let film: String            // "Kodak Portra 400"
    let variant: String?        // "−", "Normal", "+", "++", or nil for a film with one file
    var id: String { path }

    var title: String { variant.map { "\(film) · \($0)" } ?? film }

    static let extensions: Set<String> = ["png", "tif", "tiff", "cube", "3dl"]

    /// every look under `folder`, sorted by folder then film
    static func scan(_ folder: URL) -> [FilmLook] {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var looks: [FilmLook] = []
        let root = folder.standardizedFileURL.path
        for case let url as URL in e where extensions.contains(url.pathExtension.lowercased()) {
            let rel = String(url.standardizedFileURL.path.dropFirst(root.count + 1))
            var parts = rel.components(separatedBy: "/")
            let file = (parts.removeLast() as NSString).deletingPathExtension
            // the pack's identity image isn't a look
            if file.lowercased().contains("identity") { continue }
            let (film, variant) = split(file)
            looks.append(FilmLook(path: rel, group: parts, film: film, variant: variant))
        }
        return looks.sorted { ($0.group.joined(separator: "/"), $0.film, $0.path) < ($1.group.joined(separator: "/"), $1.film, $1.path) }
    }

    /// "Kodak Portra 400 3 +" -> ("Kodak Portra 400", "+"); the pack numbers
    /// a film's files so they sort pulled to pushed, 2 being the normal one
    /// where there are pulled ones
    private static func split(_ name: String) -> (String, String?) {
        guard let m = name.wholeMatch(of: /(.+?) ([1-9])( (\++|-+))?/) else { return (name, nil) }
        let sign = m.output.4.map(String.init) ?? ""
        let label = sign.isEmpty ? "Normal" : sign.replacingOccurrences(of: "-", with: "−")
        return (String(m.output.1), label)
    }
}

/// A film with its push and pull variants, as the browser shows it.
struct Film: Identifiable, Hashable {
    let group: [String]
    let name: String
    let looks: [FilmLook]
    var id: String { (group + [name]).joined(separator: "/") }
    /// the one a click applies: the normal one, or the only one
    var main: FilmLook { looks.first { $0.variant == "Normal" } ?? looks[0] }

    static func gather(_ looks: [FilmLook]) -> [Film] {
        var order: [String] = []
        var byID: [String: (group: [String], name: String, looks: [FilmLook])] = [:]
        for l in looks {
            let id = (l.group + [l.film]).joined(separator: "/")
            if byID[id] == nil { order.append(id); byID[id] = (l.group, l.film, []) }
            byID[id]!.looks.append(l)
        }
        return order.map { Film(group: byID[$0]!.group, name: byID[$0]!.name, looks: byID[$0]!.looks) }
    }
}
