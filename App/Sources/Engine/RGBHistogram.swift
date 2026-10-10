import Foundation

/// Per-channel histogram of an SDR frame (BGRA8, sRGB), for the histogram card.
struct RGBHistogram: Sendable {
    static let binCount = 128
    let red: [Int], green: [Int], blue: [Int]

    /// Samples every other pixel of every other row: plenty for a histogram,
    /// and a quarter of the work.
    init(bgra data: Data, width: Int, height: Int) {
        var r = [Int](repeating: 0, count: Self.binCount)
        var g = r, b = r
        let shift = 8 - Int(log2(Double(Self.binCount)))   // 256 levels -> bins
        data.withUnsafeBytes { raw in
            let px = raw.bindMemory(to: UInt8.self)
            for y in stride(from: 0, to: height, by: 2) {
                var i = y * width * 4
                let end = i + width * 4
                while i < end {
                    b[Int(px[i]) >> shift] += 1
                    g[Int(px[i + 1]) >> shift] += 1
                    r[Int(px[i + 2]) >> shift] += 1
                    i += 8
                }
            }
        }
        red = r; green = g; blue = b
    }
}
