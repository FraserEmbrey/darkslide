import Foundation

/// A slider on a local adjustment, and which darktable module and fields it
/// drives. Exposure is the adjustment's own instance; the rest are instances
/// of colour balance rgb and local contrast sharing its shape.
enum LocalControl: String, CaseIterable, Identifiable {
    case exposure, contrast, highlights, shadows, clarity, saturation, vibrance, warmth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .clarity: "Clarity"
        case .saturation: "Saturation"
        case .vibrance: "Vibrance"
        case .warmth: "Warmth"
        }
    }

    var op: String {
        switch self {
        case .exposure: "exposure"
        case .clarity: "bilat"
        default: "colorbalancergb"
        }
    }

    /// the slider's range; all but exposure show as −100 to 100
    var range: ClosedRange<Double> { self == .exposure ? -3...3 : -100...100 }
    var unit: String? { self == .exposure ? "EV" : nil }

    /// colour balance rgb's hue for a warmer mid-tone, and its opposite
    static let warmHue = 65.0, coolHue = 245.0
    /// mid-tone chroma at full warmth: a strong tint, but not a wash
    static let warmChroma = 0.04

    /// the fields for a slider value
    func fields(for v: Double) -> [(String, Double)] {
        let x = v / 100
        switch self {
        case .exposure: return [("exposure", (v * 100).rounded() / 100)]
        case .contrast: return [("contrast", x * 0.5)]
        case .highlights: return [("highlights_Y", x * 0.5)]
        case .shadows: return [("shadows_Y", x * 0.5)]
        case .clarity: return [("detail", x)]
        case .saturation: return [("saturation_global", x * 0.5)]
        case .vibrance: return [("vibrance", x * 0.5)]
        case .warmth: return [("midtones_H", v >= 0 ? Self.warmHue : Self.coolHue), ("midtones_C", abs(x) * Self.warmChroma)]
        }
    }

    /// the slider value the module's fields give
    func value(from m: EngineModule) -> Double {
        func n(_ name: String) -> Double { m.fields.first { $0.name == name }?.value.number ?? 0 }
        switch self {
        case .exposure: return n("exposure")
        case .contrast: return n("contrast") / 0.5 * 100
        case .highlights: return n("highlights_Y") / 0.5 * 100
        case .shadows: return n("shadows_Y") / 0.5 * 100
        case .clarity: return n("detail") * 100
        case .saturation: return n("saturation_global") / 0.5 * 100
        case .vibrance: return n("vibrance") / 0.5 * 100
        case .warmth:
            let c = n("midtones_C") / Self.warmChroma * 100
            return abs(n("midtones_H") - Self.coolHue) < 1 ? -c : c
        }
    }

    /// settings an instance needs on being added, where darktable's defaults
    /// aren't neutral: local contrast starts at 125% detail
    var neutral: [(String, Double)] { op == "bilat" ? [("detail", 0)] : [] }
}

/// Aperture's Quick Brushes: a brushed local adjustment with its sliders set
/// for one job. Any of them can be changed after, as for any local adjustment.
enum QuickBrush: String, CaseIterable, Identifiable {
    case dodge, burn, contrast, clarity, soften, saturate, desaturate, warm, cool, plain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dodge: "Dodge"
        case .burn: "Burn"
        case .contrast: "Contrast"
        case .clarity: "Definition"
        case .soften: "Smooth Skin"
        case .saturate: "Intensify"
        case .desaturate: "Desaturate"
        case .warm: "Warm"
        case .cool: "Cool"
        case .plain: "Brush"
        }
    }

    var symbol: String {
        switch self {
        case .dodge: "sun.max"
        case .burn: "moon"
        case .contrast: "circle.lefthalf.filled"
        case .clarity: "sparkle"
        case .soften: "face.smiling"
        case .saturate: "drop.fill"
        case .desaturate: "drop"
        case .warm: "thermometer.sun"
        case .cool: "thermometer.snowflake"
        case .plain: "paintbrush"
        }
    }

    /// the sliders it sets, on a fresh adjustment
    var values: [(LocalControl, Double)] {
        switch self {
        case .dodge: [(.exposure, 0.7)]
        case .burn: [(.exposure, -0.7)]
        case .contrast: [(.contrast, 40)]
        case .clarity: [(.clarity, 40)]
        // negative local contrast softens texture and keeps edges, as skin smoothing wants
        case .soften: [(.clarity, -60)]
        case .saturate: [(.saturation, 40)]
        case .desaturate: [(.saturation, -100)]
        case .warm: [(.warmth, 50)]
        case .cool: [(.warmth, -50)]
        case .plain: []
        }
    }
}
