import Accelerate
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Enlarging on export, as Lightroom's Super Resolution and Pixelmator's do:
/// Apple's super resolution scaler (VideoToolbox, macOS 26), which comes with
/// macOS and runs on the Neural Engine. In tests on public samples it gave
/// slightly crisper edges than plain resampling without inventing texture,
/// unlike Real-ESRGAN and BSRGAN. It only enlarges 4× and takes at most
/// 1920 px a side, so a photo goes through in overlapping tiles, each cut at
/// the middle of its overlap; 2× is 4× brought down by half, tile by tile.
enum Upscaler {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// the factors offered: 4× is the scaler's own, 2× is 4× then halved
    static let factors = [2, 4]

    static var isAvailable: Bool {
        VTSuperResolutionScalerConfiguration.isSupported
            && VTSuperResolutionScalerConfiguration.supportedScaleFactors.contains(4)
    }

    private static let maxTile = 1920
    /// overlap either side of a cut, in source pixels: past the scaler's edge effects
    private static let margin = 32

    /// The image enlarged by `factor`. Its pixel values go through as they are
    /// when `space` is nil (an image already in its export encoding);
    /// otherwise it's rendered in `space` first, which should be a
    /// gamma-encoded one (PQ for HDR), and comes back tagged with it.
    static func enlarge(_ image: CIImage, by factor: Int, space: CGColorSpace?,
                        progress: @Sendable (Double) -> Void = { _ in }) async throws -> CIImage {
        guard factors.contains(factor) else { throw Failure(message: "Enlarging works at 2× or 4×.") }
        let extent = image.extent.integral
        let W = Int(extent.width), H = Int(extent.height)
        let tw = min(maxTile, W), th = min(maxTile, H)
        guard isAvailable,
              let config = VTSuperResolutionScalerConfiguration(
                  frameWidth: tw, frameHeight: th, scaleFactor: 4, inputType: .image,
                  usePrecomputedFlow: false, qualityPrioritization: .normal, revision: .revision1)
        else { throw Failure(message: "This Mac can't enlarge \(W) × \(H) px photos with Apple's scaler.") }
        let format = kCVPixelFormatType_64RGBAHalf
        guard config.__frameSupportedPixelFormats.map(\.uint32Value).contains(format) else {
            throw Failure(message: "Apple's scaler doesn't take half-float images.")
        }
        if config.configurationModelStatus != .ready {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                config.downloadConfigurationModel { e in if let e { k.resume(throwing: e) } else { k.resume() } }
            }
        }

        // the whole source, as half floats
        let context = space == nil ? CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
                                   : CIContext()
        let srcRow = W * 8
        var source = Data(count: srcRow * H)
        source.withUnsafeMutableBytes { raw in
            context.render(image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY)),
                           toBitmap: raw.baseAddress!, rowBytes: srcRow,
                           bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBAh, colorSpace: space)
        }

        let OW = W * factor, OH = H * factor
        let outRow = OW * 8
        var output = Data(count: outRow * OH)
        let xs = starts(length: W, tile: tw), ys = starts(length: H, tile: th)

        func buffer(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
            var b: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &b)
            guard let b else { throw Failure(message: "Not enough memory to enlarge the photo.") }
            return b
        }
        let input = try buffer(tw, th)
        let scaled = try buffer(tw * 4, th * 4)
        let halved = factor == 2 ? try buffer(tw * 2, th * 2) : nil

        let processor = VTFrameProcessor()
        try processor.startSession(configuration: config)
        defer { processor.endSession() }
        let time = CMTime(value: 0, timescale: 1)

        for (j, y0) in ys.enumerated() {
            for (i, x0) in xs.enumerated() {
                // the tile in
                CVPixelBufferLockBaseAddress(input, [])
                let inBase = CVPixelBufferGetBaseAddress(input)!, inRow = CVPixelBufferGetBytesPerRow(input)
                source.withUnsafeBytes { s in
                    for r in 0..<th {
                        memcpy(inBase + r * inRow, s.baseAddress! + (y0 + r) * srcRow + x0 * 8, tw * 8)
                    }
                }
                CVPixelBufferUnlockBaseAddress(input, [])

                guard let src = VTFrameProcessorFrame(buffer: input, presentationTimeStamp: time),
                      let dst = VTFrameProcessorFrame(buffer: scaled, presentationTimeStamp: time),
                      let params = VTSuperResolutionScalerParameters(
                          sourceFrame: src, previousFrame: nil, previousOutputFrame: nil, opticalFlow: nil,
                          submissionMode: .random, destinationFrame: dst)
                else { throw Failure(message: "Couldn't set up Apple's scaler.") }
                try await processor.process(parameters: params)

                let result = halved ?? scaled
                if let halved { try halve(scaled, into: halved) }

                // the part this tile owns: up to the middle of each overlap
                let cx0 = i == 0 ? 0 : (xs[i - 1] + tw + x0) / 2
                let cx1 = i == xs.count - 1 ? W : (x0 + tw + xs[i + 1]) / 2
                let cy0 = j == 0 ? 0 : (ys[j - 1] + th + y0) / 2
                let cy1 = j == ys.count - 1 ? H : (y0 + th + ys[j + 1]) / 2
                CVPixelBufferLockBaseAddress(result, .readOnly)
                let rBase = CVPixelBufferGetBaseAddress(result)!, rRow = CVPixelBufferGetBytesPerRow(result)
                output.withUnsafeMutableBytes { o in
                    for oy in (cy0 * factor)..<(cy1 * factor) {
                        memcpy(o.baseAddress! + oy * outRow + cx0 * factor * 8,
                               rBase + (oy - y0 * factor) * rRow + (cx0 - x0) * factor * 8,
                               (cx1 - cx0) * factor * 8)
                    }
                }
                CVPixelBufferUnlockBaseAddress(result, .readOnly)
                progress(Double(j * xs.count + i + 1) / Double(xs.count * ys.count))
            }
        }
        let enlarged = CIImage(bitmapData: output, bytesPerRow: outRow, size: CGSize(width: OW, height: OH),
                               format: .RGBAh, colorSpace: space)
        return enlarged.settingProperties(resized(image.properties, width: OW, height: OH))
    }

    /// An HDR image at the enlarged size: the enlarged SDR image times the
    /// ratio of the HDR image to the SDR one, which is resampled smoothly, as
    /// a gain map is. In linear light, worked out here as Core Image's divide
    /// stops at 1; the small offset keeps black finite.
    static func carryHDR(from hdr: CIImage, sdr: CIImage, onto big: CIImage) -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let extent = sdr.extent.integral
        let w = Int(extent.width), h = Int(extent.height), n = w * h * 4
        let context = CIContext(options: [.workingColorSpace: space])
        func pixels(_ i: CIImage) -> [Float] {
            var p = [Float](repeating: 0, count: n)
            context.render(i, toBitmap: &p, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: space)
            return p
        }
        var top = pixels(hdr), bottom = pixels(sdr)
        var lift: Float = 1e-4
        vDSP_vsadd(top, 1, &lift, &top, 1, vDSP_Length(n))
        vDSP_vsadd(bottom, 1, &lift, &bottom, 1, vDSP_Length(n))
        vDSP_vdiv(bottom, 1, top, 1, &top, 1, vDSP_Length(n))     // top / bottom
        let ratio = CIImage(bitmapData: top.withUnsafeBytes { Data($0) }, bytesPerRow: w * 16, size: extent.size,
                            format: .RGBAf, colorSpace: space)
            .transformed(by: .init(translationX: extent.minX, y: extent.minY))
        let scale = big.extent.width / extent.width
        let smooth = ratio.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            .cropped(to: big.extent)
        return big.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: smooth])
    }

    /// tile origins along one side: steps that leave 2 × margin of overlap,
    /// the last one moved back to end at the edge
    private static func starts(length: Int, tile: Int) -> [Int] {
        guard length > tile else { return [0] }
        let step = tile - 2 * margin
        var s = Array(stride(from: 0, to: length - tile, by: step))
        s.append(length - tile)
        return s
    }

    /// half size, with vImage's high-quality (Lanczos) resampling
    private static func halve(_ from: CVPixelBuffer, into to: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(from, .readOnly)
        CVPixelBufferLockBaseAddress(to, [])
        defer {
            CVPixelBufferUnlockBaseAddress(from, .readOnly)
            CVPixelBufferUnlockBaseAddress(to, [])
        }
        var s = vImage_Buffer(data: CVPixelBufferGetBaseAddress(from), height: vImagePixelCount(CVPixelBufferGetHeight(from)),
                              width: vImagePixelCount(CVPixelBufferGetWidth(from)), rowBytes: CVPixelBufferGetBytesPerRow(from))
        var d = vImage_Buffer(data: CVPixelBufferGetBaseAddress(to), height: vImagePixelCount(CVPixelBufferGetHeight(to)),
                              width: vImagePixelCount(CVPixelBufferGetWidth(to)), rowBytes: CVPixelBufferGetBytesPerRow(to))
        let err = vImageScale_ARGB16F(&s, &d, nil, vImage_Flags(kvImageHighQualityResampling))
        guard err == kvImageNoError else { throw Failure(message: "Couldn't resize the enlarged photo (\(err)).") }
    }

    /// the image's metadata, with its pixel size updated
    private static func resized(_ properties: [String: Any], width: Int, height: Int) -> [String: Any] {
        var p = properties
        p[kCGImagePropertyPixelWidth as String] = width
        p[kCGImagePropertyPixelHeight as String] = height
        if var exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = width
            exif[kCGImagePropertyExifPixelYDimension as String] = height
            p[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFXResolution as String)
            tiff.removeValue(forKey: kCGImagePropertyTIFFYResolution as String)
            p[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return p
    }
}
