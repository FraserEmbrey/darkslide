import AppKit
import CoreText
import Foundation
import CoreImage

/// A frame and a text watermark, added to exports only (the edit is left as
/// it is), drawn by Core Image on darktable's output: no Cairo needed.
struct ExportExtras: Codable, Equatable {
    enum Shape: String, Codable, CaseIterable, Identifiable {
        case even, square, portrait45
        var id: String { rawValue }
        var title: String {
            switch self {
            case .even: "Even border"
            case .square: "Square"
            case .portrait45: "4:5 portrait"
            }
        }
    }
    enum Tone: String, Codable, CaseIterable, Identifiable {
        case white, black
        var id: String { rawValue }
        var title: String { self == .white ? "White" : "Black" }
        var rgb: [Double] { self == .white ? [1, 1, 1] : [0, 0, 0] }
    }

    var frameOn = false
    var frameWidth = 4.0          // % of the longer side
    var frameTone = Tone.white
    var frameShape = Shape.even

    var watermarkOn = false
    var watermarkText = "© " + NSFullUserName()
    var watermarkSize = 20.0      // the text's width, % of the photo's longer side
    var watermarkPosition = 8     // 0...8, left to right, top to bottom
    var watermarkOpacity = 80.0
    var watermarkTone = Tone.white

    static let key = "ExportExtras"

    static func load() -> ExportExtras {
        guard let data = UserDefaults.standard.data(forKey: key),
              let e = try? JSONDecoder().decode(ExportExtras.self, from: data) else { return ExportExtras() }
        return e
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    var any: Bool { frameOn || (watermarkOn && !watermarkText.trimmingCharacters(in: .whitespaces).isEmpty) }

    /// The framed picture's size and the photo's place in it: darktable's
    /// framing module (borders.c, modify_roi_out) with the longer side as the
    /// basis, ported. The border's size is its share of the framed side, so
    /// the border added is `L · s / (1 − s)`; a shaped frame adds it to one
    /// side and sizes the other to the shape. The photo is centred.
    func frameLayout(photo: CGSize) -> (canvas: CGSize, photo: CGRect) {
        let w = Double(photo.width), h = Double(photo.height)
        guard frameOn, w > 0, h > 0 else { return (photo, CGRect(origin: .zero, size: photo)) }
        let size = frameWidth / 100
        var widthBasis = w > h
        let basisIn = widthBasis ? w : h
        var cw: Double, ch: Double
        if frameShape == .even {
            let out = (basisIn / (1 - size)).rounded()
            if widthBasis { cw = out; ch = h + out - w } else { ch = out; cw = w + out - h }
        } else {
            let imageAspect = w / h
            var aspect = frameShape == .square ? 1.0 : 0.8      // 4:5 portrait
            let border = basisIn * (1 / (1 - size) - 1)
            if widthBasis && imageAspect < aspect { widthBasis = false } else if !widthBasis && imageAspect > aspect { widthBasis = true }
            if !widthBasis { aspect = 1 / aspect }
            if widthBasis { cw = (w + border).rounded(); ch = (cw / aspect).rounded() }
            else { ch = (h + border).rounded(); cw = (ch / aspect).rounded() }
        }
        return (CGSize(width: cw, height: ch), CGRect(x: (cw - w) / 2, y: (ch - h) / 2, width: w, height: h))
    }

    /// The long edge to export the photo at so that, framed, the picture's
    /// long edge is `longEdge` (0, the original size, stays 0)
    func photoLongEdge(for longEdge: Int, photo: CGSize) -> Int {
        guard frameOn, longEdge > 0, photo.width > 0, photo.height > 0 else { return longEdge }
        let layout = frameLayout(photo: photo)
        let grow = max(layout.canvas.width, layout.canvas.height) / max(photo.width, photo.height)
        return Int((Double(longEdge) / grow).rounded())
    }

    /// The frame and watermark added to an image (origin at zero), drawn with
    /// Core Image. `white` is the value that is white in the image's encoding:
    /// 1 for SDR and linear images, lower for PQ and HLG, so a white frame
    /// sits at reference white rather than the format's peak.
    func composite(_ image: CIImage, white: Double = 1) -> CIImage {
        let photo = image.extent.size
        let layout = frameLayout(photo: photo)
        let c = layout.canvas, r = layout.photo
        // Core Image's origin is at the bottom: flip the layout's top-down y
        func flipped(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: c.height - rect.maxY, width: rect.width, height: rect.height) }
        let level = CGFloat(white)
        var out = image
        if frameOn {
            let v = frameTone == .white ? level : 0
            let frame = CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1))
                .cropped(to: CGRect(origin: .zero, size: c))
            let placed = flipped(r)
            out = image.transformed(by: CGAffineTransform(translationX: placed.minX, y: placed.minY)).composited(over: frame)
        }
        let text = watermarkText.trimmingCharacters(in: .whitespaces)
        let onFrame = frameOn && r.minY > 0
        let tone = onFrame ? (frameTone == .white ? Tone.black : Tone.white) : watermarkTone
        guard watermarkOn, !text.isEmpty, let mark = Self.textImage(text, tone: tone) else { return out }
        // the text's size and place, top-down, as on the frame or on the photo
        let column = watermarkPosition % 3, row = watermarkPosition / 3
        let aspect = mark.extent.width / max(mark.extent.height, 1)
        var box: CGRect
        if onFrame {
            let border = c.height - r.maxY
            let h = min(border * 0.42, c.height * 0.03), w = h * aspect
            let x = column == 0 ? r.minX : column == 2 ? r.maxX - w : (c.width - w) / 2
            box = CGRect(x: x, y: r.maxY + (border - h) / 2, width: w, height: h)
        } else {
            let w = max(c.width, c.height) * watermarkSize / 100, h = w / aspect
            let mx = c.width * 0.02, my = c.height * 0.03
            let x = column == 0 ? mx : column == 2 ? c.width - mx - w : (c.width - w) / 2
            let y = row == 0 ? my : row == 2 ? c.height - my - h : (c.height - h) / 2
            box = CGRect(x: x, y: y, width: w, height: h)
        }
        box = flipped(box)
        let scale = box.height / mark.extent.height
        // white text at the encoding's white, and the opacity, before placing
        let alpha = CGFloat(watermarkOpacity / 100)
        let k = tone == .white ? level : 1
        let tinted = mark.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k * alpha, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k * alpha, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k * alpha, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
        ])
        let placed = tinted.transformed(by: CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: box.minX, y: box.minY)))
        return placed.composited(over: out).cropped(to: CGRect(origin: .zero, size: c))
    }

    /// the text, white or black on transparent (premultiplied), large enough
    /// to stay sharp at any size
    static func textImage(_ text: String, tone: Tone) -> CIImage? {
        let font = CTFontCreateUIFontForLanguage(.system, 200, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 200, nil)
        let colour = tone == .white ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let pad: CGFloat = 12
        let w = Int(ceil(bounds.width + 2 * pad)), h = Int(ceil(bounds.height + 2 * pad))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.textPosition = CGPoint(x: pad - bounds.minX, y: pad - bounds.minY)
        CTLineDraw(line, ctx)
        // the coverage only: the colour is set when it's placed
        return ctx.makeImage().map { CIImage(cgImage: $0, options: [.colorSpace: NSNull()]) }
    }

}
