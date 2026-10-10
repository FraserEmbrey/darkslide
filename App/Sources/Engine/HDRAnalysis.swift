import CoreGraphics
import Foundation

/// How the export profile chosen in darktable's output color profile module
/// will encode the pipeline's linear output.
///
/// darktable builds its PQ and HLG profiles from the BT.2100 curves with no
/// extra scaling (common/colorspaces.c), and clips the encoded signal at 1.0:
///   PQ:  linear 1.0 = 10,000 nits
///   HLG: linear 1.0 = nominal peak; displayed through the BT.2100 OOTF
///        for a 1000-nit reference display (system gamma 1.2)
/// Anything else is SDR, where 1.0 is SDR white.
struct HDRTarget: Sendable, Equatable {
    enum Transfer: Sendable { case sdr, pq, hlg }
    enum Primaries: Sendable { case rec2020, p3 }

    let transfer: Transfer
    let primaries: Primaries
    let name: String

    /// BT.2408 HDR reference white, used to place HDR output on the EDR scale
    static let referenceWhiteNits = 203.0
    static let hlgPeakNits = 1000.0
    static let pqPeakNits = 10_000.0

    /// darktable's dt_colorspaces_color_profile_type_t values
    init(darktableProfile type: Int) {
        switch type {
        case 22: (transfer, primaries, name) = (.pq, .rec2020, "PQ Rec.2020")
        case 23: (transfer, primaries, name) = (.hlg, .rec2020, "HLG Rec.2020")
        case 24: (transfer, primaries, name) = (.pq, .p3, "PQ P3")
        case 25: (transfer, primaries, name) = (.hlg, .p3, "HLG P3")
        default: (transfer, primaries, name) = (.sdr, .rec2020, "SDR")
        }
    }

    var isHDR: Bool { transfer != .sdr }

    /// The format's peak, × reference white.
    var peak: Double? {
        switch transfer {
        case .sdr: nil
        case .pq: Self.pqPeakNits / Self.referenceWhiteNits
        case .hlg: Self.hlgPeakNits / Self.referenceWhiteNits
        }
    }

    var luminanceWeights: (Float, Float, Float) {
        primaries == .p3 ? (0.2290, 0.6917, 0.0793) : (0.2627, 0.6780, 0.0593)
    }
}

/// Luminance statistics for an HDR frame on the EDR scale: 1.0 is reference
/// (SDR) white, 2.0 one stop brighter. Nits assume 203-nit reference white.
struct HDRAnalysis: Sendable {
    static let minStops = -8.0
    static let maxStops = 6.0
    static let binCount = 280

    let target: HDRTarget
    let bins: [Int]               // luminance
    let channelBins: [[Int]]      // red, green, blue, same stops scale as `bins`
    let peak: Double              // × reference white
    let fractionAboveSDR: Double
    let fractionAboveDisplay: Double
    let fractionClipped: Double   // at the format's ceiling or outside its gamut
    let fractionNearPeak: Double  // within a third of a stop of the format's peak
    let displayHeadroom: Double
    /// the peak before the HDR limit rolled it off (equal to `peak` without one)
    let unlimitedPeak: Double

    var peakStops: Double { log2(max(peak, 1e-6)) }
    var peakNits: Double { peak * HDRTarget.referenceWhiteNits }

    /// Running totals for one slice of the image; slices are merged at the end.
    private struct Partial {
        var bins = [Int](repeating: 0, count: HDRAnalysis.binCount)
        var red = [Int](repeating: 0, count: HDRAnalysis.binCount)
        var green = [Int](repeating: 0, count: HDRAnalysis.binCount)
        var blue = [Int](repeating: 0, count: HDRAnalysis.binCount)
        var peak: Float = 0
        var unlimitedPeak: Float = 0
        var aboveSDR = 0, aboveDisplay = 0, clipped = 0, nearPeak = 0
    }

    /// Converts darktable's linear Rec.2020 output to what the export will
    /// show, on the EDR scale and in the export's primaries, and analyses it.
    /// Reads `source` (the mapped frame) once and writes a new buffer, split
    /// across all cores. The overlay marking pixels beyond the display is only
    /// built when asked for.
    ///
    /// `limit` (× reference white) rolls highlights off smoothly so nothing
    /// exceeds it: from a stop below the limit, luminance eases towards it with
    /// hue kept, as Greg Benz suggests capping HDR peaks well below what the
    /// format allows.
    static func process(source: UnsafeRawBufferPointer, width: Int, height: Int, target: HDRTarget,
                        displayHeadroom: Double, wantOverlay: Bool,
                        limit: Double? = nil) -> (Data, HDRAnalysis, CGImage?) {
        let count = width * height
        var output = Data(count: count * 16)
        var mask = Data(count: wantOverlay ? count * 4 : 0)
        let slices = ProcessInfo.processInfo.activeProcessorCount * 4
        var partials = [Partial](repeating: Partial(), count: slices)

        // a third of a stop below the format's peak, on the EDR scale
        let nearPeakThreshold = target.peak.map { Float($0) * powf(2, -1.0 / 3) } ?? .infinity
        let headroom = Float(displayHeadroom)
        let (wr, wg, wb) = target.luminanceWeights
        let binScale = Float(binCount) / Float(maxStops - minStops)
        let minStopsF = Float(minStops)
        let refWhite = Float(HDRTarget.referenceWhiteNits)
        let pqScale = Float(HDRTarget.pqPeakNits) / refWhite
        let hlgScale = Float(HDRTarget.hlgPeakNits) / refWhite
        let limitL = Float(limit ?? .infinity)
        let knee = max(1, limitL / 2)

        output.withUnsafeMutableBytes { outRaw in
            mask.withUnsafeMutableBytes { maskRaw in
                partials.withUnsafeMutableBufferPointer { parts in
                    // each slice touches only its own pixels and its own Partial
                    nonisolated(unsafe) let src = source.assumingMemoryBound(to: Float.self)
                    nonisolated(unsafe) let dst = outRaw.assumingMemoryBound(to: Float.self)
                    nonisolated(unsafe) let mp = maskRaw.assumingMemoryBound(to: UInt8.self)
                    nonisolated(unsafe) let results = parts

                    DispatchQueue.concurrentPerform(iterations: slices) { slice in
                        var p = Partial()
                        for i in (count * slice / slices)..<(count * (slice + 1) / slices) {
                            var r = src[4 * i], g = src[4 * i + 1], b = src[4 * i + 2]

                            if target.primaries == .p3 {
                                // linear Rec.2020 -> linear Display P3 (D65)
                                (r, g, b) = (1.3435783 * r - 0.2821797 * g - 0.0613986 * b,
                                             -0.0652975 * r + 1.0757879 * g - 0.0104905 * b,
                                             0.0028218 * r - 0.0195985 * g + 1.0167767 * b)
                            }

                            if target.isHDR {
                                // the encoded signal is clipped to [0, 1]; negatives are out of gamut
                                if r < 0 || g < 0 || b < 0 || r > 1 || g > 1 || b > 1 { p.clipped += 1 }
                                r = min(max(r, 0), 1); g = min(max(g, 0), 1); b = min(max(b, 0), 1)
                                switch target.transfer {
                                case .pq:
                                    r *= pqScale; g *= pqScale; b *= pqScale
                                case .hlg:
                                    // BT.2100 OOTF: Fd = Lw * Ys^(gamma - 1) * E, Lw = 1000, gamma = 1.2
                                    let s = hlgScale * powf(max(wr * r + wg * g + wb * b, 0), 0.2)
                                    r *= s; g *= s; b *= s
                                case .sdr: break
                                }
                            }
                            var y = wr * r + wg * g + wb * b
                            if y > p.unlimitedPeak { p.unlimitedPeak = y }
                            if y > knee {
                                // slope 1 at the knee, approaching the limit asymptotically
                                let span = limitL - knee
                                let s = (knee + span * (1 - expf(-(y - knee) / span))) / y
                                r *= s; g *= s; b *= s; y *= s
                            }
                            dst[4 * i] = r; dst[4 * i + 1] = g; dst[4 * i + 2] = b; dst[4 * i + 3] = 1

                            if y > p.peak { p.peak = y }
                            if y > 1 { p.aboveSDR += 1 }
                            if y >= nearPeakThreshold { p.nearPeak += 1 }
                            if y > headroom {
                                p.aboveDisplay += 1
                                if wantOverlay {
                                    mp[4 * i] = 160      // translucent red, premultiplied
                                    mp[4 * i + 3] = 160
                                }
                            }
                            // per channel too, so the HDR histogram can be drawn like the SDR one;
                            // every other pixel is plenty for that
                            if i & 1 == 0 {
                                if r > 0 { p.red[min(max(Int((log2f(r) - minStopsF) * binScale), 0), binCount - 1)] += 1 }
                                if g > 0 { p.green[min(max(Int((log2f(g) - minStopsF) * binScale), 0), binCount - 1)] += 1 }
                                if b > 0 { p.blue[min(max(Int((log2f(b) - minStopsF) * binScale), 0), binCount - 1)] += 1 }
                            }
                            guard y > 0 else { continue }
                            let bin = Int((log2f(y) - minStopsF) * binScale)
                            p.bins[min(max(bin, 0), binCount - 1)] += 1
                        }
                        results[slice] = p
                    }
                }
            }
        }

        var total = Partial()
        for p in partials {
            for k in 0..<binCount {
                total.bins[k] += p.bins[k]
                total.red[k] += p.red[k]; total.green[k] += p.green[k]; total.blue[k] += p.blue[k]
            }
            total.peak = max(total.peak, p.peak)
            total.unlimitedPeak = max(total.unlimitedPeak, p.unlimitedPeak)
            total.aboveSDR += p.aboveSDR; total.aboveDisplay += p.aboveDisplay
            total.clipped += p.clipped; total.nearPeak += p.nearPeak
        }

        let n = Double(max(count, 1))
        let analysis = HDRAnalysis(
            target: target, bins: total.bins, channelBins: [total.red, total.green, total.blue],
            peak: Double(total.peak),
            fractionAboveSDR: Double(total.aboveSDR) / n,
            fractionAboveDisplay: Double(total.aboveDisplay) / n,
            fractionClipped: Double(total.clipped) / n,
            fractionNearPeak: Double(total.nearPeak) / n,
            displayHeadroom: displayHeadroom,
            unlimitedPeak: Double(total.unlimitedPeak))

        guard wantOverlay, total.aboveDisplay > 0, let provider = CGDataProvider(data: mask as CFData) else {
            return (output, analysis, nil)
        }
        let overlay = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        return (output, analysis, overlay)
    }
}
