import Foundation

/// The export formats Develop offers, as Pixelmator and Lightroom group them:
/// HDR JPEG and HDR HEIC (an 8-bit SDR image with an ISO 21496-1 gain map,
/// from Core Image; see EditorModel.exportGainMap), and SDR JPEG, TIFF and PNG
/// from darktable and HEIC from Core Image (exportThroughCoreImage). darktable
/// is built without its HEIF, JPEG XL, WebP and OpenEXR modules: macOS writes
/// HEIF itself. A 10-bit HLG or PQ HEIF is still written for Photos and tests,
/// but isn't offered: a gain map HEIC is half the size and shows everywhere.
/// HEIC can be 10-bit under the sheet's advanced options, for smoother
/// gradients when the file will be edited again, at about twice the size.
enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case jpegGainMap, heifGainMap, jpeg, heif, tiff, png

    static let hdrFormats: [ExportFormat] = [.jpegGainMap, .heifGainMap]
    static let sdrFormats: [ExportFormat] = [.jpeg, .heif, .png, .tiff]

    var isGainMap: Bool { self == .jpegGainMap || self == .heifGainMap }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .jpegGainMap: "HDR JPEG"
        case .heifGainMap: "HDR HEIC"
        case .heif: "HEIC"
        case .tiff: "TIFF"
        case .png: "PNG"
        }
    }

    /// darktable's format module, for formats darktable writes
    var darktableName: String? {
        switch self {
        case .jpegGainMap, .heifGainMap, .heif: nil
        default: rawValue
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg, .jpegGainMap: "jpg"
        case .heif, .heifGainMap: "heic"
        case .tiff: "tif"
        case .png: "png"
        }
    }

    var usesQuality: Bool { [.jpeg, .jpegGainMap, .heif, .heifGainMap].contains(self) }

    /// bit depths darktable's module for the format offers
    var bitDepths: [Int] {
        switch self {
        case .jpeg, .jpegGainMap: [8]
        case .heif, .heifGainMap: [8, 10]     // what Core Image writes
        case .tiff: [8, 16, 32]
        case .png: [8, 16]
        }
    }

    /// whether the format can carry HDR at the given depth
    func holdsHDR(bitDepth: Int) -> Bool {
        isGainMap || (self == .heif && bitDepth >= 10)
    }

    /// bit depths the export sheet offers
    var offeredBitDepths: [Int] { bitDepths }

    /// whether the bit depth sits under the sheet's advanced options: HEIC is
    /// 8-bit unless asked, while PNG and TIFF are chosen for their depth
    var bitDepthIsAdvanced: Bool { self == .heif || self == .heifGainMap }

    var detail: String {
        switch self {
        case .jpegGainMap: "A JPEG that also carries the HDR highlights in a gain map (ISO 21496-1). HDR in Apple apps, Chrome and Android; a normal JPEG everywhere else."
        case .heifGainMap: "A HEIC with an HDR gain map, as iPhone photos are. About half the size of HDR JPEG; HDR in Apple apps and recent browsers."
        case .jpeg: "Opens everywhere."
        case .heif: "Apple's format: about half the size of JPEG at the same quality."
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
    /// what the export sheet offers
    static let offered: [ExportProfile] = [.sRGB, .displayP3, .adobeRGB]
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
    var profile: ExportProfile = .sRGB
    var quality = 85
    var bitDepth = 8
    /// 0 is the original size, otherwise the long edge in pixels
    var longEdge = 0
    /// 2 or 4 to enlarge the original size on export (Upscaler); the long
    /// edge doesn't apply then. Optional so older saved settings still load.
    var enlarge: Int?

    /// the enlargement, when it's one this Mac can do
    var enlargement: Int? {
        guard let enlarge, Upscaler.factors.contains(enlarge), Upscaler.isAvailable else { return nil }
        return enlarge
    }

    static let sizes = [0, 1080, 2048, 3000, 4096, 6000]
    static let key = "ExportSettings2"

    static func load() -> ExportSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              var s = try? JSONDecoder().decode(ExportSettings.self, from: data) else { return ExportSettings() }
        // the sheet offers SDR profiles for SDR formats only
        if !s.format.isGainMap, s.profile == .fromEdit || s.profile.isHDR { s.profile = .sRGB }
        if !s.format.offeredBitDepths.contains(s.bitDepth) { s.bitDepth = s.format.offeredBitDepths[0] }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
