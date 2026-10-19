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
    /// detail where it matters (on the person the camera focused on, else
    /// the most prominent person, else the AF area, the face or the middle):
    /// only comparable between frames of one scene
    var sharpness: Double = 0
    /// whether the camera's AF area was on a person; nil with no one in the
    /// frame. Off a person, the camera likely focused on the background.
    var focusOnSubject: Bool?
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

    private static let personLock = NSLock()

    /// Measures a photo on a dispatch thread, not a Swift task's: Vision
    /// waits on its own queues, and a task's thread blocked there isn't
    /// replaced, so a few at once could stall every task in the app.
    static func analyseOffPool(_ url: URL) async -> CullFacts? {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async { done.resume(returning: analyse(url)) }
        }
    }

    // MARK: Measuring

    static func analyse(_ url: URL) -> CullFacts? {
        guard let source = CGImageSourceCreateWithURL(url.photoFile as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
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
        let people = VNGeneratePersonInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: small)
        try? handler.perform([aesthetics, faces, print])
        // one at a time: several at once deadlocked inside Vision
        personLock.withLock { try? handler.perform([people]) }

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

        // Vision's boxes are 0 to 1 from the bottom left; these are from the top left
        let face = found.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
        let faceBox = face.map { b in CGRect(x: b.boundingBox.minX, y: 1 - b.boundingBox.maxY,
                                            width: b.boundingBox.width, height: b.boundingBox.height) }
        if let faceBox { facts.eyesClosed = eyesClosed(in: full, face: faceBox) }
        let af = focus?.box.map { oriented($0, orientation) }
        let w = Double(full.width), h = Double(full.height)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)

        // Where to measure. A person: the one the camera's AF area is on, else
        // the most prominent, with the background masked out, so a sharp
        // background behind a soft subject doesn't count as sharp.
        if let person = Person.find(people.results?.first, af: af) {
            facts.focusOnSubject = person.underAF
            var r = CGRect(x: person.box.minX * w, y: person.box.minY * h, width: person.box.width * w, height: person.box.height * h)
            // a tall figure: the part where focus matters, around the AF area
            // on them, else their head and shoulders
            let centre = person.underAF ? CGPoint(x: af!.midX * w, y: af!.midY * h)
                : CGPoint(x: r.midX, y: r.minY + min(r.height, r.width * 1.5) * 0.3)
            let side = Double(detailPixels)
            if r.width > side { r = CGRect(x: min(max(centre.x - side / 2, r.minX), r.maxX - side), y: r.minY, width: side, height: r.height) }
            if r.height > side { r = CGRect(x: r.minX, y: min(max(centre.y - side / 2, r.minY), r.maxY - side), width: r.width, height: side) }
            r = r.intersection(bounds).integral
            if let crop = full.cropping(to: r) {
                let box = CGRect(x: r.minX / w, y: r.minY / h, width: r.width / w, height: r.height / h)
                facts.sharpness = detail(crop) { x, y in person.contains(CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height)) }.ratio
                facts.subject = box
                return facts
            }
        }

        // No one: the camera's AF area, else the biggest face, else the middle;
        // at least a tenth of the short side, widened while it's too plain to
        // tell (a dark shirt, a wall)
        let region = af ?? faceBox ?? CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
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
        guard let source = CGImageSourceCreateWithURL(url.photoFile as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return fullSize(source, url: url)
    }

    /// The photo at about `pixels` on its long edge, upright, for looking at:
    /// the camera's JPEG, so it's quick.
    static func preview(_ url: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url.photoFile as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
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
    private static func detail(_ image: CGImage, inside: ((Double, Double) -> Bool)? = nil) -> (ratio: Double, energy: Double) {
        let w = max(8, image.width / 2), h = max(8, image.height / 2)
        let fine = laplacianVariance(image, w, h, inside: inside), coarse = laplacianVariance(image, w / 2, h / 2, inside: inside)
        return (fine / (coarse + 1), fine)
    }

    /// below this Laplacian energy a patch is too plain to judge
    private static let plainEnergy = 40.0

    /// `inside`: where to count, 0 to 1 across and down the patch; a pixel
    /// counts when it and the pixels a few away on each side are inside, so
    /// the outline (where the mask is rough) doesn't
    private static func laplacianVariance(_ image: CGImage, _ w: Int, _ h: Int, inside: ((Double, Double) -> Bool)? = nil) -> Double {
        var px = [UInt8](repeating: 0, count: w * h)
        guard let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0 }
        c.interpolationQuality = .medium
        c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var mask: [Bool]?
        if let inside {
            var m = [Bool](repeating: false, count: w * h)
            for y in 0..<h { for x in 0..<w { m[y * w + x] = inside((Double(x) + 0.5) / Double(w), (Double(y) + 0.5) / Double(h)) } }
            // shrunk by about 3% of the patch
            let k = max(1, max(w, h) / 32)
            var eroded = m
            for y in 0..<h {
                for x in 0..<w where m[y * w + x] {
                    if x < k || y < k || x >= w - k || y >= h - k
                        || !m[y * w + x - k] || !m[y * w + x + k] || !m[(y - k) * w + x] || !m[(y + k) * w + x] {
                        eroded[y * w + x] = false
                    }
                }
            }
            // too little of the person left to judge: the whole patch
            if eroded.lazy.filter({ $0 }).count >= w * h / 20 { mask = eroded }
        }
        var sum = 0.0, sum2 = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                if let mask, !mask[i] { continue }
                let l = Double(px[i - 1]) + Double(px[i + 1]) + Double(px[i - w]) + Double(px[i + w]) - 4 * Double(px[i])
                sum += l
                sum2 += l * l
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        return sum2 / n - (sum / n) * (sum / n)
    }

    /// One person Vision found: their outline, to measure only them.
    private struct Person {
        let labels: [UInt8]
        let width: Int, height: Int
        let label: UInt8
        /// 0 to 1 from the top left
        let box: CGRect
        let underAF: Bool

        func contains(_ p: CGPoint) -> Bool {
            let x = min(max(Int(p.x * Double(width)), 0), width - 1), y = min(max(Int(p.y * Double(height)), 0), height - 1)
            return labels[y * width + x] == label
        }

        /// The person the AF area is most on, else the biggest (the
        /// subject, most likely); nil with no one in the frame, or only
        /// specks (people far off in the background).
        static func find(_ o: VNInstanceMaskObservation?, af: CGRect?) -> Person? {
            guard let o, !o.allInstances.isEmpty else { return nil }
            let buffer = o.instanceMask
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
            var labels = [UInt8](repeating: 0, count: w * h)
            var area: [UInt8: Int] = [:]
            var extent: [UInt8: (Int, Int, Int, Int)] = [:]
            for y in 0..<h {
                let r = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    let l = r[x]
                    labels[y * w + x] = l
                    guard l > 0 else { continue }
                    area[l, default: 0] += 1
                    let e = extent[l] ?? (x, y, x, y)
                    extent[l] = (min(e.0, x), min(e.1, y), max(e.2, x), max(e.3, y))
                }
            }
            // people big enough to be the subject: a fiftieth of the frame
            let candidates = area.filter { $0.value >= w * h / 50 }
            guard !candidates.isEmpty else { return nil }
            var chosen: UInt8?
            var underAF = false
            if let af {
                // the person covering most of the AF area
                var under: [UInt8: Int] = [:]
                let x0 = Int(af.minX * Double(w)), x1 = max(x0 + 1, Int(af.maxX * Double(w)))
                let y0 = Int(af.minY * Double(h)), y1 = max(y0 + 1, Int(af.maxY * Double(h)))
                for y in max(0, y0)..<min(h, y1) { for x in max(0, x0)..<min(w, x1) where labels[y * w + x] > 0 { under[labels[y * w + x], default: 0] += 1 } }
                if let best = under.max(by: { $0.value < $1.value }), area[best.key] != nil {
                    chosen = best.key
                    underAF = true
                }
            }
            if chosen == nil { chosen = candidates.max { $0.value < $1.value }?.key }
            guard let label = chosen, let e = extent[label] else { return nil }
            let box = CGRect(x: Double(e.0) / Double(w), y: Double(e.1) / Double(h),
                             width: Double(e.2 - e.0 + 1) / Double(w), height: Double(e.3 - e.1 + 1) / Double(h))
            return Person(labels: labels, width: w, height: h, label: label, box: box, underAF: underAF)
        }
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

    /// A burst: frames close together in time, and alike. Close means within
    /// a second and a half of a photo on its own; within a burst, within
    /// four times its own pace (half a second at least), so the next
    /// press of the shutter starts a new one: high-speed frames come every
    /// hundredth of a second, a second apart is another burst.
    static let burstGap = 1.5
    static let burstDistance: Float = 0.6

    /// Photos in order, split into bursts. A photo on its own is a run of one.
    static func bursts(_ photos: [URL], facts: [URL: CullFacts]) -> [[URL]] {
        var prints: [URL: VNFeaturePrintObservation] = [:]
        return bursts(photos, facts: facts, prints: &prints)
    }

    /// `prints`: feature prints already unarchived, kept between calls
    static func bursts(_ photos: [URL], facts: [URL: CullFacts], prints: inout [URL: VNFeaturePrintObservation]) -> [[URL]] {
        var runs: [[URL]] = []
        func print(_ u: URL) -> VNFeaturePrintObservation? {
            if let p = prints[u] { return p }
            guard let d = facts[u]?.print,
                  let p = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: d) else { return nil }
            prints[u] = p
            return p
        }
        func limit(_ run: [URL]) -> Double {
            let times = run.compactMap { facts[$0]?.time }
            guard times.count >= 2 else { return burstGap }
            let steps = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
            return min(burstGap, max(0.5, 4 * steps[steps.count / 2]))
        }
        for u in photos {
            if let run = runs.last, let last = run.last, let t0 = facts[last]?.time, let t1 = facts[u]?.time,
               abs(t1 - t0) <= limit(run) {
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
        if f.focusOnSubject == false { s -= 0.2 }
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
    static let version = 2

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
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.photoFile.path),
              let size = a[.size] as? Int, let date = a[.modificationDate] as? Date else { return nil }
        return (size, date.timeIntervalSince1970)
    }
}
