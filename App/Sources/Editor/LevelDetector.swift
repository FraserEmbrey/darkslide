import CoreGraphics
import Foundation

/// Finds how far a photo is tilted from the near-horizontal and near-vertical
/// edges in it (buildings, frames, poles, horizons), as Lightroom's and
/// Photomator's levelling do: the tilt that squares the strongest of them up.
/// Natural textures (leaves, grass) spread their edges over every angle and
/// add no peak, so a photo with nothing straight in it gives nil.
enum LevelDetector {
    /// The tilt in degrees within ±`maxTilt`, positive when the straight
    /// lines lean clockwise in the image as shown; nil if nothing is clearly
    /// straight.
    static func tilt(of image: CGImage, maxTilt: Double = 15) -> Double? {
        // grey, about 900 px on the long side
        let scale = 900 / Double(max(image.width, image.height))
        let w = max(Int(Double(image.width) * min(scale, 1)), 16), h = max(Int(Double(image.height) * min(scale, 1)), 16)
        var grey = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &grey, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // a light blur, so pixel steps don't bias the angles of near-level edges
        var px = grey.map(Float.init)
        var tmp = px
        for y in 0..<h { for x in 1..<(w - 1) { tmp[y * w + x] = (px[y * w + x - 1] + 2 * px[y * w + x] + px[y * w + x + 1]) / 4 } }
        for y in 1..<(h - 1) { for x in 0..<w { px[y * w + x] = (tmp[(y - 1) * w + x] + 2 * tmp[y * w + x] + tmp[(y + 1) * w + x]) / 4 } }

        // Sobel gradients, then the structure tensor over a 5 × 5 window: where
        // it is coherent the pixel sits on a straight edge, where it isn't it is
        // texture (grass, leaves) and is left out
        var gxs = [Float](repeating: 0, count: w * h), gys = gxs
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                gxs[i] = (px[i - w + 1] + 2 * px[i + 1] + px[i + w + 1]) - (px[i - w - 1] + 2 * px[i - 1] + px[i + w - 1])
                gys[i] = (px[i + w - 1] + 2 * px[i + w] + px[i + w + 1]) - (px[i - w - 1] + 2 * px[i - w] + px[i - w + 1])
            }
        }
        func boxBlur(_ a: [Float], r: Int) -> [Float] {
            var t = a, o = a
            for y in 0..<h {
                var acc: Float = 0
                for x in 0..<min(r, w) { acc += a[y * w + x] }
                for x in 0..<w {
                    if x + r < w { acc += a[y * w + x + r] }
                    if x - r - 1 >= 0 { acc -= a[y * w + x - r - 1] }
                    t[y * w + x] = acc
                }
            }
            for x in 0..<w {
                var acc: Float = 0
                for y in 0..<min(r, h) { acc += t[y * w + x] }
                for y in 0..<h {
                    if y + r < h { acc += t[(y + r) * w + x] }
                    if y - r - 1 >= 0 { acc -= t[(y - r - 1) * w + x] }
                    o[y * w + x] = acc
                }
            }
            return o
        }
        let jxx = boxBlur(zip(gxs, gxs).map { $0 * $1 }, r: 2)
        let jyy = boxBlur(zip(gys, gys).map { $0 * $1 }, r: 2)
        let jxy = boxBlur(zip(gxs, gys).map { $0 * $1 }, r: 2)

        let binsPerDegree = 10.0
        let count = Int(2 * maxTilt * binsPerDegree) + 1
        var hist = [Double](repeating: 0, count: count)
        var samples = 0
        for y in 3..<(h - 3) {
            for x in 3..<(w - 3) {
                let i = y * w + x
                let m = (gxs[i] * gxs[i] + gys[i] * gys[i]).squareRoot()
                guard m > 30 else { continue }
                let a = Double(jxx[i]), b = Double(jyy[i]), c = Double(jxy[i])
                let trace = a + b
                guard trace > 0 else { continue }
                let coherence = ((a - b) * (a - b) + 4 * c * c).squareRoot() / trace
                guard coherence > 0.85 else { continue }
                // the dominant gradient direction of the window
                let phi = 0.5 * atan2(2 * c, a - b) * 180 / .pi
                let d = remainder(phi, 90)       // -45...45 from the nearest axis
                guard abs(d) <= maxTilt else { continue }
                let bin = Int(((d + maxTilt) * binsPerDegree).rounded())
                // converging verticals lean more the further they are from the centre,
                // so lines near the middle count most; verticals beat horizons,
                // which are often hills or receding ground
                let vertical = abs(remainder(phi, 180)) < 45
                let off = vertical ? abs(Double(x - w / 2)) / Double(w / 2) : abs(Double(y - h / 2)) / Double(h / 2)
                let place = max(0, 1 - off) * (vertical ? 1 : 0.5)
                if hist.indices.contains(bin) { hist[bin] += Double(m) * coherence * coherence * place * place }
                samples += 1
            }
        }
        guard samples > 150 else { return nil }
        // smooth over ±0.5°, then the peak must stand well clear of the rest
        let sigma = 3.0
        var smooth = [Double](repeating: 0, count: count)
        for i in 0..<count {
            var acc = 0.0, wsum = 0.0
            for k in -9...9 where hist.indices.contains(i + k) {
                let g = exp(-Double(k * k) / (2 * sigma * sigma))
                acc += hist[i + k] * g; wsum += g
            }
            smooth[i] = acc / wsum
        }
        guard let peak = smooth.indices.max(by: { smooth[$0] < smooth[$1] }) else { return nil }
        let mean = smooth.reduce(0, +) / Double(count)
        guard smooth[peak] > mean * 1.8 else { return nil }
        // refine the peak between bins
        var offset = 0.0
        if peak > 0, peak < count - 1 {
            let a = smooth[peak - 1], b = smooth[peak], c = smooth[peak + 1]
            let den = a - 2 * b + c
            if abs(den) > 1e-9 { offset = 0.5 * (a - c) / den }
        }
        return (Double(peak) + offset) / binsPerDegree - maxTilt
    }
}
