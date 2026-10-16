import CoreImage
import CoreML
import Foundation
import Vision

/// Rescuing missed focus: Restormer (Zamir et al., CVPR 2022; MIT licence),
/// trained on DPDD's pairs of real out-of-focus and sharp photos, run with
/// Core ML on the GPU. A transformer whose attention runs across the colour
/// channels rather than the pixels, so a 512 px tile sees all of itself at
/// little cost; it predicts what the blur took away and adds it back. In
/// tests on RealDOF's real defocus pairs it took them from 22.4 to 26.5 dB
/// against the sharp photo; on slight softness it does less than
/// sharpening, so it's for clear misses. Detail that's gone entirely comes
/// back smoothed rather than invented. Tiles overlap by 48 px and are
/// cross-faded. The model is converted by Scripts/fetch-models.sh; without
/// it, Rescue Focus isn't offered.
///
/// For camera shake, the same network trained on GoPro's motion blur. On
/// RealBlur's real shaken photos it gained 0.6 dB on average, up to 3 dB on
/// the worst shake, and lost up to 1 dB on a few: worth it for clear shake,
/// not for slight.
enum RescueFocus {
    enum Kind: String, CaseIterable, Identifiable {
        case focus, shake
        var id: String { rawValue }
        var title: String { self == .focus ? "Missed Focus" : "Camera Shake" }
        fileprivate var resource: String { self == .focus ? "RescueFocus" : "RescueMotion" }
        var modelURL: URL? {
            Bundle.main.url(forResource: resource, withExtension: "mlmodelc", subdirectory: "Models")
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var isAvailable: Bool { Kind.focus.modelURL != nil }
    /// the kinds of blur whose models are installed
    static var kinds: [Kind] { Kind.allCases.filter { $0.modelURL != nil } }

    private static let tile = 512
    private static let margin = 48

    private static func model(_ kind: Kind) throws -> MLModel {
        guard let modelURL = kind.modelURL else { throw Failure(message: "The Rescue Focus model isn't installed.") }
        let config = MLModelConfiguration()
        // the GPU: five times quicker than the Neural Engine for this model
        config.computeUnits = .cpuAndGPU
        return try MLModel(contentsOf: modelURL, configuration: config)
    }

    /// The subjects Vision finds in a photo, so the rescue can be kept to
    /// them: the model also "sharpens" bokeh, which is meant to be soft.
    struct Subjects: @unchecked Sendable {
        let handler: VNImageRequestHandler
        let observation: VNInstanceMaskObservation

        /// nil when Vision finds none
        static func find(in picture: CGImage) throws -> Subjects? {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: picture, options: [:])
            try handler.perform([request])
            guard let o = request.results?.first, !o.allInstances.isEmpty else { return nil }
            return Subjects(handler: handler, observation: o)
        }

        /// the subject under a point (0 to 1 across and down), if there's one there
        func instance(at p: CGPoint) -> Int? {
            let buffer = observation.instanceMask
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
            let x = min(max(Int(p.x * Double(w)), 0), w - 1), y = min(max(Int(p.y * Double(h)), 0), h - 1)
            let label = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).load(fromByteOffset: x, as: UInt8.self)
            return label > 0 && observation.allInstances.contains(Int(label)) ? Int(label) : nil
        }

        /// The soft matte of the subject under `point`, or of all of them when
        /// the point isn't on one, stretched over `extent`, white inside.
        func matte(at point: CGPoint, over extent: CGRect) throws -> CIImage {
            let instances = instance(at: point).map { IndexSet(integer: $0) } ?? observation.allInstances
            let matte = Compositor.matteImage(try observation.generateScaledMaskForImage(forInstances: instances, from: handler))
            let e = matte.extent
            return matte
                .transformed(by: CGAffineTransform(scaleX: extent.width / e.width, y: extent.height / e.height))
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
                .cropped(to: extent)
        }
    }

    /// The image with its focus rescued, `amount` (0 to 1) of the way. Its
    /// values go through gamma-encoded in `space`, as the model was trained
    /// on encoded photos, and come back tagged with it. With a `mask` (a grey
    /// picture over the image, white where to rescue) the rest is left as it
    /// was, and tiles wholly outside it aren't run.
    static func run(_ image: CIImage, kind: Kind = .focus, amount: Double, space: CGColorSpace, mask: CIImage? = nil,
                    progress: @Sendable (Double) -> Void = { _ in }) throws -> CIImage {
        let model = try model(kind)
        let extent = image.extent.integral
        let W = Int(extent.width), H = Int(extent.height)
        guard W >= 16, H >= 16 else { throw Failure(message: "The photo is too small.") }

        // the whole picture, RGBA floats
        var pixels = [Float](repeating: 0, count: W * H * 4)
        CIContext().render(image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY)),
                           toBitmap: &pixels, rowBytes: W * 16,
                           bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBAf, colorSpace: space)
        // the mask's values as they are, one per pixel, top row first as the picture's
        var coverage: [Float]?
        if let mask {
            var m = [Float](repeating: 0, count: W * H)
            CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
                .render(mask.transformed(by: .init(translationX: -extent.minX, y: -extent.minY)),
                        toBitmap: &m, rowBytes: W * 4,
                        bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .Rf, colorSpace: nil)
            coverage = m
        }

        let T = tile, M = margin, step = T - 2 * M
        var acc = [Float](repeating: 0, count: W * H * 3)
        var weight = [Float](repeating: 0, count: W * H)
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: T), NSNumber(value: T)], dataType: .float32)
        let plane = T * T

        func starts(_ n: Int) -> [Int] {
            guard n > T else { return [0] }
            var s = Array(stride(from: 0, to: n - T, by: step))
            s.append(n - T)
            return s
        }
        // a small photo is reflected out to a whole tile
        func mirror(_ i: Int, _ n: Int) -> Int {
            if n <= 1 { return 0 }
            let period = 2 * (n - 1)
            var k = abs(i) % period
            if k >= n { k = period - k }
            return k
        }
        let ys = starts(H), xs = starts(W)
        // full weight in the middle, falling off across the overlap on sides that have a neighbour
        func ramp(_ d: Int, _ inner: Bool) -> Float { inner ? min(1, (Float(d) + 0.5) / Float(2 * M)) : 1 }

        for (j, y0) in ys.enumerated() {
            for (i, x0) in xs.enumerated() {
                defer { progress(Double(j * xs.count + i + 1) / Double(ys.count * xs.count)) }
                if let coverage {
                    var touches = false
                    outer: for y in y0..<min(y0 + T, H) {
                        for x in x0..<min(x0 + T, W) where coverage[y * W + x] > 0.01 { touches = true; break outer }
                    }
                    if !touches { continue }
                }
                input.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in
                    for dy in 0..<T {
                        // pixel rows run top down in the bitmap Core Image rendered
                        let row = mirror(y0 + dy, H)
                        for dx in 0..<T {
                            let s = (row * W + mirror(x0 + dx, W)) * 4
                            for c in 0..<3 { p[c * plane + dy * T + dx] = min(max(pixels[s + c], 0), 1) }
                        }
                    }
                }
                let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": input]))
                guard let o = out.featureValue(for: "output")?.multiArrayValue else {
                    throw Failure(message: "The Rescue Focus model gave no output.")
                }
                let st = o.strides.map(\.intValue)
                let read: (Int) -> Float
                switch o.dataType {
                case .float32:
                    let q = o.dataPointer.assumingMemoryBound(to: Float.self)
                    read = { q[$0] }
                case .float16:
                    let q = o.dataPointer.assumingMemoryBound(to: Float16.self)
                    read = { Float(q[$0]) }
                default:
                    throw Failure(message: "The Rescue Focus model's output is in an unexpected format.")
                }
                let h = min(T, H), w = min(T, W)
                for dy in 0..<h {
                    let wy = min(ramp(dy, j > 0), ramp(h - 1 - dy, j < ys.count - 1))
                    for dx in 0..<w {
                        let wgt = wy * min(ramp(dx, i > 0), ramp(w - 1 - dx, i < xs.count - 1))
                        let k = (y0 + dy) * W + x0 + dx
                        for c in 0..<3 { acc[k * 3 + c] += wgt * read(c * st[1] + dy * st[2] + dx * st[3]) }
                        weight[k] += wgt
                    }
                }
            }
        }

        // blended with the original by the amount, and the mask
        let amount = Float(min(max(amount, 0), 1))
        for k in 0..<(W * H) {
            pixels[k * 4 + 3] = 1
            // a skipped tile's pixels stay as they were
            guard weight[k] > 0 else { continue }
            let a = amount * (coverage?[k] ?? 1), w = 1 / weight[k]
            for c in 0..<3 {
                let v = pixels[k * 4 + c]
                pixels[k * 4 + c] = v + a * (acc[k * 3 + c] * w - v)
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: W * 16, size: CGSize(width: W, height: H), format: .RGBAf, colorSpace: space)
            .transformed(by: .init(translationX: extent.minX, y: extent.minY))
            .settingProperties(image.properties)
    }
}
