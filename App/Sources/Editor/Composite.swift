import CoreImage
import CoreVideo
import Foundation
import Vision

/// A multiple exposure: other photos, each with its own edit, blended over
/// this one with one blend mode, as a camera's multiple exposure mode or a
/// layered blend in Photoshop. The blend can be kept to the subject (the
/// silhouette double exposure) or the background, and the subject can be cut
/// out onto a plain or gradient backdrop. Done by the app with Core Image on
/// darktable's renders, after the edit: darktable's own composite module
/// takes its photo in before that photo's tone edits, as 8-bit linear.
/// Kept per photo in the catalog, as darktable has nothing to read it with.
struct CompositeSettings: Codable, Equatable {
    enum Blend: String, Codable, CaseIterable, Identifiable {
        case normal, screen, lighten, add, multiply, darken, overlay, softLight, difference
        var id: String { rawValue }
        var title: String {
            switch self {
            case .normal: "Normal"
            case .screen: "Screen"
            case .lighten: "Lighten"
            case .add: "Add"
            case .multiply: "Multiply"
            case .darken: "Darken"
            case .overlay: "Overlay"
            case .softLight: "Soft Light"
            case .difference: "Difference"
            }
        }
        var detail: String {
            switch self {
            case .normal: "Lays each photo over at its opacity."
            case .screen: "The classic multiple exposure: dark parts let the other photo through, bright parts add."
            case .lighten: "Keeps the brighter of the two at each point."
            case .add: "Adds the light of each, as film exposed twice. Brightens quickly."
            case .multiply: "Darkens: light parts let the other photo through, dark parts stay dark."
            case .darken: "Keeps the darker of the two at each point."
            case .overlay: "Brings in the other photo's texture with more contrast."
            case .softLight: "A gentler overlay, for texture."
            case .difference: "Inverts where the photos are bright; graphic, abstract results."
            }
        }
        fileprivate var filter: String? {
            switch self {
            case .normal: nil
            case .screen: "CIScreenBlendMode"
            case .lighten: "CILightenBlendMode"
            case .add: "CIAdditionCompositing"
            case .multiply: "CIMultiplyBlendMode"
            case .darken: "CIDarkenBlendMode"
            case .overlay: "CIOverlayBlendMode"
            case .softLight: "CISoftLightBlendMode"
            case .difference: "CIDifferenceBlendMode"
            }
        }
    }

    /// where the photos blend
    enum Region: String, Codable, CaseIterable, Identifiable {
        case everywhere, subject, background
        var id: String { rawValue }
        var title: String {
            switch self {
            case .everywhere: "Everywhere"
            case .subject: "Subject"
            case .background: "Background"
            }
        }
    }

    enum Backdrop: String, Codable, CaseIterable, Identifiable {
        case none, colour, gradient
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "None"
            case .colour: "Colour"
            case .gradient: "Gradient"
            }
        }
    }

    struct Layer: Codable, Equatable, Identifiable {
        var id = UUID()
        var path: String
        var opacity = 1.0
        /// 1 fills the photo; larger zooms in
        var scale = 1.0
        /// offset as a fraction of the photo's width and height, rightward and down
        var x = 0.0, y = 0.0
        var url: URL { URL(fileURLWithPath: path) }
    }

    var blend = Blend.screen
    var layers: [Layer] = []
    var region = Region.everywhere
    var backdrop = Backdrop.none
    /// sRGB, 0 to 1
    var colour: [Double] = [1, 1, 1]
    var colour2: [Double] = [0.1, 0.12, 0.16]
    /// the gradient's direction in degrees: 0 runs from top to bottom
    var angle = 0.0

    var isActive: Bool { !layers.isEmpty || backdrop != .none }
    /// whether the subject has to be found
    var needsSubject: Bool { backdrop != .none || (!layers.isEmpty && region != .everywhere) }
}

enum Compositor {
    /// The composite of `base`, a picture of `region` of the photo (in pixels
    /// of the photo at `canvas` size, top-left origin) at the base's own scale.
    /// `layers` are the other photos' renders, each with its settings;
    /// `subject` is the photo's subject matte over the whole photo, any size,
    /// white inside. `encoded`: the values are already gamma-encoded (an export
    /// read without colour management); otherwise they're Core Image's linear
    /// working values, and are encoded for blending, as Photoshop blends.
    static func apply(_ settings: CompositeSettings, base: CIImage, canvas: CGSize, region: CGRect,
                      layers: [(CIImage, CompositeSettings.Layer)], subject: CIImage?, encoded: Bool) -> CIImage {
        let extent = base.extent
        let s = extent.width / region.width
        // the whole photo at the base's scale, in Core Image's bottom-left space,
        // placed so the shown region lands on the base's extent
        let full = CGRect(x: extent.minX - region.minX * s,
                          y: extent.minY - (canvas.height - region.maxY) * s,
                          width: canvas.width * s, height: canvas.height * s)
        func encode(_ i: CIImage) -> CIImage { encoded ? i : i.applyingFilter("CILinearToSRGBToneCurve") }
        func decode(_ i: CIImage) -> CIImage { encoded ? i : i.applyingFilter("CISRGBToneCurveToLinear") }

        var out = encode(base)
        let matte = subject.map { fit($0, to: full).cropped(to: extent) }

        if settings.backdrop != .none, let matte {
            let back = backdrop(settings, in: full, encoded: encoded).cropped(to: extent)
            out = out.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: back, kCIInputMaskImageKey: matte])
        }
        for (picture, layer) in layers {
            let placed = encode(place(picture, layer, in: full)).cropped(to: extent)
            var blended: CIImage
            if let name = settings.blend.filter {
                blended = placed.applyingFilter(name, parameters: [kCIInputBackgroundImageKey: out])
            } else {
                blended = placed
            }
            // opacity, then the region, as one mask
            var mask = CIImage(color: CIColor(red: layer.opacity, green: layer.opacity, blue: layer.opacity)).cropped(to: extent)
            if settings.region != .everywhere, let matte {
                let where_ = settings.region == .subject ? matte : matte.applyingFilter("CIColorInvert")
                mask = where_.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask])
            }
            blended = blended.cropped(to: extent)
            out = blended.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: mask])
        }
        return decode(out.cropped(to: extent))
    }

    /// a layer filling the photo (cropped to its shape), then zoomed and moved
    private static func place(_ picture: CIImage, _ layer: CompositeSettings.Layer, in full: CGRect) -> CIImage {
        let e = picture.extent
        let fill = max(full.width / e.width, full.height / e.height) * max(layer.scale, 0.1)
        let w = e.width * fill, h = e.height * fill
        let x = full.midX - w / 2 + layer.x * full.width
        let y = full.midY - h / 2 - layer.y * full.height
        return picture
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
            .clampedToExtent()
    }

    /// a matte stretched over the photo
    private static func fit(_ matte: CIImage, to full: CGRect) -> CIImage {
        let e = matte.extent
        return matte
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: full.width / e.width, y: full.height / e.height))
            .transformed(by: CGAffineTransform(translationX: full.minX, y: full.minY))
            .clampedToExtent()
    }

    private static func backdrop(_ settings: CompositeSettings, in full: CGRect, encoded: Bool) -> CIImage {
        // the colours are sRGB values: encoded as they are, otherwise linear for the working space
        func colour(_ c: [Double]) -> CIColor {
            let v = (c + [0, 0, 0]).prefix(3).map { CGFloat($0) }
            return CIColor(red: v[0], green: v[1], blue: v[2])
        }
        let a = colour(settings.colour)
        guard settings.backdrop == .gradient else { return CIImage(color: a) }
        let b = colour(settings.colour2)
        // from the top edge's centre to the bottom's at 0°, turning clockwise
        let r = settings.angle * .pi / 180
        let half = (abs(sin(r)) * full.width + abs(cos(r)) * full.height) / 2
        let dx = sin(r) * half, dy = cos(r) * half
        return CIImage.empty().applyingFilter("CISmoothLinearGradient", parameters: [
            "inputPoint0": CIVector(x: full.midX - dx, y: full.midY + dy),
            "inputPoint1": CIVector(x: full.midX + dx, y: full.midY - dy),
            "inputColor0": a, "inputColor1": b,
        ])
    }

    /// the subject's soft matte at the picture's size, white inside; nil when
    /// Vision finds no subject
    static func subjectMatte(in picture: CGImage) throws -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: picture, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
        let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        // one float channel; copied, as Vision reuses its buffers
        let matte = CIImage(cvPixelBuffer: buffer)
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var pixels = [Float](repeating: 0, count: w * h)
        context.render(matte, toBitmap: &pixels, rowBytes: w * 4, bounds: matte.extent, format: .Rf, colorSpace: nil)
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .Rf, colorSpace: nil)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            // opaque everywhere now, so back to the matte's own extent
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }
}
