import CoreLocation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything known about a photo, for the metadata window: a readable
/// summary, and every tag as found. The file's own metadata comes from
/// ImageIO (which reads raws); the edit's from the XMP sidecar.
struct PhotoMetadata: Sendable {
    struct Row: Sendable, Hashable { let label: String; let value: String }
    struct Section: Sendable, Identifiable { let title: String; let rows: [Row]; var id: String { title } }

    /// the facts the Info window lays out, as Photos does
    struct Facts: Sendable {
        var title: String?
        var caption: String?
        var fileName = ""
        var format = ""
        var taken: Date?
        var rating: Int?
        var camera: String?
        var lens: String?
        var focalLength: Double?
        var focal35: Int?
        var aperture: Double?
        var shutter: Double?
        var iso: Int?
        var bias: Double?
        var width: Int?
        var height: Int?
        var fileSize: Int64?
        var whiteBalanceAuto: Bool?
        var metering: Int?
        var flashFired: Bool?
        var tags: [String] = []
        var editedWith: [String] = []
        var historyCount = 0
        var hasSidecar = false
        var hdr = false
        var locationFromSidecar = false

        var megapixels: String? {
            guard let width, let height else { return nil }
            return "\(Int((Double(width * height) / 1_000_000).rounded())) MP"
        }
        var shutterText: String? { shutter.map { $0 >= 1 ? "\(PhotoMetadata.trim($0)) s" : "1/\(Int((1 / $0).rounded())) s" } }
        var apertureText: String? { aperture.map { "ƒ\(PhotoMetadata.trim($0))" } }
        var focalText: String? { focalLength.map { "\(PhotoMetadata.trim($0)) mm" } }
        var biasText: String? { bias.map { $0 == 0 ? "0 ev" : String(format: "%+.1f ev", $0) } }
    }

    let facts: Facts
    let summary: [Section]
    let all: [Section]
    let location: CLLocationCoordinate2D?

    static func read(_ url: URL) -> PhotoMetadata {
        var summary: [Section] = []
        var all: [Section] = []
        var location: CLLocationCoordinate2D?

        let props: [CFString: Any] = {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            else { return [:] }
            return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        }()
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        // Capture
        var capture: [Row] = []
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let camera = CameraNames.display(make: make, model: model) { capture.append(Row(label: "Camera", value: camera)) }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String ?? aux[kCGImagePropertyExifAuxLensModel] as? String {
            capture.append(Row(label: "Lens", value: typesetApertures(lens)))
        }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            capture.append(Row(label: "Taken", value: formatExifDate(date) + (offset.map { " (UTC\($0))" } ?? "")))
        }
        var exposure: [String] = []
        if let f = fNumber(exif) { exposure.append("ƒ/\(trim(f))") }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double { exposure.append(shutter(t)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
        if !exposure.isEmpty { capture.append(Row(label: "Exposure", value: exposure.joined(separator: "  "))) }
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double {
            let e35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int
            capture.append(Row(label: "Focal length", value: "\(trim(fl)) mm" + (e35.map { " (\($0) mm full frame)" } ?? "")))
        }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double, bias != 0 {
            capture.append(Row(label: "Compensation", value: String(format: "%+.1f EV", bias)))
        }
        if let program = exif[kCGImagePropertyExifExposureProgram] as? Int, let name = programs[program] {
            capture.append(Row(label: "Mode", value: name))
        }
        if let metering = exif[kCGImagePropertyExifMeteringMode] as? Int, let name = meterings[metering] {
            capture.append(Row(label: "Metering", value: name))
        }
        if let flash = exif[kCGImagePropertyExifFlash] as? Int {
            capture.append(Row(label: "Flash", value: flash & 1 == 1 ? "Fired" : "Off"))
        }
        if let wb = exif[kCGImagePropertyExifWhiteBalance] as? Int {
            capture.append(Row(label: "White balance", value: wb == 0 ? "Auto" : "Manual"))
        }
        if let serial = exif[kCGImagePropertyExifBodySerialNumber] as? String {
            capture.append(Row(label: "Serial number", value: serial))
        }
        if !capture.isEmpty { summary.append(Section(title: "Capture", rows: capture)) }

        // Image
        var image: [Row] = []
        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            let mp = Double(w * h) / 1_000_000
            image.append(Row(label: "Size", value: "\(w) × \(h) (\(String(format: "%.1f", mp)) MP)"))
        }
        // for raws these describe the camera's embedded preview, not the raw data
        let isRaw = UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) ?? false
        if !isRaw {
            if let depth = props[kCGImagePropertyDepth] as? Int { image.append(Row(label: "Bit depth", value: "\(depth)-bit")) }
            if let profile = props[kCGImagePropertyProfileName] as? String { image.append(Row(label: "Colour profile", value: profile)) }
        }
        if let o = props[kCGImagePropertyOrientation] as? Int, o != 1 { image.append(Row(label: "Orientation", value: orientations[o] ?? "\(o)")) }
        if !image.isEmpty { summary.append(Section(title: "Image", rows: image)) }

        // darktable's sidecar: the edit, and where the location may have been set
        let xmpURL = URL(fileURLWithPath: url.path + ".xmp")
        let sidecar = SidecarInfo.read(xmpURL)
        location = sidecar.location ?? gpsLocation(gps)

        // Location
        if let c = location {
            var rows = [Row(label: "Coordinates", value: String(format: "%.5f, %.5f", c.latitude, c.longitude))]
            if let alt = gps[kCGImagePropertyGPSAltitude] as? Double { rows.append(Row(label: "Altitude", value: "\(Int(alt.rounded())) m")) }
            rows.append(Row(label: "From", value: sidecar.location != nil ? "The sidecar (placed in Develop or darktable)" : "The camera's GPS"))
            summary.append(Section(title: "Location", rows: rows))
        }

        if sidecar.exists {
            var rows: [Row] = []
            if let rating = sidecar.rating { rows.append(Row(label: "Rating", value: rating < 0 ? "Rejected" : rating == 0 ? "None" : String(repeating: "★", count: rating))) }
            if !sidecar.labels.isEmpty { rows.append(Row(label: "Colour labels", value: sidecar.labels.joined(separator: ", "))) }
            if !sidecar.tags.isEmpty { rows.append(Row(label: "Tags", value: sidecar.tags.joined(separator: ", "))) }
            if let title = sidecar.title { rows.append(Row(label: "Title", value: title)) }
            if let d = sidecar.description { rows.append(Row(label: "Description", value: d)) }
            rows.append(Row(label: "History", value: sidecar.historyCount == 1 ? "1 step" : "\(sidecar.historyCount) steps"))
            if !sidecar.modules.isEmpty { rows.append(Row(label: "Edited with", value: sidecar.modules.joined(separator: ", "))) }
            summary.append(Section(title: "darktable", rows: rows))
        }

        // File
        var file = [Row(label: "Name", value: url.lastPathComponent), Row(label: "Folder", value: url.deletingLastPathComponent().path)]
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            if let size = attrs[.size] as? Int64 { file.append(Row(label: "Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
            if let d = attrs[.modificationDate] as? Date { file.append(Row(label: "Modified", value: d.formatted(date: .abbreviated, time: .shortened))) }
        }
        file.append(Row(label: "Sidecar", value: sidecar.exists ? xmpURL.lastPathComponent : "None"))
        summary.append(Section(title: "File", rows: file))

        // every tag, by dictionary
        var top: [Row] = []
        for (key, value) in props {
            if let dict = value as? [CFString: Any] {
                all.append(Section(title: groupName(key as String), rows: rows(dict)))
            } else {
                top.append(Row(label: key as String, value: describe(value)))
            }
        }
        all.sort { $0.title < $1.title }
        if !top.isEmpty { all.insert(Section(title: "General", rows: top.sorted { $0.label < $1.label }), at: 0) }
        if !sidecar.all.isEmpty { all.append(Section(title: "XMP sidecar", rows: sidecar.all)) }

        var f = Facts()
        f.fileName = url.lastPathComponent
        f.format = url.pathExtension.uppercased()
        f.title = sidecar.title
        f.caption = sidecar.description
        f.rating = sidecar.rating
        f.camera = CameraNames.display(make: make, model: model)
        f.lens = (exif[kCGImagePropertyExifLensModel] as? String ?? aux[kCGImagePropertyExifAuxLensModel] as? String).map(Self.typesetApertures)
        f.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
        f.focal35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int
        if f.focal35 == nil, let fl = f.focalLength, let crop = cropFactor(exif: exif, props: props, make: make, model: model) {
            f.focal35 = Int((fl * crop).rounded())
        }
        f.aperture = fNumber(exif)
        f.shutter = exif[kCGImagePropertyExifExposureTime] as? Double
        f.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
        f.bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double
        f.width = props[kCGImagePropertyPixelWidth] as? Int
        f.height = props[kCGImagePropertyPixelHeight] as? Int
        f.fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
        // iPhones name the lens "iPhone 18 Pro Max back triple camera 16.891mm f/2.8";
        // say which camera, as Photos does, from the equivalent focal length
        if let lens = f.lens, (make ?? "").lowercased().hasPrefix("apple"), lens.lowercased().contains("camera") {
            if lens.lowercased().contains("front") {
                f.lens = "Front camera"
            } else if let eq = f.focal35 {
                f.lens = eq < 18 ? "Ultra wide camera" : eq <= 60 ? "Main camera" : "Telephoto camera"
            }
        }
        f.whiteBalanceAuto = (exif[kCGImagePropertyExifWhiteBalance] as? Int).map { $0 == 0 }
        f.metering = exif[kCGImagePropertyExifMeteringMode] as? Int
        f.flashFired = (exif[kCGImagePropertyExifFlash] as? Int).map { $0 & 1 == 1 }
        f.tags = sidecar.tags
        f.editedWith = sidecar.modules
        f.historyCount = sidecar.historyCount
        f.hasSidecar = sidecar.exists
        f.hdr = !isRaw && AppleRawFallback.isHDR(url)
        f.locationFromSidecar = sidecar.location != nil
        if let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy:MM:dd HH:mm:ss"
            // shown as the camera's clock said, so no zone shift
            df.timeZone = .current
            f.taken = df.date(from: text)
        }

        return PhotoMetadata(facts: f, summary: summary, all: all, location: location)
    }

    // MARK: Formatting

    private static func rows(_ dict: [CFString: Any]) -> [Row] {
        dict.map { Row(label: $0.key as String, value: describe($0.value)) }.sorted { $0.label < $1.label }
    }

    private static func describe(_ v: Any) -> String {
        switch v {
        case let a as [Any]: return a.map(describe).joined(separator: ", ")
        case let d as [CFString: Any]: return d.map { "\($0.key): \(describe($0.value))" }.sorted().joined(separator: "; ")
        case let n as NSNumber: return n.stringValue
        default: return "\(v)"
        }
    }

    private static func groupName(_ key: String) -> String {
        key.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
    }

    /// The crop factor, when the file doesn't give the 35 mm equivalent focal
    /// length (Fujifilm doesn't). From the camera first: the EXIF focal-plane
    /// resolution, the other route, can describe a different image size than
    /// the raw's (Fujifilm's gives a 33 mm wide sensor for the X100V's 23.5 mm
    /// APS-C), so it's only a last resort, and only when the answer is plausible.
    private static func cropFactor(exif: [CFString: Any], props: [CFString: Any], make: String?, model: String?) -> Double? {
        let maker = (make ?? "").lowercased(), body = (model ?? "").uppercased()
        if maker.hasPrefix("fujifilm") { return body.hasPrefix("GFX") ? 0.79 : 1.53 }
        if maker.hasPrefix("sony") {
            if body.hasPrefix("ILCE-6") || body.hasPrefix("ILCE-5") || body.hasPrefix("NEX") || body.hasPrefix("ZV-E10") { return 1.53 }
            if body.hasPrefix("ILCE-") { return 1 }
        }
        if maker.hasPrefix("nikon") {
            // Z bodies are full frame except the DX ones; Z50, Z30, Zfc
            if body.contains("Z 50") || body.contains("Z50") || body.contains("Z 30") || body.contains("Z30") || body.contains("Z FC") || body.contains("ZFC") { return 1.53 }
            if body.contains(" Z") || body.hasPrefix("Z") { return 1 }
        }
        if maker.hasPrefix("olympus") || maker.hasPrefix("om digital") { return 2 }
        if maker.hasPrefix("panasonic") { return body.hasPrefix("DC-S") ? 1 : 2 }
        if maker.hasPrefix("leica") && (body.hasPrefix("M") || body.hasPrefix("Q") || body.hasPrefix("SL")) { return 1 }
        // last resort: the sensor's width from the focal-plane resolution
        if let xres = exif[kCGImagePropertyExifFocalPlaneXResolution] as? Double, xres > 0,
           let width = props[kCGImagePropertyPixelWidth] as? Int,
           let unit = exif[kCGImagePropertyExifFocalPlaneResolutionUnit] as? Int,
           let unitMM = [2: 25.4, 3: 10, 4: 1][unit] {
            let crop = 36 / (Double(width) / xres * unitMM)
            if crop > 0.7 && crop < 6 { return crop }
        }
        return nil
    }

    /// The f-number: EXIF's FNumber, or else its ApertureValue (APEX: f =
    /// 2^(Av/2)), as Photos and darktable read it. A Leica M lens has no
    /// electronic contacts for its aperture, so the camera estimates it by
    /// comparing its light meter with what reached the sensor and writes only
    /// ApertureValue (its maker note's FNumber is a placeholder 1.0).
    static func fNumber(_ exif: [CFString: Any]) -> Double? {
        if let f = exif[kCGImagePropertyExifFNumber] as? Double, f > 0 { return f }
        guard let av = exif[kCGImagePropertyExifApertureValue] as? Double, av.isFinite else { return nil }
        return (pow(2, av / 2) * 10).rounded() / 10
    }

    /// Lens names write the aperture as "f/1.2" or "F2.8"; set them with the ƒ glyph.
    static func typesetApertures(_ text: String) -> String {
        text.replacing(#/\bf\/(?=\d)/#, with: "ƒ/")
            .replacing(#/\bF(?=\d+(?:\.\d+)?(?:-\d+(?:\.\d+)?)?\b)/#, with: "ƒ")
            // Fujifilm runs it on: "XF18-55mmF2.8-4"
            .replacing(#/mmF(?=\d)/#, with: "mmƒ")
    }

    static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private static func shutter(_ t: Double) -> String {
        t >= 1 ? "\(trim(t)) s" : "1/\(Int((1 / t).rounded())) s"
    }

    private static func formatExifDate(_ s: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let d = f.date(from: s) else { return s }
        return d.formatted(date: .long, time: .standard)
    }

    private static func gpsLocation(_ gps: [CFString: Any]) -> CLLocationCoordinate2D? {
        guard var lat = gps[kCGImagePropertyGPSLatitude] as? Double, var lon = gps[kCGImagePropertyGPSLongitude] as? Double,
              !(lat == 0 && lon == 0) else { return nil }
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = -lon }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private static let programs = [1: "Manual", 2: "Program", 3: "Aperture priority", 4: "Shutter priority",
                                   5: "Creative", 6: "Action", 7: "Portrait", 8: "Landscape"]
    private static let meterings = [1: "Average", 2: "Centre-weighted", 3: "Spot", 4: "Multi-spot", 5: "Multi-segment", 6: "Partial"]
    private static let orientations = [2: "Mirrored", 3: "Rotated 180°", 4: "Mirrored vertically", 5: "Mirrored, rotated 90° anticlockwise",
                                       6: "Rotated 90° clockwise", 7: "Mirrored, rotated 90° clockwise", 8: "Rotated 90° anticlockwise"]
}

/// What darktable's sidecar says: rating, labels, tags, the edit history.
private struct SidecarInfo {
    var exists = false
    var rating: Int?
    var labels: [String] = []
    var tags: [String] = []
    var title: String?
    var description: String?
    var historyCount = 0
    var modules: [String] = []
    var location: CLLocationCoordinate2D?
    var all: [PhotoMetadata.Row] = []

    static func read(_ url: URL) -> SidecarInfo {
        var info = SidecarInfo()
        var subjects: [String] = [], hierarchical: [String] = []
        guard let data = try? Data(contentsOf: url),
              let meta = CGImageMetadataCreateFromXMPData(data as CFData) else { return info }
        info.exists = true
        func string(_ path: String) -> String? {
            CGImageMetadataCopyStringValueWithPath(meta, nil, path as CFString) as String?
        }
        info.rating = string("xmp:Rating").flatMap { Int($0) }
        let labelNames = ["red", "yellow", "green", "blue", "purple"]
        if let tags = CGImageMetadataCopyTags(meta) as? [CGImageMetadataTag] {
            for tag in tags {
                let prefix = CGImageMetadataTagCopyPrefix(tag) as String? ?? ""
                let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
                let key = prefix.isEmpty ? name : "\(prefix):\(name)"
                let value = CGImageMetadataTagCopyValue(tag)
                let values: [String] = {
                    if let arr = value as? [CGImageMetadataTag] {
                        return arr.compactMap { CGImageMetadataTagCopyValue($0).map { "\($0)" } }
                    }
                    return value.map { ["\($0)"] } ?? []
                }()
                switch key {
                case "darktable:colorlabels": info.labels = values.compactMap { Int($0).flatMap { labelNames.indices.contains($0) ? labelNames[$0].capitalized : nil } }
                case "dc:subject": subjects = values
                case "lr:hierarchicalSubject": hierarchical = values
                case "dc:title": info.title = values.first
                case "dc:description": info.description = values.first
                case "darktable:history":
                    info.historyCount = (value as? [CGImageMetadataTag])?.count ?? 0
                default: break
                }
                if key != "darktable:history" && key != "darktable:masks_history" {
                    info.all.append(PhotoMetadata.Row(label: key, value: values.joined(separator: ", ")))
                }
            }
        }
        // the operations in the history, in order, without repeats
        if let history = CGImageMetadataCopyTagWithPath(meta, nil, "darktable:history" as CFString),
           let items = CGImageMetadataTagCopyValue(history) as? [CGImageMetadataTag] {
            var seen = Set<String>()
            for (i, item) in items.enumerated() {
                if let op = CGImageMetadataCopyStringValueWithPath(meta, nil, "darktable:history[\(i + 1)].darktable:operation" as CFString) as String?,
                   seen.insert(op).inserted {
                    info.modules.append(op)
                }
                _ = item
            }
        }
        info.all.sort { $0.label < $1.label }
        // darktable tags each photo with its own darktable|format|… tags, whose
        // parts also land in dc:subject; the user's tags are what's left
        let automatic = Set(hierarchical.filter { $0.hasPrefix("darktable|") }.flatMap { $0.split(separator: "|").map(String.init) })
        info.tags = subjects.filter { !automatic.contains($0) }
        // modules darktable always runs aren't edits
        let always: Set = ["rawprepare", "demosaic", "colorin", "colorout", "gamma", "flip", "dither", "finalscale"]
        info.modules = info.modules.filter { !always.contains($0) }
        // darktable writes positions as degrees and decimal minutes
        if let lat = string("exif:GPSLatitude").flatMap(Self.coordinate), let lon = string("exif:GPSLongitude").flatMap(Self.coordinate) {
            info.location = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return info
    }

    private static func coordinate(_ s: String) -> Double? {
        guard let hemisphere = s.last, "NSEW".contains(hemisphere) else { return nil }
        let parts = s.dropLast().split(separator: ",").compactMap { Double($0) }
        guard let d = parts.first else { return nil }
        let v = d + (parts.count > 1 ? parts[1] / 60 : 0) + (parts.count > 2 ? parts[2] / 3600 : 0)
        return "SW".contains(hemisphere) ? -v : v
    }
}
