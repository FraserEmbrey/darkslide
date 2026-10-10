import CoreGraphics
import Foundation

/// darktable's rotate and perspective module (iop/ashift.c), the parts its
/// interface does: the homography for a rotation, lens shifts and shear, the
/// automatic crop that keeps the photo's shape, and an automatic upright fit.
/// Coordinates are ashift's input, before the orientation flip.
enum Perspective {
    struct Geometry: Equatable {
        var rotation = 0.0       // degrees
        var vertical = 0.0       // lensshift_v
        var horizontal = 0.0     // lensshift_h
        var shear = 0.0
    }

    typealias Matrix = [[Double]]

    private static func mul(_ a: Matrix, _ b: Matrix) -> Matrix {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] } } }
    }

    static func apply(_ m: Matrix, _ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = m[2][0] * x + m[2][1] * y + m[2][2]
        return CGPoint(x: (m[0][0] * x + m[0][1] * y + m[0][2]) / w, y: (m[1][0] * x + m[1][1] * y + m[1][2]) / w)
    }

    /// _homography in ashift.c, forward, in its generic lens model (28 mm,
    /// no lens dependence, aspect 1), which is the module's default
    static func homography(_ g: Geometry, width: Double, height: Double) -> Matrix {
        let u = width, v = height
        let fLength = 28.0, orthocorr = 0.0, aspect = 1.0
        let phi = g.rotation * .pi / 180
        let cosi = cos(phi), sini = sin(phi)
        let ascale = aspect.squareRoot()

        let horifac = 1 - orthocorr / 100
        let exppaV = exp(g.vertical)
        let fdbV = fLength / (14.4 + (v / u - 1) * 7.2)
        let radV = fdbV * (exppaV - 1) / (exppaV + 1)
        let alphaV = min(max(atan(radV), -1.5), 1.5)
        let rtV = sin(0.5 * alphaV)
        let rV = max(0.1, 2 * (horifac - 1) * rtV * rtV + 1)

        let vertifac = 1 - orthocorr / 100
        let exppaH = exp(g.horizontal)
        let fdbH = fLength / (14.4 + (u / v - 1) * 7.2)
        let radH = fdbH * (exppaH - 1) / (exppaH + 1)
        let alphaH = min(max(atan(radH), -1.5), 1.5)
        let rtH = sin(0.5 * alphaH)
        let rH = max(0.1, 2 * (vertifac - 1) * rtH * rtH + 1)

        // step 1: flip x and y (ShiftN works in y : x : 1)
        var m: Matrix = [[0, 1, 0], [1, 0, 0], [0, 0, 1]]
        // step 2: rotation about the centre
        m = mul([[cosi, -sini, -0.5 * v * cosi + 0.5 * u * sini + 0.5 * v],
                 [sini, cosi, -0.5 * v * sini - 0.5 * u * cosi + 0.5 * u],
                 [0, 0, 1]], m)
        // step 3: shear
        m = mul([[1, g.shear, 0], [g.shear, 1, 0], [0, 0, 1]], m)
        // step 4: vertical lens shift
        m = mul([[exppaV, 0, 0],
                 [0.5 * ((exppaV - 1) * u) / v, 2 * exppaV / (exppaV + 1), -0.5 * ((exppaV - 1) * u) / (exppaV + 1)],
                 [(exppaV - 1) / v, 0, 1]], m)
        // step 5: horizontal compression
        m = mul([[1, 0, 0], [0, rV, 0.5 * u * (1 - rV)], [0, 0, 1]], m)
        // step 6: flip back
        m = mul([[0, 1, 0], [1, 0, 0], [0, 0, 1]], m)
        // step 7: horizontal lens shift
        m = mul([[exppaH, 0, 0],
                 [0.5 * ((exppaH - 1) * v) / u, 2 * exppaH / (exppaH + 1), -0.5 * ((exppaH - 1) * v) / (exppaH + 1)],
                 [(exppaH - 1) / u, 0, 1]], m)
        // step 8: vertical compression
        m = mul([[1, 0, 0], [0, rH, 0.5 * v * (1 - rH)], [0, 0, 1]], m)
        // step 9: aspect
        m = mul([[ascale, 0, 0], [0, 1 / ascale, 0], [0, 0, 1]], m)
        // step 10: shift so no coordinate is negative
        var umin = Double.infinity, vmin = Double.infinity
        for y in [0.0, height - 1] {
            for x in [0.0, width - 1] {
                let p = apply(m, CGPoint(x: x, y: y))
                umin = min(umin, Double(p.x)); vmin = min(vmin, Double(p.y))
            }
        }
        return mul([[1, 0, -umin], [0, 1, -vmin], [0, 0, 1]], m)
    }

    /// The crop margins (cl, cr, ct, cb, as fractions of the output) of the
    /// largest rectangle of the photo's shape inside the corrected photo, as
    /// darktable's "automatic cropping: original format" fits them. darktable
    /// fits the centre with a simplex; this searches it on a grid, then finer.
    static func cropMargins(_ g: Geometry, width: Double, height: Double) -> (cl: Double, cr: Double, ct: Double, cb: Double) {
        if g == Geometry() { return (0, 1, 0, 1) }
        let h = homography(g, width: width, height: height)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: height), CGPoint(x: width, y: height), CGPoint(x: width, y: 0)]
            .map { apply(h, $0) }
        let xs = corners.map { Double($0.x) }, ys = corners.map { Double($0.y) }
        let xmin = xs.min()!, ymin = ys.min()!, owd = xs.max()! - xmin, oht = ys.max()! - ymin
        // the edges as lines a x + b y + c = 0, oriented so the inside is positive
        let centre = CGPoint(x: xs.reduce(0, +) / 4, y: ys.reduce(0, +) / 4)
        let edges: [(Double, Double, Double)] = (0..<4).map { n in
            let p = corners[n], q = corners[(n + 1) % 4]
            var a = Double(q.y - p.y), b = Double(p.x - q.x)
            var c = -(a * Double(p.x) + b * Double(p.y))
            if a * Double(centre.x) + b * Double(centre.y) + c < 0 { a = -a; b = -b; c = -c }
            return (a, b, c)
        }
        let alpha = atan2(height, width)
        let dirs = [(cos(alpha), sin(alpha)), (cos(alpha), -sin(alpha)), (-cos(alpha), sin(alpha)), (-cos(alpha), -sin(alpha))]
        /// the half diagonal of the largest such rectangle centred at (x, y)
        func reach(_ x: Double, _ y: Double) -> Double {
            var d = Double.infinity
            for (a, b, c) in edges {
                let inside = a * x + b * y + c
                if inside <= 0 { return 0 }
                for (dx, dy) in dirs {
                    let rate = a * dx + b * dy
                    if rate < 0 { d = min(d, inside / -rate) }
                }
            }
            return d
        }
        var best = (x: Double(centre.x), y: Double(centre.y), d: reach(Double(centre.x), Double(centre.y)))
        var step = max(owd, oht) / 8
        for _ in 0..<24 {
            var improved = false
            for (sx, sy) in [(1.0, 0.0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)] {
                let x = best.x + sx * step, y = best.y + sy * step
                let d = reach(x, y)
                if d > best.d { best = (x, y, d); improved = true }
            }
            if !improved { step /= 2 }
        }
        guard best.d > 0, best.d.isFinite else { return (0, 1, 0, 1) }
        let cl = (best.x - best.d * cos(alpha) - xmin) / owd, cr = (best.x + best.d * cos(alpha) - xmin) / owd
        let ct = (best.y - best.d * sin(alpha) - ymin) / oht, cb = (best.y + best.d * sin(alpha) - ymin) / oht
        let clamp = { (v: Double) in min(max(v, 0), 1) }
        return (clamp(cl), clamp(cr), clamp(ct), clamp(cb))
    }

    /// Automatic upright, like Lightroom's Vertical: the rotation and vertical
    /// lens shift that make the photo's near-vertical lines vertical. Measured
    /// on the photo as ashift sees it (no rotation, no perspective, no flip),
    /// at any size: the samples are scaled to ashift's input size.
    static func fitUpright(_ image: CGImage, inputSize: CGSize) -> Geometry? {
        guard let samples = LevelDetector.edgeSamples(of: image, maxTilt: 25, verticalOnly: true),
              samples.count > 150 else { return nil }
        let sx = Double(inputSize.width) / Double(image.width), sy = Double(inputSize.height) / Double(image.height)
        let pts = samples.map { s in
            (p: CGPoint(x: s.x * sx, y: s.y * sy), d: CGVector(dx: s.dx * sx, dy: s.dy * sy), w: s.weight)
        }
        let w = Double(inputSize.width), h = Double(inputSize.height)
        // each line's lean from vertical after the correction, robustly: past 3°
        // a line is more likely a tree or a diagonal than a wall
        func cost(_ g: Geometry) -> Double {
            let m = homography(g, width: w, height: h)
            var total = 0.0
            for s in pts {
                let a = apply(m, s.p)
                let b = apply(m, CGPoint(x: s.p.x + s.d.dx * 8, y: s.p.y + s.d.dy * 8))
                let lean = atan2(Double(b.x - a.x), Double(b.y - a.y))
                let dev = remainder(lean, .pi) * 180 / .pi
                total += s.w * min(dev * dev, 9)
            }
            return total
        }
        var best = Geometry()
        var bestCost = cost(best)
        // coarse grid, then a shrinking pattern search
        for r in stride(from: -10.0, through: 10.0, by: 1) {
            for v in stride(from: -1.2, through: 1.2, by: 0.1) {
                let g = Geometry(rotation: r, vertical: v)
                let c = cost(g)
                if c < bestCost { best = g; bestCost = c }
            }
        }
        var stepR = 0.5, stepV = 0.05
        for _ in 0..<30 {
            var improved = false
            for (dr, dv) in [(stepR, 0.0), (-stepR, 0), (0, stepV), (0, -stepV)] {
                let g = Geometry(rotation: best.rotation + dr, vertical: best.vertical + dv)
                let c = cost(g)
                if c < bestCost { best = g; bestCost = c; improved = true }
            }
            if !improved { stepR /= 2; stepV /= 2 }
            if stepR < 0.02 { break }
        }
        // only where lines really are vertical once corrected: buildings, frames,
        // poles. In a natural scene the edges are scattered (trees, rocks) and the
        // best fit is just whatever leans most, so nothing is changed.
        let m = homography(best, width: w, height: h)
        var inline = 0.0, total = 0.0
        for s in pts {
            let a = apply(m, s.p)
            let b = apply(m, CGPoint(x: s.p.x + s.d.dx * 8, y: s.p.y + s.d.dy * 8))
            let dev = abs(remainder(atan2(Double(b.x - a.x), Double(b.y - a.y)), .pi) * 180 / .pi)
            total += s.w
            if dev < 1 { inline += s.w }
        }
        lastConfidence = total > 0 ? inline / total : 0
        guard lastConfidence >= minimumConfidence else { return nil }
        return Geometry(rotation: (best.rotation * 100).rounded() / 100, vertical: (best.vertical * 1000).rounded() / 1000)
    }

    /// the share of edge strength within 1° of vertical after the last fit
    nonisolated(unsafe) static var lastConfidence = 0.0
    // the Z50 sample (buildings among trees) scores 0.27, a landscape 0.14
    static let minimumConfidence = 0.2
}
