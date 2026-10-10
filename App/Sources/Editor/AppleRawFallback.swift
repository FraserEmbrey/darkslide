import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decoding through macOS, for what darktable can't read fully. For raws darktable can't decode (a Hasselblad multi-shot FFF, a camera
/// too new for rawspeed and LibRaw, an iPhone's ProRAW), Apple's raw engine
/// renders the file as Photos shows it, in HDR (its tone curve, local tone
/// mapping and highlights above SDR white), to a half-float linear Rec.2020
/// TIFF in Develop's cache, and darktable edits that as an HDR photo. Everything else refers to the
/// original: the library, Info, exports and the catalog. The edit's sidecar is
/// kept beside the original (photo.fff.xmp) and copied to and from the
/// cached TIFF's on open and save. darktable's raw steps (demosaic, raw white
/// balance) don't run; Apple's decoder has done them.
enum AppleRawFallback {
    /// whether Apple's raw engine can read the file
    static func canDecode(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src) as String? else { return false }
        return type.contains("raw") && CIRAWFilter(imageURL: url) != nil
    }

    /// Apple raw engine versions macOS offers for this file, newest first
    /// ("9", "8", …); empty when it decodes the file without a version
    /// choice (as for Nikon's High Efficiency raws)
    static func decoderVersions(_ url: URL) -> [String] {
        guard let f = CIRAWFilter(imageURL: url) else { return [] }
        return f.supportedDecoderVersions.map(\.rawValue).filter { $0 != "None" }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
    }

    /// The decoded TIFF, made if it's missing or older than the raw, with
    /// the decoder version macOS used. `version` asks for one of
    /// decoderVersions(); nil is the newest.
    static func decodedTIFF(for url: URL, version: String? = nil) throws -> (url: URL, version: String) {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw EngineError(message: "Neither darktable nor macOS can decode \(url.lastPathComponent).")
        }
        // Core Image's default isn't always the newest (a Nikon Z6 II file
        // offers 7, 8 and 9 but defaults to 8), so nil picks the newest here
        if let wanted = version ?? decoderVersions(url).first,
           filter.supportedDecoderVersions.contains(CIRAWDecoderVersion(rawValue: wanted)) {
            filter.decoderVersion = CIRAWDecoderVersion(rawValue: wanted)
        }
        let used = filter.decoderVersion.rawValue
        let tiff = try cacheURL(for: url, suffix: "rawhdr\(used.isEmpty || used == "None" ? "" : used)")
        if isFresh(tiff, for: url) { return (tiff, used) }
        // Apple's own rendering, as Photos shows it: darktable has no tone
        // mapper for a decoded image, and a scene-referred decode looks flat
        // and too bright without one (a ProRAW's +3 EV baseline exposure
        // relies on its tone curve and local tone map)
        filter.extendedDynamicRangeAmount = 1
        guard let image = filter.outputImage else {
            throw EngineError(message: "macOS couldn't decode \(url.lastPathComponent).")
        }
        let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        let context = CIContext(options: [.workingColorSpace: space])
        // macOS reports the size of some raws it can't actually decode (a
        // Hasselblad multi-shot FFF) and returns black; don't edit that
        guard hasContent(image, context: context) else {
            throw EngineError(message: "Neither darktable nor macOS can decode \(url.lastPathComponent). Export it as DNG or TIFF from the camera maker's software (Phocus, for Hasselblad) and open that.")
        }
        try writeTIFF(image, to: tiff, format: .RGBAh, space: space, context: context)
        return (tiff, used)
    }

    /// how a decoder version reads in the interface
    static func versionName(_ v: String) -> String {
        v.isEmpty || v == "None" ? "Apple raw engine" : "Apple RAW \(v.replacingOccurrences(of: "DNG", with: " (DNG)"))"
    }

    /// whether a small render of the decode has anything in it
    private static func hasContent(_ image: CIImage, context: CIContext) -> Bool {
        let scale = 64 / max(image.extent.width, image.extent.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = max(Int(small.extent.width), 1), h = max(Int(small.extent.height), 1)
        var buf = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &buf, rowBytes: w * 16, bounds: small.extent.integral, format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!)
        return stride(from: 0, to: buf.count, by: 4).contains { buf[$0] > 1e-4 || buf[$0 + 1] > 1e-4 || buf[$0 + 2] > 1e-4 }
    }

    // MARK: HDR images

    /// Whether a (non-raw) image holds HDR: a gain map (ISO 21496-1 or Apple's,
    /// as iPhones, Pixel and Ultra HDR JPEGs carry) or an HLG or PQ transfer
    /// (Nikon's HLG HEIF, HDR AVIF). darktable reads only the SDR base of a
    /// gain map image, so these are opened through macOS's HDR decode.
    static func isHDR(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        if hasGainMap(src) { return true }
        // decoding is lazy: creating the image reads its colour space, not its pixels
        if let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
           let space = image.colorSpace {
            return CGColorSpaceUsesITUR_2100TF(space)
        }
        return false
    }

    /// Whether a raw carries an HDR gain map, as an iPhone's ProRAW does (for
    /// its HDR rendering); a raw's colour space isn't checked, which would decode it.
    static func rawHasGainMap(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return false }
        return hasGainMap(src)
    }

    private static func hasGainMap(_ src: CGImageSource) -> Bool {
        [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap].contains {
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, $0) != nil
        }
    }

    /// formats darktable is built without, which macOS reads
    static let appleDecodedExtensions: Set<String> = ["heic", "heif", "hif", "avif", "jxl", "webp", "exr"]

    static func needsAppleDecode(_ url: URL) -> Bool { appleDecodedExtensions.contains(url.pathExtension.lowercased()) }

    /// An SDR image darktable can't read, as a 16-bit TIFF in its own colour
    /// space (with its profile embedded), the right way up.
    static func decodedImage(for url: URL) throws -> URL {
        let tiff = try cacheURL(for: url, suffix: "sdr")
        if isFresh(tiff, for: url) { return tiff }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw EngineError(message: "macOS couldn't decode \(url.lastPathComponent).")
        }
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        try writeTIFF(image, to: tiff, format: .RGBA16, space: space, context: context)
        return tiff
    }

    /// The image with its HDR, as macOS shows it (the gain map applied at full
    /// strength, or HLG/PQ decoded), as a linear floating-point TIFF in
    /// Rec.2020: SDR white is 1.0 and highlights go above it, scene-referred
    /// as darktable expects.
    static func decodedHDR(for url: URL) throws -> URL {
        let tiff = try cacheURL(for: url, suffix: "hdr")
        if isFresh(tiff, for: url) { return tiff }
        guard let image = CIImage(contentsOf: url, options: [.expandToHDR: true, .applyOrientationProperty: true]) else {
            throw EngineError(message: "macOS couldn't decode \(url.lastPathComponent).")
        }
        let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        let context = CIContext(options: [.workingColorSpace: space])
        try writeTIFF(image, to: tiff, format: .RGBAh, space: space, context: context)
        return tiff
    }

    /// Through ImageIO, which writes strips: Core Image can write TIFFs
    /// tiled (it does for half-float), and darktable's TIFF reader doesn't
    /// take tiled ones.
    private static func writeTIFF(_ image: CIImage, to url: URL, format: CIFormat, space: CGColorSpace, context: CIContext) throws {
        guard let cg = context.createCGImage(image, from: image.extent, format: format, colorSpace: space),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw EngineError(message: "Couldn't decode \(url.lastPathComponent).")
        }
        // LZW, which darktable's TIFF reader (libtiff) takes: a 24 MP decode is
        // 196 MB uncompressed
        let props = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary
        CGImageDestinationAddImage(dest, cg, props)
        guard CGImageDestinationFinalize(dest) else { throw EngineError(message: "Couldn't write the decoded image.") }
        trimCache(keeping: url)
    }

    /// The decoded files kept at most, newest used first. A Nikon HE raw
    /// decodes to a couple of hundred megabytes, and a card of them would
    /// otherwise fill the disk as they're opened. Edits are safe: each
    /// decode's sidecar is copied beside the original when saved, and back
    /// when the photo is opened and decoded again.
    static let cacheLimit: Int64 = 6_000_000_000

    private static func trimCache(keeping current: URL) {
        let fm = FileManager.default
        guard let dir = try? cacheDirectory(),
              let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return }
        let tiffs = files.filter { $0.pathExtension == "tif" }.map { f -> (URL, Date, Int64) in
            let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (f, v?.contentModificationDate ?? .distantPast, Int64(v?.fileSize ?? 0))
        }.sorted { $0.1 > $1.1 }
        var total: Int64 = 0
        for (f, _, size) in tiffs {
            total += size
            guard total > cacheLimit, f.standardizedFileURL != current.standardizedFileURL else { continue }
            try? fm.removeItem(at: f)
            try? fm.removeItem(at: URL(fileURLWithPath: f.path + ".xmp"))
        }
    }

    private static func cacheDirectory() throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Develop/decoded", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        return caches
    }

    private static func cacheURL(for url: URL, suffix: String) throws -> URL {
        let caches = try cacheDirectory()
        let key = SHA256.hash(data: Data(url.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return caches.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(key)-\(suffix).tif")
    }

    private static func isFresh(_ tiff: URL, for url: URL) -> Bool {
        let source = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let made = (try? tiff.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let made, made >= source else { return false }
        // marked as used now, so the cache keeps the photos in use (trimCache)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: tiff.path)
        return true
    }

    /// Where the edit of a macOS decode is kept beside the original. For a
    /// raw it's photo.NEF.apple.xmp, apart from darktable's own photo.NEF.xmp:
    /// the two decodes don't share raw-stage steps (darktable's raw white
    /// balance would be applied again to Apple's already balanced image,
    /// turning it purple). For an HDR image it's the usual photo.HEIC.xmp.
    static func sidecar(for original: URL, raw: Bool) -> URL {
        URL(fileURLWithPath: original.path + (raw ? ".apple.xmp" : ".xmp"))
    }

    /// the edit beside the original goes to the decoded TIFF's, if newer
    static func sidecarToDecoded(original: URL, decoded: URL, raw: Bool) {
        let tiffSidecar = URL(fileURLWithPath: decoded.path + ".xmp")
        let mine = sidecar(for: original, raw: raw)
        if FileManager.default.fileExists(atPath: mine.path) {
            copyIfNewer(from: mine, to: tiffSidecar)
        } else {
            // no edit of this decode yet: start fresh, never from another decoder's
            try? FileManager.default.removeItem(at: tiffSidecar)
        }
    }

    /// after saving, the TIFF's sidecar goes beside the original
    static func sidecarToOriginal(original: URL, decoded: URL, raw: Bool) {
        copyIfNewer(from: URL(fileURLWithPath: decoded.path + ".xmp"), to: sidecar(for: original, raw: raw))
    }

    private static func copyIfNewer(from: URL, to: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path) else { return }
        let fromDate = (try? fm.attributesOfItem(atPath: from.path)[.modificationDate]) as? Date ?? .distantPast
        let toDate = (try? fm.attributesOfItem(atPath: to.path)[.modificationDate]) as? Date ?? .distantPast
        guard fromDate > toDate else { return }
        try? fm.removeItem(at: to)
        try? fm.copyItem(at: from, to: to)
    }
}
