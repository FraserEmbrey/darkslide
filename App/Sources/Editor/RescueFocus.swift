import CoreImage
import CoreML
import Foundation

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
enum RescueFocus {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var modelURL: URL? {
        Bundle.main.url(forResource: "RescueFocus", withExtension: "mlmodelc", subdirectory: "Models")
    }

    static var isAvailable: Bool { modelURL != nil }

    private static let tile = 512
    private static let margin = 48

    private static func model() throws -> MLModel {
        guard let modelURL else { throw Failure(message: "The Rescue Focus model isn't installed.") }
        let config = MLModelConfiguration()
        // the GPU: five times quicker than the Neural Engine for this model
        config.computeUnits = .cpuAndGPU
        return try MLModel(contentsOf: modelURL, configuration: config)
    }

    /// The image with its focus rescued, `amount` (0 to 1) of the way. Its
    /// values go through gamma-encoded in `space`, as the model was trained
    /// on encoded photos, and come back tagged with it.
    static func run(_ image: CIImage, amount: Double, space: CGColorSpace,
                    progress: @Sendable (Double) -> Void = { _ in }) throws -> CIImage {
        let model = try model()
        let extent = image.extent.integral
        let W = Int(extent.width), H = Int(extent.height)
        guard W >= 16, H >= 16 else { throw Failure(message: "The photo is too small.") }

        // the whole picture, RGBA floats
        var pixels = [Float](repeating: 0, count: W * H * 4)
        CIContext().render(image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY)),
                           toBitmap: &pixels, rowBytes: W * 16,
                           bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBAf, colorSpace: space)

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
                progress(Double(j * xs.count + i + 1) / Double(ys.count * xs.count))
            }
        }

        // blended with the original by the amount
        let a = Float(min(max(amount, 0), 1))
        for k in 0..<(W * H) {
            let w = weight[k] > 0 ? 1 / weight[k] : 0
            for c in 0..<3 {
                let v = pixels[k * 4 + c]
                pixels[k * 4 + c] = v + a * (acc[k * 3 + c] * w - v)
            }
            pixels[k * 4 + 3] = 1
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: W * 16, size: CGSize(width: W, height: H), format: .RGBAf, colorSpace: space)
            .transformed(by: .init(translationX: extent.minX, y: extent.minY))
            .settingProperties(image.properties)
    }
}
