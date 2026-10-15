import CoreGraphics
import Foundation

/// How the camera focused: the mode, the AF area, whether it found focus, and
/// where the AF area sat. Read from Nikon's maker note (ImageIO doesn't decode
/// its AF block), after exiftool's tables: the focus mode is tag 0x0007, and
/// AFInfo2 (tag 0x00b7) holds the area, detection and, for mirrorless bodies,
/// the AF area's position in the camera's own frame.
struct CameraFocus: Sendable, Equatable {
    /// AF-S, AF-C, AF-A or Manual
    var mode: String?
    var area: String?
    var detection: String?
    /// whether the camera found focus (Expeed 7 bodies: Z8, Z9, Z6III, Zf, Z5II, Z50II)
    var inFocus: Bool?
    /// the AF area, 0...1 across the photo as the sensor saw it (before rotation)
    var box: CGRect?

    var modeText: String? {
        switch mode?.uppercased() {
        case nil: nil
        case "AF-S": "Single AF (AF-S)"
        case "AF-C": "Continuous AF (AF-C)"
        case "AF-A": "Auto AF (AF-A)"
        case "AF-F": "Full-time AF (AF-F)"
        case "MANUAL", "MF": "Manual focus"
        default: mode
        }
    }

    static func read(_ url: URL) -> CameraFocus? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let file = Reader(h), let tiff = file.tiffStart(),
              let exif = file.ifdEntry(tiff: tiff, ifd: file.ifd0(tiff: tiff), tag: 0x8769),
              let note = file.ifdEntry(tiff: tiff, ifd: tiff.base + Int(exif.value), tag: 0x927c)
        else { return nil }
        let start = tiff.base + Int(note.value)
        // Nikon's type 3 note: "Nikon\0", a version, then its own TIFF header
        guard file.bytes(at: start, count: 6) == Array("Nikon\0".utf8),
              let inner = file.tiffHeader(at: start + 10) else { return nil }
        let ifd = inner.base + inner.firstIFD
        var focus = CameraFocus()
        if let m = file.ifdEntry(tiff: inner, ifd: ifd, tag: 0x0007), let raw = file.data(of: m, tiff: inner) {
            focus.mode = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if focus.mode?.isEmpty == true { focus.mode = nil }
        }
        if let af = file.ifdEntry(tiff: inner, ifd: ifd, tag: 0x00b7), let d = file.data(of: af, tiff: inner), d.count >= 8 {
            focus.readAFInfo2(d, bigEndian: inner.bigEndian)
        }
        // NX Studio's pixel shift merge keeps the mode but blanks the AF result
        // and position (out of focus, at 0, 0), which would only mislead
        if url.pathExtension.lowercased() == "nefx" { focus.inFocus = nil; focus.box = nil }
        return focus.mode == nil && focus.area == nil ? nil : focus
    }

    private mutating func readAFInfo2(_ d: [UInt8], bigEndian: Bool) {
        let version = String(decoding: d.prefix(4), as: UTF8.self)
        func u16(_ i: Int) -> Int? {
            guard i + 1 < d.count else { return nil }
            return bigEndian ? Int(d[i]) << 8 | Int(d[i + 1]) : Int(d[i + 1]) << 8 | Int(d[i])
        }
        let method = Int(d[4])
        detection = [0: "Phase detect", 1: "Contrast detect", 2: "Hybrid"][method]
        let mode = Int(d[5])
        area = (method == 0 ? Self.phaseAreas : Self.contrastAreas)[mode]
        // where the camera gives the AF area as coordinates (mirrorless bodies)
        let fields: (w: Int, h: Int, x: Int, y: Int, aw: Int, ah: Int, result: Int?)?
        switch version {
        case "0300", "0301": fields = (0x2a, 0x2c, 0x2e, 0x30, 0x32, 0x34, nil)
        case "0400", "0401", "0402": fields = (0x3e, 0x40, 0x42, 0x44, 0x46, 0x48, 0x4a)
        default: fields = nil
        }
        guard let f = fields, d[7] == 1 else { return }
        if let r = f.result, r < d.count { inFocus = d[r] == 1 }
        guard let w = u16(f.w), let h = u16(f.h), w > 0, h > 0,
              let x = u16(f.x), let y = u16(f.y), let aw = u16(f.aw), let ah = u16(f.ah),
              x > 0 || y > 0, aw > 0, ah > 0 else { return }
        // the position is the area's centre
        box = CGRect(x: (Double(x) - Double(aw) / 2) / Double(w), y: (Double(y) - Double(ah) / 2) / Double(h),
                     width: Double(aw) / Double(w), height: Double(ah) / Double(h))
    }

    private static let phaseAreas = [0: "Single point", 1: "Dynamic area", 2: "Dynamic area (closest subject)",
                                     3: "Group dynamic", 4: "Dynamic area (9 points)", 5: "Dynamic area (21 points)",
                                     6: "Dynamic area (51 points)", 7: "Dynamic area (51 points, 3D tracking)",
                                     8: "Auto area", 9: "3D tracking", 10: "Single point (wide)", 11: "Dynamic area (wide)",
                                     12: "Dynamic area (wide, 3D tracking)", 13: "Group area", 14: "Dynamic area (25 points)",
                                     15: "Dynamic area (72 points)", 16: "Group area (horizontal)", 17: "Group area (vertical)",
                                     18: "Dynamic area (49 points)", 128: "Single point", 129: "Auto area",
                                     130: "Subject tracking", 131: "Face priority"]
    private static let contrastAreas = [0: "Contrast detect", 1: "Normal area", 2: "Wide area", 3: "Face priority",
                                        4: "Subject tracking", 128: "Single point", 129: "Auto area", 130: "Subject tracking",
                                        131: "Face priority", 192: "Pinpoint", 193: "Single point", 194: "Dynamic area",
                                        195: "Wide area (S)", 196: "Wide area (L)", 197: "Auto area", 198: "Auto area (people)",
                                        199: "Auto area (animals)", 200: "Normal area", 201: "Wide area", 202: "Face priority",
                                        203: "Subject tracking", 204: "Dynamic area (S)", 205: "Dynamic area (M)",
                                        206: "Dynamic area (L)", 207: "3D tracking", 208: "Wide area (custom)"]
}

/// Reads a TIFF-structured file (NEF, NRW, NEFX) or a JPEG's Exif block, a
/// piece at a time, so a half-gigabyte merged file isn't read whole.
private struct Reader {
    struct TIFF { let base: Int; let bigEndian: Bool; let firstIFD: Int }
    struct Entry { let type: Int; let count: Int; let value: UInt32; let valueAt: Int }

    let handle: FileHandle

    init?(_ h: FileHandle) { handle = h }

    func bytes(at offset: Int, count: Int) -> [UInt8]? {
        guard offset >= 0, count > 0, count < 1 << 20 else { return nil }
        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let d = try handle.read(upToCount: count), d.count == count else { return nil }
            return [UInt8](d)
        } catch { return nil }
    }

    func tiffHeader(at base: Int) -> TIFF? {
        guard let b = bytes(at: base, count: 8) else { return nil }
        let big: Bool
        switch (b[0], b[1]) {
        case (0x4d, 0x4d): big = true
        case (0x49, 0x49): big = false
        default: return nil
        }
        return TIFF(base: base, bigEndian: big, firstIFD: Int(Self.u32(b, 4, big)))
    }

    /// the TIFF a raw is, or the one in a JPEG's APP1 Exif segment
    func tiffStart() -> TIFF? {
        if let t = tiffHeader(at: 0) { return t }
        guard let soi = bytes(at: 0, count: 2), soi == [0xff, 0xd8] else { return nil }
        var at = 2
        while let m = bytes(at: at, count: 4), m[0] == 0xff {
            let len = Int(m[2]) << 8 | Int(m[3])
            if m[1] == 0xe1, bytes(at: at + 4, count: 6) == Array("Exif\0\0".utf8) { return tiffHeader(at: at + 10) }
            if m[1] == 0xda { return nil }
            at += 2 + len
        }
        return nil
    }

    func ifd0(tiff: TIFF) -> Int { tiff.base + tiff.firstIFD }

    func ifdEntry(tiff: TIFF, ifd: Int, tag: Int) -> Entry? {
        guard let c = bytes(at: ifd, count: 2) else { return nil }
        let n = tiff.bigEndian ? Int(c[0]) << 8 | Int(c[1]) : Int(c[1]) << 8 | Int(c[0])
        guard n > 0, n < 1000, let all = bytes(at: ifd + 2, count: n * 12) else { return nil }
        for i in 0..<n {
            let e = i * 12
            let t = tiff.bigEndian ? Int(all[e]) << 8 | Int(all[e + 1]) : Int(all[e + 1]) << 8 | Int(all[e])
            guard t == tag else { continue }
            let type = tiff.bigEndian ? Int(all[e + 2]) << 8 | Int(all[e + 3]) : Int(all[e + 3]) << 8 | Int(all[e + 2])
            return Entry(type: type, count: Int(Self.u32(all, e + 4, tiff.bigEndian)),
                         value: Self.u32(all, e + 8, tiff.bigEndian), valueAt: ifd + 2 + e + 8)
        }
        return nil
    }

    /// an entry's bytes: in the entry itself when they fit in four, else at its offset
    func data(of e: Entry, tiff: TIFF) -> [UInt8]? {
        let size = [1: 1, 2: 1, 3: 2, 4: 4, 7: 1][e.type] ?? 1
        let n = e.count * size
        return n <= 4 ? bytes(at: e.valueAt, count: n) : bytes(at: tiff.base + Int(e.value), count: n)
    }

    static func u32(_ b: [UInt8], _ i: Int, _ big: Bool) -> UInt32 {
        let v = (0..<4).map { UInt32(b[i + $0]) }
        return big ? v[0] << 24 | v[1] << 16 | v[2] << 8 | v[3] : v[3] << 24 | v[2] << 16 | v[1] << 8 | v[0]
    }
}
