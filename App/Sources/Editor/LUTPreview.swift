import CoreImage
import Foundation
import ImageIO

/// Small previews of film looks, worked out in the app: each LUT shrunk to a
/// 32-point cube for Core Image's colour cube, applied to a small render of
/// the photo without its look. Close to darktable's result, not identical
/// (darktable interpolates the full cube tetrahedrally).
enum LUTPreview {
    static let size = 32
    // NSCache is thread-safe
    nonisolated(unsafe) private static let cubes = NSCache<NSString, NSData>()
    nonisolated(unsafe) private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// the look applied to `base`, or nil if the LUT can't be read
    static func render(_ look: URL, on base: CGImage) -> CGImage? {
        guard let cube = cube(for: look) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let input = CIImage(cgImage: base)
        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": size, "inputCubeData": cube as Data, "inputColorSpace": space,
            kCIInputImageKey: input,
        ]), let out = filter.outputImage else { return nil }
        return context.createCGImage(out, from: input.extent, format: .RGBA8, colorSpace: space)
    }

    private static func cube(for url: URL) -> NSData? {
        if let c = cubes.object(forKey: url.path as NSString) { return c }
        let ext = url.pathExtension.lowercased()
        let sample: ((Double, Double, Double) -> (Float, Float, Float))?
        switch ext {
        case "png", "tif", "tiff": sample = hald(url)
        case "cube": sample = cubeFile(url)
        default: sample = nil
        }
        guard let sample else { return nil }
        var data = [Float](repeating: 1, count: size * size * size * 4)
        let n = Double(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let (x, y, z) = sample(Double(r) / n, Double(g) / n, Double(b) / n)
                    let i = ((b * size + g) * size + r) * 4
                    data[i] = x; data[i + 1] = y; data[i + 2] = z
                }
            }
        }
        let c = data.withUnsafeBufferPointer { NSData(bytes: $0.baseAddress, length: $0.count * 4) }
        cubes.setObject(c, forKey: url.path as NSString)
        return c
    }

    /// A Hald CLUT image: N³ entries (N = level²) in reading order, red fastest
    private static func hald(_ url: URL) -> ((Double, Double, Double) -> (Float, Float, Float))? {
        guard let src = CGImageSourceCreateWithURL(url.photoFile as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil), img.width == img.height else { return nil }
        let w = img.width
        let n = Int((pow(Double(w * w), 1.0 / 3)).rounded())
        guard n * n * n == w * w else { return nil }
        var px = [UInt8](repeating: 0, count: w * w * 4)
        guard let ctx = CGContext(data: &px, width: w, height: w, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: w))
        let m = Double(n - 1)
        return { r, g, b in
            let i = Int((r * m).rounded()) + Int((g * m).rounded()) * n + Int((b * m).rounded()) * n * n
            let o = i * 4
            return (Float(px[o]) / 255, Float(px[o + 1]) / 255, Float(px[o + 2]) / 255)
        }
    }

    /// A .cube file: LUT_3D_SIZE, then rows of r g b with red fastest
    private static func cubeFile(_ url: URL) -> ((Double, Double, Double) -> (Float, Float, Float))? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var n = 0
        var values: [(Float, Float, Float)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("LUT_3D_SIZE") { n = Int(t.split(separator: " ").last ?? "") ?? 0; continue }
            let parts = t.split(separator: " ")
            guard parts.count == 3, let x = Float(parts[0]), let y = Float(parts[1]), let z = Float(parts[2]) else { continue }
            values.append((x, y, z))
        }
        guard n > 1, values.count == n * n * n else { return nil }
        let m = Double(n - 1)
        return { r, g, b in values[Int((r * m).rounded()) + Int((g * m).rounded()) * n + Int((b * m).rounded()) * n * n] }
    }
}
