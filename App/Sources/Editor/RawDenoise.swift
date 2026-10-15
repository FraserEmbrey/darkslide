import CoreML
import Foundation

/// Raw noise reduction before demosaicing, as Lightroom's Denoise does: the
/// RawNIND model (UtNet2, Benoit Brummer, UCLouvain; GPL-3.0) that darktable
/// 5.6 ships as "raw denoise", run with Core ML on the GPU. It follows
/// darktable's dt_restore_raw_bayer (src/common/ai/restore_raw_bayer.c): the
/// mosaic is normalised per site, packed as R, G1, G2, B at half size in
/// 512 px tiles overlapping by 32, and each tile's full-size R, G, B output
/// is put back into the mosaic, its edges cross-faded with its neighbours'.
/// One change: the output is matched to the input's level per channel, not
/// as one average. darktable's single gain counts green twice in the input
/// and once in the output, which left its result about 15% brighter and a
/// little magenta on a Sony A7C at ISO 12800; per channel it's within 0.1%.
/// The model comes from darktable-ai's release, converted by
/// Scripts/fetch-models.sh; without it, Denoise isn't offered.
enum RawDenoise {
    struct Layout: Decodable, Sendable {
        let width: Int
        let height: Int
        let cropX: Int
        let cropY: Int
        let visibleWidth: Int
        let visibleHeight: Int
        let white: Float
        /// by site parity: [even row even column, even odd, odd even, odd odd]
        let black: [Float]
        /// the colour (0 R, 1 G, 2 B) at each site of the 2x2 pattern, in the same order
        let colors: [Int]
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var modelURL: URL? {
        Bundle.main.url(forResource: "RawDenoise", withExtension: "mlmodelc", subdirectory: "Models")
    }

    static var isAvailable: Bool { modelURL != nil }

    /// tile size and overlap in packed (half-size) pixels, as darktable's
    private static let tile = 512
    private static let overlap = 32

    /// Denoises a mosaic of float sensor values, returning it as uint16
    /// sensor values. `strength` blends with the original, as darktable's does.
    static func run(_ mosaic: [Float], layout l: Layout, strength: Float = 1,
                    progress: @Sendable (Double) -> Void = { _ in }) throws -> [UInt16] {
        guard let modelURL else { throw Failure(message: "The denoise model isn't installed.") }
        guard l.colors.count == 4, l.black.count == 4, mosaic.count == l.width * l.height,
              let r = l.colors.firstIndex(of: 0), l.colors.filter({ $0 == 1 }).count == 2, l.colors.contains(2)
        else { throw Failure(message: "Denoise works on Bayer raws only.") }
        let config = MLModelConfiguration()
        // full precision: the model's raw output runs to about a million times
        // its input, past half precision's range, so the Neural Engine is out
        config.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: modelURL, configuration: config)

        let W = l.width, H = l.height
        let T = tile, O = overlap, step = T - 2 * O
        let y0 = r / 2, x0 = r % 2                     // where red sits in the pattern
        let range = l.black.map { max(l.white - $0, 1) }
        let alpha = min(max(strength, 0), 1)

        // the working area and the bounds reflections stay within (darktable's mirror_cropped)
        let visEndY = l.cropY + l.visibleHeight, visEndX = l.cropX + l.visibleWidth
        let Hh = (visEndY - y0) / 2, Wh = (visEndX - x0) / 2
        guard Hh > 0, Wh > 0 else { throw Failure(message: "The photo is too small to denoise.") }
        var mirLoY = l.cropY + y0, mirLoX = l.cropX + x0
        var mirHiY = visEndY, mirHiX = visEndX
        if (mirHiY - mirLoY) & 1 == 1 { mirHiY -= 1 }
        if (mirHiX - mirLoX) & 1 == 1 { mirHiX -= 1 }
        mirLoY = max(mirLoY, 0); mirLoX = max(mirLoX, 0)
        mirHiY = min(mirHiY, H); mirHiX = min(mirHiX, W)

        func mirror(_ i: Int, _ lo: Int, _ hi: Int) -> Int {
            let n = hi - lo
            if n <= 1 { return lo }
            var k = abs(i - lo)
            let period = 2 * (n - 1)
            k %= period
            if k >= n { k = period - k }
            return lo + k
        }

        let input = try MLMultiArray(shape: [1, 4, NSNumber(value: T), NSNumber(value: T)], dataType: .float32)
        let plane = T * T
        // blended output over the working area; the seams' ramps sum to 1
        var acc = [Float](repeating: 0, count: W * H)
        let rows = (Hh + step - 1) / step, cols = (Wh + step - 1) / step
        let SO = 2 * O                                  // overlap in sensor pixels
        func ramp(_ d: Int) -> Float { (Float(d) + 0.5) / Float(2 * SO) }

        for ty in 0..<rows {
            for tx in 0..<cols {
                let pyBase = ty * step, pxBase = tx * step
                let pyEnd = min(pyBase + step, Hh), pxEnd = min(pxBase + step, Wh)
                let sr0 = 2 * (pyBase - O) + y0, sc0 = 2 * (pxBase - O) + x0

                // pack: slot k is the site (k / 2, k % 2) from red, so R, G1, G2, B
                var inMean = [Double](repeating: 0, count: 4)
                input.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in
                    for dy in 0..<T {
                        for k in 0..<4 {
                            let row = mirror(sr0 + 2 * dy + k / 2, mirLoY, mirHiY)
                            let site = (row & 1) << 1
                            var sum = 0.0
                            for dx in 0..<T {
                                let col = mirror(sc0 + 2 * dx + k % 2, mirLoX, mirHiX)
                                let b = site | (col & 1)
                                let v = (mosaic[row * W + col] - l.black[b]) / range[b]
                                p[k * plane + dy * T + dx] = v
                                sum += Double(v)
                            }
                            inMean[k] += sum
                        }
                    }
                }
                for k in 0..<4 { inMean[k] /= Double(plane) }

                let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": input]))
                guard let o = out.featureValue(for: "output")?.multiArrayValue, o.dataType == .float32 else {
                    throw Failure(message: "The denoise model gave no output.")
                }
                let s = o.strides.map(\.intValue)       // [1, 3, 2T, 2T], not always packed
                try o.withUnsafeBufferPointer(ofType: Float.self) { q in
                    // per-channel gain: R to the R sites, G to both greens, B to the B sites
                    var outMean = [Double](repeating: 0, count: 3)
                    for c in 0..<3 {
                        var sum = 0.0
                        for y in 0..<(2 * T) {
                            let base = c * s[1] + y * s[2]
                            for x in 0..<(2 * T) { sum += Double(q[base + x * s[3]]) }
                        }
                        outMean[c] = sum / Double(4 * plane)
                    }
                    let target = [inMean[0], (inMean[1] + inMean[2]) / 2, inMean[3]]
                    var gain = [Float](repeating: 1, count: 3)
                    for c in 0..<3 {
                        guard abs(outMean[c]) > 1e-6 * abs(target[c]), target[c] != 0 else {
                            // a channel with nothing in it: darktable's single gain
                            let all = inMean.reduce(0, +) / 4, allOut = outMean.reduce(0, +) / 3
                            guard abs(allOut) > 1e-6 * abs(all), all != 0 else { throw Failure(message: "The denoise model's output was empty.") }
                            gain = [Float](repeating: Float(all / allOut), count: 3)
                            break
                        }
                        gain[c] = Float(target[c] / outMean[c])
                    }

                    // put back into the mosaic, over the core plus the seams it shares
                    let top = ty > 0, bottom = ty < rows - 1, left = tx > 0, right = tx < cols - 1
                    let sy = y0 + 2 * pyBase, syEnd = y0 + 2 * pyEnd
                    let sx = x0 + 2 * pxBase, sxEnd = x0 + 2 * pxEnd
                    let ey0 = max(0, top ? sy - SO : sy), ey1 = min(H, bottom ? syEnd + SO : syEnd)
                    let ex0 = max(0, left ? sx - SO : sx), ex1 = min(W, right ? sxEnd + SO : sxEnd)
                    for row in ey0..<ey1 {
                        var ay: Float = 1
                        if top && row < sy + SO { ay = ramp(row - (sy - SO)) }
                        else if bottom && row >= syEnd - SO { ay = 1 - ramp(row - (syEnd - SO)) }
                        let my = 2 * O + (row - sy)
                        for col in ex0..<ex1 {
                            var ax: Float = 1
                            if left && col < sx + SO { ax = ramp(col - (sx - SO)) }
                            else if right && col >= sxEnd - SO { ax = 1 - ramp(col - (sxEnd - SO)) }
                            let mx = 2 * O + (col - sx)
                            let b = (row & 1) << 1 | (col & 1)
                            let c = l.colors[b]
                            let v = q[c * s[1] + my * s[2] + mx * s[3]] * gain[c] * range[b] + l.black[b]
                            let i = row * W + col
                            acc[i] += ax * ay * (alpha * v + (1 - alpha) * mosaic[i])
                        }
                    }
                }
                progress(Double(ty * cols + tx + 1) / Double(rows * cols))
            }
        }

        // outside the working area (a row or column at most), the original
        var result = [UInt16](repeating: 0, count: W * H)
        let wy = y0..<(y0 + 2 * Hh), wx = x0..<(x0 + 2 * Wh)
        for row in 0..<H {
            for col in 0..<W {
                let i = row * W + col
                let v = wy.contains(row) && wx.contains(col) ? acc[i] : mosaic[i]
                result[i] = UInt16(min(max(v, 0), l.white) + 0.5)
            }
        }
        return result
    }
}
