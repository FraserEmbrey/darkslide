import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// The pixel work behind Engine.gainMapPreview: an SDR base as linear floats
/// in the HDR frame's primaries, and the blend a gain map viewer does.
enum GainMapPreview {
    /// darktable's SDR frame (BGRA8, sRGB) as linear RGBA floats in `primaries`
    static func linearize(sdr: Engine.Frame, primaries: HDRTarget.Primaries) throws -> Data {
        let count = sdr.width * sdr.height
        guard sdr.pixels.count >= count * 4 else { throw EngineError(message: "The SDR frame is the wrong size.") }
        var lut = [Float](repeating: 0, count: 256)
        for v in 0..<256 {
            let c = Float(v) / 255
            lut[v] = c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
        }
        // linear sRGB -> linear Display P3 or Rec.2020 (both D65)
        let m: [Float] = primaries == .p3
            ? [0.8224621, 0.1775380, 0, 0.0331941, 0.9668058, 0, 0.0170827, 0.0723974, 0.9105199]
            : [0.6274039, 0.3292830, 0.0433131, 0.0690973, 0.9195404, 0.0113623, 0.0163914, 0.0880133, 0.8955953]
        var out = Data(count: count * 16)
        sdr.pixels.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dstRaw in
                nonisolated(unsafe) let s = src.bindMemory(to: UInt8.self)
                nonisolated(unsafe) let d = dstRaw.bindMemory(to: Float.self)
                let slices = ProcessInfo.processInfo.activeProcessorCount * 4
                DispatchQueue.concurrentPerform(iterations: slices) { slice in
                    for i in (count * slice / slices)..<(count * (slice + 1) / slices) {
                        // little-endian BGRX
                        let b = lut[Int(s[4 * i])], g = lut[Int(s[4 * i + 1])], r = lut[Int(s[4 * i + 2])]
                        d[4 * i] = m[0] * r + m[1] * g + m[2] * b
                        d[4 * i + 1] = m[3] * r + m[4] * g + m[5] * b
                        d[4 * i + 2] = m[6] * r + m[7] * g + m[8] * b
                        d[4 * i + 3] = 1
                    }
                }
            }
        }
        return out
    }

    /// The automatic SDR base: Apple's tone mapping of the HDR image to SDR,
    /// as the gain map export uses.
    static func toneMapped(hdr: CGImage, peak: Double, space: CFString) throws -> Data {
        let toneMap = CIFilter.toneMapHeadroom()
        toneMap.inputImage = CIImage(cgImage: hdr)
        toneMap.sourceHeadroom = Float(max(peak, 1))
        toneMap.targetHeadroom = 1
        guard let image = toneMap.outputImage else { throw EngineError(message: "Couldn't tone map the HDR frame.") }
        let (w, h) = (hdr.width, hdr.height)
        var out = Data(count: w * h * 16)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!])
        out.withUnsafeMutableBytes { raw in
            context.render(image, toBitmap: raw.baseAddress!, rowBytes: w * 16,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf,
                           colorSpace: CGColorSpace(name: space)!)
        }
        return out
    }

    /// Per channel, (sdr + k)^(1 - w) × (hdr + k)^w − k: applying the gain map
    /// at weight w, with the format's small offset k so blacks stay defined.
    static func blend(sdr: Data, hdr: Data, weight: Float) -> Data {
        let count = min(sdr.count, hdr.count) / 4
        var out = Data(count: count * 4)
        let k: Float = 1.0 / 64
        sdr.withUnsafeBytes { sRaw in
            hdr.withUnsafeBytes { hRaw in
                out.withUnsafeMutableBytes { oRaw in
                    nonisolated(unsafe) let s = sRaw.bindMemory(to: Float.self)
                    nonisolated(unsafe) let h = hRaw.bindMemory(to: Float.self)
                    nonisolated(unsafe) let o = oRaw.bindMemory(to: Float.self)
                    let slices = ProcessInfo.processInfo.activeProcessorCount * 4
                    DispatchQueue.concurrentPerform(iterations: slices) { slice in
                        for i in (count * slice / slices)..<(count * (slice + 1) / slices) {
                            if i & 3 == 3 { o[i] = 1; continue }
                            let a = max(s[i], 0) + k, b = max(h[i], 0) + k
                            o[i] = a * powf(b / a, weight) - k
                        }
                    }
                }
            }
        }
        return out
    }
}
