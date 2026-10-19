import CoreGraphics
import Foundation

/// Where a new spot heals from, as Lightroom and Photos pick it: darktable's
/// retouch leaves the source to the user, who'd otherwise drag it every time.
///
/// Candidates sit around the spot at two to four radii, every 20°. Each is
/// scored on how its surroundings match the spot's (a ring of samples just
/// outside both circles, in luminance from the frame on screen), plus how
/// plain its own middle is against its ring, so the source isn't another
/// blemish, plus a little for distance, so near patches win ties.
enum SpotSource {
    /// `c` and `radius` in output pixels; `shown` is the zoomed crop the frame shows, if any
    static func find(for c: CGPoint, radius r: Double, in image: CGImage?, shown: Engine.Crop?, size: CGSize) -> CGPoint {
        let fallback = CGPoint(x: c.x + (c.x + 3 * r < size.width ? 2.5 * r : -2.5 * r), y: c.y)
        guard let image, let luma = Luma(image) else { return fallback }
        // output pixels to the frame's
        let toFrame: (CGPoint) -> CGPoint = { p in
            if let crop = shown { return CGPoint(x: p.x * crop.scale - Double(crop.x), y: p.y * crop.scale - Double(crop.y)) }
            return CGPoint(x: p.x / size.width * Double(image.width), y: p.y / size.height * Double(image.height))
        }
        let scale = shown?.scale ?? Double(image.width) / size.width
        let fr = r * scale
        let ring = (0..<48).flatMap { i -> [CGPoint] in
            let a = Double(i) / 48 * 2 * .pi
            return [1.15, 1.4].map { k in CGPoint(x: cos(a) * k * fr, y: sin(a) * k * fr) }
        }
        let inner = (0..<24).flatMap { i -> [CGPoint] in
            let a = Double(i) / 24 * 2 * .pi
            return [0.3, 0.7].map { k in CGPoint(x: cos(a) * k * fr, y: sin(a) * k * fr) }
        } + [.zero]
        let t = toFrame(c)
        guard let target = luma.samples(around: t, at: ring) else { return fallback }

        var best: (score: Double, point: CGPoint)?
        for d in [2.2, 3.0, 4.0] {
            for step in 0..<18 {
                let a = Double(step) / 18 * 2 * .pi
                let p = CGPoint(x: c.x + cos(a) * d * r, y: c.y + sin(a) * d * r)
                // the source must be on the photo, edge included
                guard p.x - 1.4 * r >= 0, p.y - 1.4 * r >= 0, p.x + 1.4 * r <= size.width, p.y + 1.4 * r <= size.height else { continue }
                let f = toFrame(p)
                guard let around = luma.samples(around: f, at: ring), let middle = luma.samples(around: f, at: inner) else { continue }
                let match = zip(target, around).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } / Double(ring.count)
                let ringMean = around.reduce(0, +) / Double(around.count)
                let plain = middle.reduce(0) { $0 + ($1 - ringMean) * ($1 - ringMean) } / Double(middle.count)
                let score = match + plain + 0.0002 * d
                if best == nil || score < best!.score { best = (score, p) }
            }
        }
        return best?.point ?? fallback
    }

    /// The frame as 8-bit luminance, for sampling.
    private struct Luma {
        let width: Int, height: Int
        let data: [UInt8]

        init?(_ image: CGImage) {
            width = image.width; height = image.height
            var buf = [UInt8](repeating: 0, count: width * height)
            guard let ctx = CGContext(data: &buf, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            data = buf
        }

        /// values at offsets from a point, 0...1; nil if any fall off the frame
        func samples(around p: CGPoint, at offsets: [CGPoint]) -> [Double]? {
            var out: [Double] = []
            out.reserveCapacity(offsets.count)
            for o in offsets {
                let x = Int(p.x + o.x), y = Int(p.y + o.y)
                guard x >= 0, y >= 0, x < width, y < height else { return nil }
                out.append(Double(data[y * width + x]) / 255)
            }
            return out
        }
    }
}
