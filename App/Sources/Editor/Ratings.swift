import Foundation
import ImageIO

/// What a photo's XMP sidecar says beyond its edit: the rating darktable
/// keeps there, and whether it holds an edit at all. Rating or tagging a
/// photo writes a sidecar too, and such a photo hasn't been edited: it still
/// gets the new-photo defaults when it opens, and stays out of Edited.
enum Sidecar {
    static func url(for photo: URL) -> URL { URL(fileURLWithPath: photo.path + ".xmp") }

    /// A photo's rating: its sidecar's, else the one the camera wrote into the
    /// file (Nikon and others rate in camera). 1 to 5 stars, 0 none, -1 rejected.
    static func rating(of photo: URL) -> Int {
        if let xmp = try? String(contentsOf: url(for: photo), encoding: .utf8) {
            return rating(inXMP: xmp) ?? 0
        }
        guard let source = CGImageSourceCreateWithURL(photo.photoFile as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let text = CGImageMetadataCopyStringValueWithPath(meta, nil, "xmp:Rating" as CFString) as String?,
              let value = Int(text) else { return 0 }
        return min(max(value, -1), 5)
    }

    /// darktable writes xmp:Rating="n", -1 for rejected
    static func rating(inXMP xmp: String) -> Int? {
        guard let value = attribute("xmp:Rating", in: xmp).flatMap({ Int($0) }) else { return nil }
        return min(max(value, -1), 5)
    }

    /// whether a sidecar holds an edit: darktable history, not only metadata
    static func hasEdit(_ photo: URL) -> Bool {
        guard let xmp = try? String(contentsOf: url(for: photo), encoding: .utf8) else { return false }
        return hasEdit(inXMP: xmp)
    }

    static func hasEdit(inXMP xmp: String) -> Bool {
        if let end = attribute("darktable:history_end", in: xmp).flatMap({ Int($0) }) { return end > 0 }
        // older sidecars: any history item
        guard let history = xmp.range(of: "<darktable:history>") else { return false }
        return xmp[history.upperBound...].contains("<rdf:li")
    }

    private static func attribute(_ name: String, in xmp: String) -> String? {
        guard let start = xmp.range(of: name + "=\"") else { return nil }
        let rest = xmp[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
