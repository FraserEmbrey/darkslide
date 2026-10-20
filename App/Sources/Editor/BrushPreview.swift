import CoreImage
import Foundation

/// How a brush stroke will look while it's painted. darktable renders the
/// adjustment once the stroke is done; until then the frame on screen gets
/// the adjustment's settings from Core Image, close enough to paint by, and
/// the stroke reveals it. darktable's render replaces it when it arrives.
enum BrushPreview {
    /// The frame with the settings applied (taken away, erasing), as a frame like it.
    static func image(of frame: CGImage, values: [(LocalControl, Double)], erase: Bool) -> CGImage? {
        let set = values.filter { $0.1 != 0 }
        guard !set.isEmpty else { return nil }
        let source = CIImage(cgImage: frame)
        var img = source
        let sign = erase ? -1.0 : 1.0
        for (control, value) in set {
            let v = value * sign, x = v / 100
            switch control {
            case .exposure:
                img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: v])
            case .contrast:
                img = img.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + x * 0.35])
            case .saturation:
                img = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: max(0, 1 + x)])
            case .vibrance:
                img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": x])
            case .highlights:
                img = img.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1 + min(0, x), "inputShadowAmount": 0])
                if x > 0 { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: x * 0.3]) }
            case .shadows:
                img = img.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1, "inputShadowAmount": x])
            case .clarity:
                img = x > 0
                    ? img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 12, kCIInputIntensityKey: x * 0.8])
                    : img.applyingGaussianBlur(sigma: -x * 3).cropped(to: source.extent)
            case .warmth:
                // neutral at 6500 K, warmer as the light it's balanced for gets cooler
                img = img.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - x * 1500, y: 0),
                ])
            }
        }
        return Inpainter.image(img.cropped(to: source.extent), like: frame)
    }
}
