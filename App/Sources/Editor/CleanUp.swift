import CoreImage
import CoreML
import Foundation

/// Remove Objects: things painted over are filled in by LaMa (Samsung's
/// "big-lama", Apache-2.0, converted to Core ML at 512 × 512 by
/// Scripts/models/convert_lama.py), laid over darktable's output.
///
/// darktable has no way to hold pixels a model made, so this is Darkslide's
/// own layer, like AI denoise's amount: the marks are kept in the catalog, in
/// darktable's input coordinates (so a crop or rotation leaves them on their
/// objects), and filled again on each final render around them, so the fill
/// follows the edit beneath. darktable doesn't see it. Exports fill at their
/// own resolution. Tools/inpaintlab/README.md has what the model does well.

/// One painted stroke: points in darktable's input, normalised (0...1), and
/// the brush's radius as a fraction of the input's shorter side.
struct CleanUpMark: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var points: [CGPoint]
    var radius: Double
}

/// A mark placed on an image: its points and radius in that image's pixels,
/// top-left origin.
struct PlacedMark: Sendable, Equatable {
    var points: [CGPoint]
    var radius: Double

    var bounds: CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()! - radius, y: ys.min()! - radius,
                      width: xs.max()! - xs.min()! + 2 * radius, height: ys.max()! - ys.min()! + 2 * radius)
    }

    /// in another image of the same picture, `k` times the size, offset by (dx, dy)
    func scaled(_ k: Double, dx: Double = 0, dy: Double = 0) -> PlacedMark {
        PlacedMark(points: points.map { CGPoint(x: $0.x * k - dx, y: $0.y * k - dy) }, radius: radius * k)
    }
}

/// Fills marks with LaMa, one at a time.
actor Inpainter {
    static let shared = Inpainter()
    static let side = 512
    /// the square around a mark, as a multiple of its size: LaMa needs the
    /// context, and less made both test objects worse (Tools/inpaintlab)
    static let context = 3.0

    private var model: MLModel?

    static var isAvailable: Bool { ModelStore.installedURL(.removeObjects) != nil }

    private func loaded() throws -> MLModel {
        if let model { return model }
        guard let url = ModelStore.installedURL(.removeObjects) else {
            throw ModelStore.Failure(message: "The Remove Objects model isn't installed.")
        }
        let config = MLModelConfiguration()
        // not the Neural Engine: its half precision wove a lattice into fills
        // (the Fourier convolutions, as macOS 27 runs them) and smeared them;
        // the GPU's are clean and as quick once it's warm
        config.computeUnits = .cpuAndGPU
        let m = try MLModel(contentsOf: url, configuration: config)
        model = m
        return m
    }

    /// Loads the model and runs it once, so the first stroke doesn't wait
    /// for Core ML to prepare it (a second or two on the GPU).
    func prepare() {
        guard model == nil, let m = try? loaded() else { return }
        let n = Self.side
        guard let img = try? MLMultiArray(shape: [1, 3, NSNumber(value: n), NSNumber(value: n)], dataType: .float32),
              let msk = try? MLMultiArray(shape: [1, 1, NSNumber(value: n), NSNumber(value: n)], dataType: .float32),
              let input = try? MLDictionaryFeatureProvider(dictionary: ["image": img, "mask": msk]) else { return }
        _ = try? m.prediction(from: input)
    }

    /// The image with each mark filled. `headroom` is the image's peak over
    /// SDR white (1 for SDR): values are brought into 0...1 for the model,
    /// which knows SDR pictures, and back after. `encoded` is for an image
    /// whose values are already a display encoding and not colour managed (an
    /// export read as darktable wrote it): those go to the model as they are.
    func fill(_ image: CIImage, marks: [PlacedMark], headroom: Double = 1, encoded: Bool = false) throws -> CIImage {
        // The work is in encoded values, as the model was trained on and as
        // grain is even: shrinking in linear light made a noisy photo's fill
        // lighter than the grain round it, which the eye averages otherwise.
        let values = encoded ? image
            : image.applyingFilter("CIColorMatrix", parameters: Self.gain(1 / headroom)).applyingFilter("CILinearToSRGBToneCurve")
        var filledValues = values
        let extent = image.extent
        let n = Self.side
        for mark in marks where !mark.points.isEmpty {
            let b = mark.bounds
            let side = min(max(max(b.width, b.height) * Self.context, Double(n) / 2), min(extent.width, extent.height))
            // the square, top-left origin, kept on the image
            let sq = CGRect(x: min(max(b.midX - side / 2, 0), extent.width - side),
                            y: min(max(b.midY - side / 2, 0), extent.height - side), width: side, height: side).integral
            let k = Double(n) / sq.width
            // CI's origin is bottom left
            let ciSquare = CGRect(x: extent.minX + sq.minX, y: extent.maxY - sq.maxY, width: sq.width, height: sq.height)
            let square = filledValues.cropped(to: ciSquare)

            // the square at 512, filtered as it shrinks: a plain scale aliased
            // the grain into a pattern the model then carried on
            let scaled = square.transformed(by: CGAffineTransform(translationX: -ciSquare.minX, y: -ciSquare.minY))
                .clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
            var rgba = [UInt8](repeating: 0, count: n * n * 4)
            Self.valuesContext.render(scaled, toBitmap: &rgba, rowBytes: n * 4, bounds: CGRect(x: 0, y: 0, width: n, height: n),
                                      format: .RGBA8, colorSpace: nil)

            // the mark over the square, at 512
            let local = mark.scaled(k, dx: sq.minX * k, dy: sq.minY * k)
            let hole = Self.raster(local, width: n, height: n, grow: 1.15)

            let img = try MLMultiArray(shape: [1, 3, NSNumber(value: n), NSNumber(value: n)], dataType: .float32)
            let msk = try MLMultiArray(shape: [1, 1, NSNumber(value: n), NSNumber(value: n)], dataType: .float32)
            let ip = img.dataPointer.assumingMemoryBound(to: Float.self), mp = msk.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<(n * n) {
                for c in 0..<3 { ip[c * n * n + i] = Float(rgba[i * 4 + c]) / 255 }
                mp[i] = hole[i] > 127 ? 1 : 0
            }
            let out = try loaded().prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": img, "mask": msk]))
                .featureValue(for: "output")!.multiArrayValue!
            func value(_ i: Int) -> Float {
                out.dataType == .float16 ? Float(out.dataPointer.assumingMemoryBound(to: Float16.self)[i])
                                         : out.dataPointer.assumingMemoryBound(to: Float.self)[i]
            }
            for i in 0..<(n * n) {
                for c in 0..<3 { rgba[i * 4 + c] = UInt8(max(0, min(255, value(c * n * n + i) * 255 + 0.5))) }
                rgba[i * 4 + 3] = 255
            }

            // the mark at full size: hard for measuring the grain round it, soft for laying the fill in
            let maskSize = (Int(sq.width), Int(sq.height))
            func maskImage(grow: Double) -> CIImage {
                let px = Self.raster(mark.scaled(1, dx: sq.minX, dy: sq.minY), width: maskSize.0, height: maskSize.1, grow: grow)
                return CIImage(bitmapData: Data(px.flatMap { [$0, $0, $0, 255] }), bytesPerRow: maskSize.0 * 4,
                               size: CGSize(width: maskSize.0, height: maskSize.1), format: .RGBA8, colorSpace: nil)
                    .transformed(by: CGAffineTransform(translationX: ciSquare.minX, y: ciSquare.minY))
            }

            // back over the square, with the photo's grain, which the model
            // (seeing it at a fraction of its size) can't make
            let filled = CIImage(bitmapData: Data(rgba), bytesPerRow: n * 4, size: CGSize(width: n, height: n),
                                 format: .RGBA8, colorSpace: nil)
                .clampedToExtent()
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 1 / k, kCIInputAspectRatioKey: 1])
                .transformed(by: CGAffineTransform(translationX: ciSquare.minX, y: ciSquare.minY))
                .cropped(to: ciSquare)
            let grainy = Self.grain(like: square, outside: maskImage(grow: 1.3), in: ciSquare).map { Self.add(filled, $0) } ?? filled
            let soft = maskImage(grow: 1.1)
                .clampedToExtent()
                .applyingGaussianBlur(sigma: max(2, mark.radius * 0.25))
                .cropped(to: ciSquare)
            filledValues = grainy.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: filledValues, kCIInputMaskImageKey: soft,
            ]).cropped(to: extent)
        }
        return encoded ? filledValues
            : filledValues.applyingFilter("CISRGBToneCurveToLinear").applyingFilter("CIColorMatrix", parameters: Self.gain(headroom))
    }

    /// Grain for a fill: noise, a little softened as a raw's is by
    /// demosaicing, at the strength of the detail finer than a couple of
    /// pixels in `square` outside the mark (white over the mark), channel by
    /// channel. Most of that detail is the grain, on the flat things a fill
    /// usually goes over. Zero-mean, to add; nil for a clean photo.
    private static func grain(like square: CIImage, outside mark: CIImage, in rect: CGRect) -> CIImage? {
        let around = mark.applyingFilter("CIColorInvert").cropped(to: rect)
        func fine(_ image: CIImage) -> CIImage {
            // the image less its blur, by adding the blur negated: blend modes clamp at 0
            add(image, image.clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: rect)
                .applyingFilter("CIColorMatrix", parameters: gain(-1)))
        }
        /// the mean square of each channel's fine detail, where `weight` is white
        func power(_ image: CIImage, weight: CIImage) -> [Double] {
            let f = fine(image)
            let sq = f.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: f])
                .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weight])
            let total = mean(sq, in: rect), w = mean(weight, in: rect)
            return w[0] > 0.01 ? total.prefix(3).map { $0 / w[0] } : []
        }
        let noise = noise(in: rect)
        let photo = power(square, weight: around)
        let made = power(noise, weight: CIImage(color: .white).cropped(to: rect))
        guard photo.count == 3, made.count == 3, made.allSatisfy({ $0 > 0 }) else { return nil }
        let k = (0..<3).map { min(sqrt(photo[$0] / made[$0]), 4) }
        guard k.max()! * sqrt(made.max()!) > 0.002 else { return nil }
        return noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k[0], y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k[1], z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k[2], w: 0),
        ])
    }

    /// `a` + `b`, both opaque. Core Image's filters work on colour divided by
    /// alpha, and adding sums the alphas too, so the sum's colour is doubled
    /// back and its alpha set to 1.
    static func add(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 2, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 2, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 2, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
    }

    /// zero-mean noise over `rect`, a little softened as a raw's is by
    /// demosaicing: mostly the same in each channel, with some colour
    private static func noise(in rect: CGRect) -> CIImage {
        noiseTile.applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: CGAffineTransform.identity])
            .applyingGaussianBlur(sigma: 0.6)
            .cropped(to: rect)
    }

    /// Gaussian noise, opaque, the same every time so a fill's grain stays put
    /// between renders. (CIRandomGenerator's alpha is random too, which
    /// Core Image's filters divide by.)
    private static let noiseTile: CIImage = {
        let n = 512
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func uniform() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(state >> 40) + 0.5) / Float(1 << 24)
        }
        func gaussian() -> Float { sqrt(-2 * log(uniform())) * cos(2 * .pi * uniform()) }
        var px = [Float](repeating: 1, count: n * n * 4)
        for i in 0..<(n * n) {
            let luma = gaussian() * 0.8
            for c in 0..<3 { px[i * 4 + c] = luma + gaussian() * 0.5 }
        }
        return CIImage(bitmapData: Data(bytes: px, count: px.count * 4), bytesPerRow: n * 16,
                       size: CGSize(width: n, height: n), format: .RGBAf, colorSpace: nil)
    }()

    /// each channel's mean over `rect`
    private static func mean(_ image: CIImage, in rect: CGRect) -> [Double] {
        var px = [Float](repeating: 0, count: 4)
        valuesContext.render(image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)]),
                             toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                             format: .RGBAf, colorSpace: nil)
        return px.map(Double.init)
    }

    /// Renders values as they are in the working space (with no colour space
    /// given), while a photo with a colour space is brought into it; an
    /// export read as darktable encoded it has none, so it's left as it is.
    /// Full precision, for the grain's small numbers.
    private static let valuesContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                                          .workingFormat: CIFormat.RGBAf])

    /// a colour matrix scaling RGB by `g`, in the linear working space
    private static func gain(_ g: Double) -> [String: Any] {
        ["inputRVector": CIVector(x: g, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
         "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0)]
    }

    /// a mark drawn as one byte a pixel, top row first; `grow` widens the brush
    static func raster(_ mark: PlacedMark, width: Int, height: Int, grow: Double) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return px }
        // top-left origin
        ctx.translateBy(x: 0, y: Double(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setLineWidth(mark.radius * 2 * grow)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if mark.points.count == 1 {
            let p = mark.points[0], r = mark.radius * grow
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        } else {
            ctx.addLines(between: mark.points)
            ctx.strokePath()
        }
        return px
    }
}

extension Inpainter {
    /// A filled frame as a CGImage like the frame it came from: 8-bit SDR, or
    /// half-float HDR with its headroom, so the canvas shows it the same way.
    nonisolated static func image(_ ci: CIImage, like frame: CGImage) -> CGImage? {
        let w = frame.width, h = frame.height
        let space = frame.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        if frame.contentHeadroom > 1 {
            var px = [Float](repeating: 0, count: w * h * 4)
            renderContext.render(ci, toBitmap: &px, rowBytes: w * 16, bounds: rect, format: .RGBAf, colorSpace: space)
            guard let provider = CGDataProvider(data: Data(bytes: px, count: px.count * 4) as CFData) else { return nil }
            let info = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
            return CGImage(headroom: frame.contentHeadroom, width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 128,
                           bytesPerRow: w * 16, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        return renderContext.createCGImage(ci, from: rect, format: .RGBA8, colorSpace: space)
    }

    nonisolated private static let renderContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
}
