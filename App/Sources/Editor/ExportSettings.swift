import Foundation

/// The export formats Develop offers: JPEG, TIFF and PNG from darktable, and
/// a JPEG with an HDR gain map and HEIF from Core Image (see
/// EditorModel.exportGainMapJPEG and exportHEIF). darktable is built without
/// its HEIF, JPEG XL, WebP and OpenEXR modules: macOS writes HEIF itself.
enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case jpeg, jpegGainMap, heif, tiff, png

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .jpegGainMap: "JPEG with HDR gain map"
        case .heif: "HEIF"
        case .tiff: "TIFF"
        case .png: "PNG"
        }
    }

    /// darktable's format module, for formats darktable writes
    var darktableName: String? {
        switch self {
        case .jpegGainMap, .heif: nil
        default: rawValue
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg, .jpegGainMap: "jpg"
        case .heif: "heic"
        case .tiff: "tif"
        case .png: "png"
        }
    }

    var usesQuality: Bool { [.jpeg, .jpegGainMap, .heif].contains(self) }

    /// bit depths darktable's module for the format offers
    var bitDepths: [Int] {
        switch self {
        case .jpeg, .jpegGainMap: [8]
        case .heif: [8, 10]     // what Core Image writes
        case .tiff: [8, 16, 32]
        case .png: [8, 16]
        }
    }

    /// whether the format can carry HDR at the given depth
    func holdsHDR(bitDepth: Int) -> Bool {
        self == .jpegGainMap || (self == .heif && bitDepth >= 10)
    }

    var detail: String {
        switch self {
        case .jpeg: "Opens everywhere. 8-bit, so standard brightness only."
        case .jpegGainMap: "An ordinary JPEG that also carries the HDR highlights (ISO 21496-1 gain map, as Ultra HDR and iPhone photos use). Shows as HDR in Apple apps, Chrome and Android, and as a normal JPEG elsewhere."
        case .heif: "Apple's format: smaller than JPEG, and 10-bit for HDR."
        case .tiff: "Lossless, for printing or editing elsewhere. Large files."
        case .png: "Lossless, mainly for graphics. Large files for photos."
        }
    }
}

/// Export colour profiles, as darktable's dt_colorspaces_color_profile_type_t.
enum ExportProfile: Int, CaseIterable, Identifiable, Codable {
    case fromEdit = -1
    case sRGB = 1, displayP3 = 26, adobeRGB = 2, linearRec2020 = 4
    case hlgP3 = 25, pqP3 = 24, hlgRec2020 = 23, pqRec2020 = 22

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .fromEdit: "From the edit"
        case .sRGB: "sRGB"
        case .displayP3: "Display P3"
        case .adobeRGB: "Adobe RGB"
        case .linearRec2020: "Linear Rec.2020"
        case .hlgP3: "HLG P3 (HDR)"
        case .pqP3: "PQ P3 (HDR)"
        case .hlgRec2020: "HLG Rec.2020 (HDR)"
        case .pqRec2020: "PQ Rec.2020 (HDR)"
        }
    }

    var isHDR: Bool { [.hlgP3, .pqP3, .hlgRec2020, .pqRec2020].contains(self) }
    static let sdr: [ExportProfile] = [.sRGB, .displayP3, .adobeRGB, .linearRec2020]
    static let hdr: [ExportProfile] = [.hlgP3, .pqP3, .hlgRec2020, .pqRec2020]
}

/// Where a gain map JPEG's SDR base comes from. Greg Benz's point: most
/// viewers have little HDR headroom, so they mostly see the SDR base, and an
/// automatic tone mapping of the HDR image makes a poor one.
enum SDRBase: String, CaseIterable, Identifiable, Codable {
    case darktable, automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .darktable: "darktable's SDR rendering"
        case .automatic: "Automatic (Apple tone mapping)"
        }
    }

    var detail: String {
        switch self {
        case .darktable: "Your edit with the tone mapper's target white at standard brightness, so highlights roll off as your tone mapper intends."
        case .automatic: "Apple's tone mapping of the HDR image. Quick, but flatter."
        }
    }
}

struct ExportSettings: Codable, Equatable {
    var format: ExportFormat = .jpeg
    var sdrBase: SDRBase = .darktable
    var profile: ExportProfile = .fromEdit
    var quality = 92
    var bitDepth = 8
    /// 0 is the original size, otherwise the long edge in pixels
    var longEdge = 0

    static let sizes = [0, 1080, 2048, 3000, 4096, 6000]
    static let key = "ExportSettings2"

    static func load() -> ExportSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(ExportSettings.self, from: data) else { return ExportSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
