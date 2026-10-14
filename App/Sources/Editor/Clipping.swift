import CoreGraphics

/// The clipping view shown while a slider is dragged with Option held, as in
/// Lightroom, with both ends at once: on a grey ground, highlights clipped in a channel show in that
/// channel's colour (white where all three clip), and shadows clipped in a
/// channel in its complement (black where all three clip).
enum Clipping {
    static func image(of frame: CGImage) -> CGImage? {
        let w = frame.width, h = frame.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let ground: UInt8 = 96
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let r = px[i], g = px[i + 1], b = px[i + 2]
            let hiR = r >= 254, hiG = g >= 254, hiB = b >= 254
            let loR = r <= 1, loG = g <= 1, loB = b <= 1
            if hiR || hiG || hiB {
                px[i] = hiR ? 255 : 0; px[i + 1] = hiG ? 255 : 0; px[i + 2] = hiB ? 255 : 0
            } else if loR || loG || loB {
                px[i] = loR ? 0 : 255; px[i + 1] = loG ? 0 : 255; px[i + 2] = loB ? 0 : 255
                if loR && loG && loB { px[i] = 0; px[i + 1] = 0; px[i + 2] = 0 }
            } else {
                px[i] = ground; px[i + 1] = ground; px[i + 2] = ground
            }
        }
        return ctx.makeImage()
    }
}
