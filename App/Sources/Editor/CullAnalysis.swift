import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Vision

/// What culling needs to know about a photo, measured once and kept: when it
/// was taken (to the hundredth of a second, for bursts), what it shows (a
/// Vision feature print, to tell a burst from the next scene), how sharp it
/// is where the camera focused or on the face, whether eyes are shut, and
/// Vision's aesthetic score. Read from the camera's own full-size JPEG (the
/// file itself, or a raw's embedded preview), so nothing is rendered.
struct CullFacts: Codable, Sendable, Equatable {
    /// capture time in seconds since 1970, with the camera's subseconds
    var time: Double?
    /// Vision's overall aesthetic score, -1 to 1
    var aesthetic: Float?
    /// a document, receipt or screenshot rather than a photo, per Vision
    var utility = false
    var faces = 0
    /// the best face's capture quality, 0 to 1 (pose, blur, light, eyes)
    var faceQuality: Float?
    /// the eyes of the main face look shut; nil with no face big enough to tell
    var eyesClosed: Bool?
    /// detail where it matters (the face, else the AF area, else the centre):
    /// only comparable between frames of one scene
    var sharpness: Double = 0
    /// where that was measured, 0 to 1 across and down the photo as shown
    var subject: CGRect?
    /// the camera's own verdict: it found focus (Nikon's Expeed 7 bodies)
    var inFocus: Bool?
    /// an archived VNFeaturePrintObservation
    var print: Data?
}

enum CullAnalysis {
    /// the long edge Vision looks at; detail is measured at full size
    private static let visionPixels = 1024
    /// the most of the subject measured for sharpness, in full-size pixels
    private static let detailPixels = 1024

    // MARK: Measuring

    static func analyse(_ url: URL) -> CullFacts? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        var facts = CullFacts()
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        facts.time = captureTime(props)
        let focus = CameraFocus.read(url)
        facts.inFocus = focus?.inFocus
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1

        guard let full = fullSize(source, url: url) else { return facts }
        let scale = Double(visionPixels) / Double(max(full.width, full.height))
        let small = scale < 1 ? resized(full, scale: scale) ?? full : full

        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        let faces = VNDetectFaceCaptureQualityRequest()
        let print = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: small)
        try? handler.perform([aesthetics, faces, print])

        if let a = aesthetics.results?.first {
            facts.aesthetic = a.overallScore
            facts.utility = a.isUtility
        }
        if let p = print.results?.first {
            facts.print = try? NSKeyedArchiver.archivedData(withRootObject: p, requiringSecureCoding: true)
        }
        let found = faces.results ?? []
        facts.faces = found.count
        facts.faceQuality = found.compactMap(\.faceCaptureQuality).max()

        // Where to measure: the camera's AF area, which follows the subject
        // from frame to frame, so a burst is measured in the same place; else
        // the biggest face; else the middle. (Vision's boxes are 0 to 1 from
        // the bottom left.)
        let face = found.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
        let faceBox = face.map { b in CGRect(x: b.boundingBox.minX, y: 1 - b.boundingBox.maxY,
                                            width: b.boundingBox.width, height: b.boundingBox.height) }
        let region = focus?.box.map { oriented($0, orientation) } ?? faceBox ?? CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
        if let faceBox { facts.eyesClosed = eyesClosed(in: full, face: faceBox) }
        // big enough to judge: at least a tenth of the short side; widened
        // while it's too plain to tell (a dark shirt, a wall)
        let w = Double(full.width), h = Double(full.height)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let minSide = 0.1 * min(w, h)
        var r = CGRect(x: region.minX * w, y: region.minY * h, width: region.width * w, height: region.height * h)
        r = r.insetBy(dx: min(0, (r.width - minSide) / 2), dy: min(0, (r.height - minSide) / 2))
        for attempt in 0..<4 {
            // the middle of a big region is enough
            let m = r.insetBy(dx: max(0, (r.width - Double(detailPixels)) / 2), dy: max(0, (r.height - Double(detailPixels)) / 2))
                .intersection(bounds).integral
            guard let crop = full.cropping(to: m) else { break }
            let d = detail(crop)
            facts.sharpness = d.ratio
            facts.subject = CGRect(x: m.minX / w, y: m.minY / h, width: m.width / w, height: m.height / h)
            if d.energy >= plainEnergy || attempt == 3 { break }
            r = r.insetBy(dx: -r.width / 2, dy: -r.height / 2)
        }
        return facts
    }

    /// the photo at full size, upright: a JPEG or HEIC itself, a raw's largest embedded preview
    static func fullSize(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return fullSize(source, url: url)
    }

    /// The photo at about `pixels` on its long edge, upright, for looking at:
    /// the camera's JPEG, so it's quick.
    static func preview(_ url: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let raw = Library.isRaw(url)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: !raw,
            kCGImageSourceCreateThumbnailFromImageAlways: !raw,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        // an HLG NEF's only big preview is its HDR one
        if raw, Library.isTiny(image) { return NikonHDRPreview.sdrPicture(in: url, maxPixels: pixels) ?? image }
        return image
    }

    private static func fullSize(_ source: CGImageSource, url: URL) -> CGImage? {
        let raw = Library.isRaw(url)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: !raw,
            kCGImageSourceCreateThumbnailFromImageAlways: !raw,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 12000,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        // an HLG NEF has no big JPEG preview: its HDR one, tone mapped
        if raw, Library.isTiny(image) { return NikonHDRPreview.sdrPicture(in: url, maxPixels: 4096) ?? image }
        return image
    }

    private static func resized(_ image: CGImage, scale: Double) -> CGImage? {
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        c.interpolationQuality = .medium
        c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return c.makeImage()
    }

    /// The AF area as the photo is shown: the camera gives it in the sensor's
    /// frame, before the orientation turns the picture upright.
    static func oriented(_ b: CGRect, _ orientation: UInt32) -> CGRect {
        switch orientation {
        case 3: CGRect(x: 1 - b.maxX, y: 1 - b.maxY, width: b.width, height: b.height)
        case 6: CGRect(x: 1 - b.maxY, y: b.minX, width: b.height, height: b.width)   // turned right
        case 8: CGRect(x: b.minY, y: 1 - b.maxX, width: b.height, height: b.width)   // turned left
        default: b
        }
    }

    /// How sharp a patch is: the Laplacian's variance (fine detail) at half
    /// size, over the same at quarter size. Blur takes the fine detail first,
    /// so the ratio falls with blur whatever the patch shows; the energy alone
    /// also rises with how busy the patch is. On RealBlur's real shake it put
    /// a sharp patch above a blurred one of another scene 90% of the time,
    /// the energy alone 82%. Halved first, so sensor noise counts for less.
    private static func detail(_ image: CGImage) -> (ratio: Double, energy: Double) {
        let w = max(8, image.width / 2), h = max(8, image.height / 2)
        let fine = laplacianVariance(image, w, h), coarse = laplacianVariance(image, w / 2, h / 2)
        return (fine / (coarse + 1), fine)
    }

    /// below this Laplacian energy a patch is too plain to judge
    private static let plainEnergy = 40.0

    private static func laplacianVariance(_ image: CGImage, _ w: Int, _ h: Int) -> Double {
        var px = [UInt8](repeating: 0, count: w * h)
        guard let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0 }
        c.interpolationQuality = .medium
        c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0, sum2 = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let l = Double(px[i - 1]) + Double(px[i + 1]) + Double(px[i - w]) + Double(px[i + w]) - 4 * Double(px[i])
                sum += l
                sum2 += l * l
            }
        }
        let n = Double((w - 2) * (h - 2))
        return sum2 / n - (sum / n) * (sum / n)
    }

    /// Both eyes much flatter than open eyes are: height over width of each
    /// eye's outline, found on the face at full size. Only for a face big
    /// enough for the outline to mean something.
    private static func eyesClosed(in full: CGImage, face: CGRect) -> Bool? {
        let w = Double(full.width), h = Double(full.height)
        guard face.height * h >= 120 else { return nil }
        // the face with a margin, as the landmark detector expects
        let r = CGRect(x: face.minX * w, y: face.minY * h, width: face.width * w, height: face.height * h)
            .insetBy(dx: -0.25 * face.width * w, dy: -0.25 * face.height * h)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard let crop = full.cropping(to: r) else { return nil }
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: crop).perform([request])
        guard let marks = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })?.landmarks,
              let left = marks.leftEye, let right = marks.rightEye else { return nil }
        func openness(_ eye: VNFaceLandmarkRegion2D) -> Double? {
            let p = eye.normalizedPoints
            guard p.count >= 4, let minX = p.map(\.x).min(), let maxX = p.map(\.x).max(),
                  let minY = p.map(\.y).min(), let maxY = p.map(\.y).max(), maxX > minX else { return nil }
            return Double((maxY - minY) / (maxX - minX))
        }
        guard let l = openness(left), let r = openness(right) else { return nil }
        return max(l, r) < closedOpenness
    }

    /// below this, an eye outline's height over width reads as shut
    static let closedOpenness = 0.18

    // MARK: Time

    private static func captureTime(_ props: [CFString: Any]?) -> Double? {
        guard let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = f.date(from: text) else { return nil }
        var t = date.timeIntervalSince1970
        if let sub = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String, let digits = Double("0." + sub) { t += digits }
        return t
    }

    // MARK: Bursts

    /// how alike two photos look: 0 the same, larger for less alike
    static func distance(_ a: Data?, _ b: Data?) -> Float? {
        guard let a, let b,
              let pa = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: a),
              let pb = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: b)
        else { return nil }
        var d: Float = 0
        return (try? pa.computeDistance(&d, to: pb)) != nil ? d : nil
    }

    /// a burst: frames this close together in time, and this alike
    static let burstGap = 1.5
    static let burstDistance: Float = 0.6

    /// Photos in order, split into bursts: runs taken close together that
    /// look alike. A photo on its own is a run of one.
    static func bursts(_ photos: [URL], facts: [URL: CullFacts]) -> [[URL]] {
        var runs: [[URL]] = []
        var prints: [URL: VNFeaturePrintObservation] = [:]
        func print(_ u: URL) -> VNFeaturePrintObservation? {
            if let p = prints[u] { return p }
            guard let d = facts[u]?.print,
                  let p = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: d) else { return nil }
            prints[u] = p
            return p
        }
        for u in photos {
            if let last = runs.last?.last, let t0 = facts[last]?.time, let t1 = facts[u]?.time,
               abs(t1 - t0) <= burstGap {
                var d: Float = 0
                if let a = print(last), let b = print(u), (try? a.computeDistance(&d, to: b)) != nil, d <= burstDistance {
                    runs[runs.count - 1].append(u)
                    continue
                }
            }
            runs.append([u])
        }
        return runs
    }

    /// The frame of a burst to keep: the sharpest where it matters, with eyes
    /// open, faces well caught and the camera's focus found counting too.
    static func best(of run: [URL], facts: [URL: CullFacts]) -> URL? {
        guard run.count > 1 else { return run.first }
        let top = run.compactMap { facts[$0]?.sharpness }.max() ?? 0
        return run.max { score($0, top: top, facts) < score($1, top: top, facts) }
    }

    static func score(_ u: URL, top: Double, _ facts: [URL: CullFacts]) -> Double {
        guard let f = facts[u] else { return -10 }
        var s = top > 0 ? f.sharpness / top : 0
        if let q = f.faceQuality { s += 0.3 * Double(q) }
        if f.eyesClosed == true { s -= 0.6 }
        if f.inFocus == false { s -= 0.3 }
        if let a = f.aesthetic { s += 0.1 * Double(a) }
        return s
    }

    // MARK: Keeping

    /// Facts for a folder's photos, kept in Caches, each against the file's
    /// size and modification date so a changed file is measured again.
    struct Store: Codable {
        struct Entry: Codable { var size: Int; var modified: Double; var facts: CullFacts }
        var entries: [String: Entry] = [:]
    }

    /// bump when what's measured changes, so old stores are measured afresh
    static let version = 1

    static func storeURL(for folder: URL) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let digest = SHA256.hash(data: Data("\(version)|\(folder.standardizedFileURL.path)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return caches.appendingPathComponent("Darkslide/cull/\(digest.prefix(32)).plist")
    }

    static func load(_ folder: URL) -> Store {
        guard let file = storeURL(for: folder), let data = try? Data(contentsOf: file),
              let store = try? PropertyListDecoder().decode(Store.self, from: data) else { return Store() }
        return store
    }

    static func save(_ store: Store, for folder: URL) {
        guard let file = storeURL(for: folder) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try? encoder.encode(store).write(to: file, options: .atomic)
    }

    /// the size and date a store entry is checked against
    static func stamp(_ url: URL) -> (size: Int, modified: Double)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = a[.size] as? Int, let date = a[.modificationDate] as? Date else { return nil }
        return (size, date.timeIntervalSince1970)
    }
}
