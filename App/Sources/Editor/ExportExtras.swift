import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A frame and a text watermark, added to exports only (the edit is left as
/// it is). darktable's framing and watermark modules do the work, appended
/// to the export as a style; the watermark's text is drawn here, with
/// macOS's text engine, into a PNG for darktable to place.
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

    /// the modules for the engine's export, after drawing the watermark's PNG
    /// into darktable's user watermarks folder (`configDir`); `photo` is the
    /// edit's size, for placing the watermark on a frame
    func engineExtras(configDir: URL, photo: CGSize) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let text = watermarkText.trimmingCharacters(in: .whitespaces)
        // darktable applies the watermark after the frame, to the whole picture
        let layout = frameLayout(photo: photo)
        let c = layout.canvas, r = layout.photo
        let column = watermarkPosition % 3
        // on a frame it sits in the bottom border, in the frame's other tone
        let onFrame = frameOn && r.minY > 0
        let tone = onFrame ? (frameTone == .white ? Tone.black : Tone.white) : watermarkTone
        if watermarkOn, !text.isEmpty, c.width > 0, c.height > 0,
           let file = Self.drawText(text, tone: tone, into: configDir.appendingPathComponent("watermarks")) {
            var fields: [String: Any] = ["filename": file, "opacity": watermarkOpacity]
            if onFrame {
                let border = c.height - r.maxY
                // in proportion to the border, but never large on a deep one
                let textHeight = min(border * 0.42, c.height * 0.03)
                fields["alignment"] = 6 + column        // the bottom row
                fields["scale_base"] = 4                 // advanced
                fields["scale_img"] = 2                  // to the picture's height
                fields["scale_svg"] = 1                  // by the marker's height
                fields["scale"] = textHeight / c.height * 100
                fields["yoffset"] = -((border - textHeight) / 2) / c.height
                // in line with the photo's side, where it's at a side
                fields["xoffset"] = column == 0 ? r.minX / c.width : column == 2 ? -(c.width - r.maxX) / c.width : 0
            } else {
                fields["alignment"] = watermarkPosition
                fields["scale_base"] = 4
                fields["scale_img"] = 3                  // to the larger side
                fields["scale_svg"] = 0                  // by the marker's width
                fields["scale"] = watermarkSize
                // a little in from the edges it's aligned to
                fields["xoffset"] = column == 0 ? 0.02 : column == 2 ? -0.02 : 0
                fields["yoffset"] = watermarkPosition / 3 == 0 ? 0.03 : watermarkPosition / 3 == 2 ? -0.03 : 0
            }
            out.append(["op": "watermark", "fields": fields])
        }
        if frameOn {
            var fields: [String: Any] = ["size": frameWidth / 100, "color": frameTone.rgb, "basis": 4]
            switch frameShape {
            case .even: fields["aspect"] = -1.0
            case .square: fields["aspect"] = 1.0
            case .portrait45: fields["aspect"] = 1.25; fields["aspect_orient"] = 1
            }
            out.append(["op": "borders", "fields": fields])
        }
        return out
    }

    /// the text as a transparent PNG, large enough to stay sharp at any size;
    /// returns its file name in `folder`
    static func drawText(_ text: String, tone: Tone, into folder: URL) -> String? {
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
        guard let image = ctx.makeImage() else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "develop-watermark-\(tone.rawValue).png"
        guard let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? name : nil
    }
}
