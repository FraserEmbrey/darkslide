import Foundation

/// Converts between a scene illuminant's chromaticity (CIE xy, as darktable's
/// color calibration stores it) and the familiar temperature and tint.
///
/// The Planckian locus uses Krystek's (1985) rational approximation in CIE 1960
/// uv. Tint is the standard Duv (signed distance from the locus, positive above
/// it, i.e. a greener light) scaled by 1000. A greener light makes the corrected
/// image more magenta, so a positive tint reads as "more magenta", as in Lightroom.
enum Illuminant {
    static let kelvinRange: ClosedRange<Double> = 2000...12000
    static let tintRange: ClosedRange<Double> = -40...40   // Duv × 1000

    private static func locus(_ t: Double) -> (u: Double, v: Double) {
        let u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t * t) / (1 + 8.42420235e-4 * t + 7.08145163e-7 * t * t)
        let v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t * t) / (1 - 2.89741816e-5 * t + 1.61456053e-7 * t * t)
        return (u, v)
    }

    /// unit normal to the locus at t, pointing to positive Duv (greener)
    private static func normal(_ t: Double) -> (u: Double, v: Double) {
        let a = locus(t), b = locus(t + 1)
        let du = b.u - a.u, dv = b.v - a.v, n = (du * du + dv * dv).squareRoot()
        return (dv / n, -du / n)
    }

    static func xy(kelvin: Double, tint: Double) -> (x: Double, y: Double) {
        let p = locus(kelvin), n = normal(kelvin), duv = tint / 1000
        let u = p.u + duv * n.u, v = p.v + duv * n.v
        let d = 2 * u - 8 * v + 4
        return (3 * u / d, 2 * v / d)
    }

    static func kelvinAndTint(x: Double, y: Double) -> (kelvin: Double, tint: Double) {
        let d = -2 * x + 12 * y + 3
        let u = 4 * x / d, v = 6 * y / d
        // nearest point on the locus, golden-section search over log temperature
        func dist(_ lt: Double) -> Double {
            let p = locus(exp(lt)); return (p.u - u) * (p.u - u) + (p.v - v) * (p.v - v)
        }
        var lo = log(1667.0), hi = log(25000.0)
        let g = (5.0.squareRoot() - 1) / 2
        for _ in 0..<80 {
            let a = hi - g * (hi - lo), b = lo + g * (hi - lo)
            if dist(a) < dist(b) { hi = b } else { lo = a }
        }
        let t = exp((lo + hi) / 2), p = locus(t), n = normal(t)
        return (t, ((u - p.u) * n.u + (v - p.v) * n.v) * 1000)
    }
}
