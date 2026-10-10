import Foundation
import SwiftUI

/// Hand-tuned presentation on top of the generated controls.
///
/// darktable's params metadata gives hard limits (exposure allows -18 to +18 EV),
/// while its GTK interface narrows sliders to useful "soft" ranges in each
/// module's gui code, which we can't see. This is where those get restated,
/// and where custom editors will be registered as they're built.
enum Presentation {
    /// The starting Essentials list, in the order darktable's manual recommends
    /// for basic processing: lens correction first (vignetting changes
    /// brightness), exposure, scene white if the camera got it wrong, the tone
    /// mapper, colour; then corrections as needed. Users can change it.
    static let defaultEssentials: [String] = [
        "lens",
        "exposure",
        "channelmixerrgb",  // scene white: darktable sets it in color calibration, not white balance
        "filmicrgb",
        "sigmoid",
        "agx",
        "colorbalancergb",
        "rgbcurve",         // the RGB curve, on its own editor
        "toneequal",
        "highlights",
        "denoiseprofile",
        "sharpen",
        "vignette",
    ]

    /// tone mappers: only the one in use is shown in Essentials
    static let toneMappers: Set<String> = ["filmicrgb", "sigmoid", "agx"]

    /// Slider ranges keyed "op.field". Values outside can still be typed in.
    static let softRanges: [String: ClosedRange<Double>] = [
        "exposure.exposure": -3...4,
        "exposure.black": -0.1...0.1,
        "temperature.red": 0...4,
        "temperature.green": 0...4,
        "temperature.blue": 0...4,
        "temperature.g2": 0...4,
        "sigmoid.middle_grey_contrast": 0.1...3,
        "filmicrgb.white_point_source": 2...10,
        "filmicrgb.black_point_source": -14...(-3),
        "filmicrgb.contrast": 0.5...3,
        "filmicrgb.latitude": 0.1...50,
        "filmicrgb.balance": -50...50,
        "filmicrgb.security_factor": -50...50,
        "sigmoid.contrast_skewness": -1...1,
        "colorbalancergb.chroma_global": -1...1,
        "colorbalancergb.saturation_global": -1...1,
        "colorbalancergb.vibrance": -1...1,
        "colorbalancergb.contrast": -1...1,
    ]

    /// Fields that only apply in some modes, keyed "op.field": shown only while
    /// the controlling enum field holds one of the listed values. Restates
    /// darktable's GTK layouts (e.g. exposure's manual/automatic panels).
    private static func value(_ m: EngineModule, _ f: String) -> Int {
        Int(m.fields.first { $0.name == f }?.value.number ?? -1)
    }

    /// Visibility that depends on more than one field.
    static let visibleIf: [String: @Sendable (EngineModule) -> Bool] = [
        // highlight reconstruction, as darktable's gui_changed shows them
        // methods: 0 clip, 1 LCh, 2 colour, 3 guided laplacians, 4 segmentation, 5 inpaint opposed
        "highlights.candidating": { value($0, "mode") == 4 },
        "highlights.combine": { value($0, "mode") == 4 },
        "highlights.recovery": { value($0, "mode") == 4 },
        "highlights.strength": { value($0, "mode") == 4 && value($0, "recovery") != 0 },
        "highlights.noise_level": { value($0, "mode") == 3 || (value($0, "mode") == 4 && value($0, "recovery") != 0) },
        "highlights.iterations": { value($0, "mode") == 3 },
        "highlights.scales": { value($0, "mode") == 3 },
        "highlights.solid_color": { value($0, "mode") == 3 },
        // filmic, as its gui_changed shows and enables them
        "filmicrgb.reconstruct_threshold": { value($0, "enable_highlight_reconstruction") == 1 },
        "filmicrgb.reconstruct_feather": { value($0, "enable_highlight_reconstruction") == 1 },
        "filmicrgb.reconstruct_bloom_vs_details": { value($0, "enable_highlight_reconstruction") == 1 },
        "filmicrgb.reconstruct_grey_vs_color": { value($0, "enable_highlight_reconstruction") == 1 },
        "filmicrgb.reconstruct_structure_vs_texture": { value($0, "enable_highlight_reconstruction") == 1 },
        "filmicrgb.output_power": { value($0, "auto_hardness") == 0 },
        "filmicrgb.grey_point_source": { value($0, "custom_grey") == 1 },
        "filmicrgb.grey_point_target": { value($0, "custom_grey") == 1 },
        "filmicrgb.noise_distribution": { ($0.fields.first { $0.name == "noise_level" }?.value.number ?? 0) > 0 },
        "demosaic.cs_radius": { value($0, "cs_enabled") == 1 },
        "demosaic.cs_boost": { value($0, "cs_enabled") == 1 },
        "demosaic.cs_iter": { value($0, "cs_enabled") == 1 },
        "demosaic.cs_thrs": { value($0, "cs_enabled") == 1 },
        "demosaic.cs_center": { value($0, "cs_enabled") == 1 },
    ]

    static let visibleWhen: [String: (field: String, values: Set<Int>)] = [
        // color calibration: light-source lists only for their illuminant type
        "channelmixerrgb.illum_fluo": ("illuminant", [4]),
        "channelmixerrgb.illum_led": ("illuminant", [5]),
    ]

    /// Names shown instead of darktable's, where its module does a familiar job
    /// under another name. Search still matches darktable's name.
    static let displayNames: [String: String] = [
        "channelmixerrgb": "Scene white",
        "toneequal": "Shadows and highlights",
        "rgbcurve": "RGB curve",
        "colorequal": "Hue curves",
        "rgblevels": "RGB levels",
    ]

    /// Bookkeeping fields darktable's interface never shows, keyed "op.field".
    static let hidden: Set<String> = [
        "temperature.various",   // the fourth channel of 4-colour sensors
        "temperature.preset",    // which white balance preset was last chosen
        // exposure's Auto sets the slider (EditorModel.measureAutoExposure),
        // so darktable's automatic mode and its settings aren't shown
        "exposure.mode",
        "exposure.deflicker_percentile",
        "exposure.deflicker_target_level",
        "highlights.blendL",     // legacy, never shown by darktable
        "highlights.blendC",
        "tonecurve.tonecurve_preset",      // tone curve bookkeeping; the curves
        "tonecurve.tonecurve_unbound_ab",  // themselves need a curve editor
    ]

    /// Familiar names that search should find darktable's modules by.
    static let searchAliases: [String: [String]] = [
        "bilat": ["clarity", "detail", "texture"],
        "diffuse": ["sharpen", "sharpness", "clarity", "dehaze", "bloom", "blur"],
        "hazeremoval": ["dehaze", "haze", "fog"],
        "colorbalancergb": ["saturation", "vibrance", "contrast", "colour grading", "color grading", "split toning", "brilliance"],
        "toneequal": ["shadows", "highlights", "dodge", "burn", "tone equaliser"],
        "channelmixerrgb": ["white balance", "temperature", "tint", "colour calibration", "color calibration"],
        "temperature": ["white balance", "temperature"],
        "denoiseprofile": ["noise", "noise reduction"],
        "lens": ["distortion", "vignetting", "chromatic aberration", "lens correction"],
        "ashift": ["perspective", "keystone", "straighten", "level"],
        "colorequal": ["hue", "hsl", "colour equaliser", "color equalizer", "colour mixer", "color mixer"],
        "highlights": ["highlight recovery", "clipped", "blown"],
        "filmicrgb": ["tone mapping", "contrast", "film"],
        "sigmoid": ["tone mapping", "contrast"],
        "agx": ["tone mapping", "contrast"],
        "grain": ["film grain", "grain"],
        "vignette": ["vignette"],
        "demosaic": ["demosaicing", "capture sharpening", "debayer"],
    ]

    /// the name a module is shown under
    static func title(of module: EngineModule) -> String {
        displayNames[module.op] ?? module.name.capitalizedSentence
    }

    static func matches(_ module: EngineModule, search: String) -> Bool {
        let names = [module.name, displayNames[module.op] ?? ""] + (searchAliases[module.op] ?? [])
        return names.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    /// Enum choices in a chosen order, with an explanation of each, keyed
    /// "op.field". Shown as menu tooltips and under the menu for the current choice.
    struct Option {
        let value: Int
        let name: String
        let detail: String
    }

    static let describedOptions: [String: [Option]] = [
        "highlights.mode": [
            Option(value: 5, name: "Inpaint opposed",
                   detail: "Best for most photos, and darktable's default. Fills clipped areas with colour from nearby unclipped pixels. Leave the clipping threshold at 1."),
            Option(value: 4, name: "Segmentation based",
                   detail: "For large blown areas such as overcast skies, lamps or the sun: treats each clipped area as a whole. Use Rebuild for big flat areas like sky."),
            Option(value: 3, name: "Guided laplacians",
                   detail: "For partly clipped highlights where texture matters, such as clouds or skin catching the light. Slow; more iterations give better results."),
            Option(value: 0, name: "Clip highlights",
                   detail: "Turns clipped areas plain white instead of rebuilding colour. Clean and predictable."),
            Option(value: 1, name: "Reconstruct in LCh",
                   detail: "Older method: rebuilds brightness and colour separately. Rarely better than the methods above."),
            Option(value: 2, name: "Reconstruct colour",
                   detail: "Older method: spreads colour into clipped areas. Can leave colour fringes."),
        ],
        "highlights.recovery": [
            Option(value: 0, name: "Off", detail: "Only the segmentation itself; nothing rebuilt beyond it."),
            Option(value: 5, name: "Generic", detail: "Rebuilds clipped areas of any size with some texture. A good first try."),
            Option(value: 6, name: "Flat generic", detail: "As generic, but smoother: for areas that should be plain, like sky."),
            Option(value: 2, name: "Large segments", detail: "For big clipped areas, keeping some texture."),
            Option(value: 4, name: "Flat large segments", detail: "For big clipped areas that should be smooth, such as overcast sky."),
            Option(value: 1, name: "Small segments", detail: "For small clipped areas such as reflections and specular highlights."),
            Option(value: 3, name: "Flat small segments", detail: "For small clipped areas that should be smooth."),
        ],
    ]

    /// Clearer labels than darktable's field descriptions, keyed "op.field".
    static let fieldLabels: [String: String] = [
        "colorbalancergb.vibrance": "Vibrance",
        "colorbalancergb.contrast": "Contrast",
        "colorbalancergb.chroma_global": "Chroma",
        "colorbalancergb.saturation_global": "Saturation",
        "colorbalancergb.brilliance_global": "Brilliance",
        "colorbalancergb.chroma_shadows": "Shadows chroma",
        "colorbalancergb.chroma_midtones": "Midtones chroma",
        "colorbalancergb.chroma_highlights": "Highlights chroma",
        "colorbalancergb.saturation_shadows": "Shadows saturation",
        "colorbalancergb.saturation_midtones": "Midtones saturation",
        "colorbalancergb.saturation_highlights": "Highlights saturation",
        "colorbalancergb.brilliance_shadows": "Shadows brilliance",
        "colorbalancergb.brilliance_midtones": "Midtones brilliance",
        "colorbalancergb.brilliance_highlights": "Highlights brilliance",
        "colorbalancergb.shadows_Y": "Shadows lift", "colorbalancergb.shadows_C": "Shadows chroma", "colorbalancergb.shadows_H": "Shadows hue",
        "colorbalancergb.midtones_Y": "Midtones power", "colorbalancergb.midtones_C": "Midtones chroma", "colorbalancergb.midtones_H": "Midtones hue",
        "colorbalancergb.highlights_Y": "Highlights gain", "colorbalancergb.highlights_C": "Highlights chroma", "colorbalancergb.highlights_H": "Highlights hue",
        "colorbalancergb.global_Y": "Global offset", "colorbalancergb.global_C": "Global chroma", "colorbalancergb.global_H": "Global hue",
        // darktable's zone names, with the exposure each sits at
        "toneequal.noise": "Blacks (−8 EV)",
        "toneequal.ultra_deep_blacks": "Deep shadows (−7 EV)",
        "toneequal.deep_blacks": "Shadows (−6 EV)",
        "toneequal.blacks": "Light shadows (−5 EV)",
        "toneequal.shadows": "Mid-tones (−4 EV)",
        "toneequal.midtones": "Dark highlights (−3 EV)",
        "toneequal.highlights": "Highlights (−2 EV)",
        "toneequal.whites": "Whites (−1 EV)",
        "toneequal.speculars": "Speculars (0 EV)",
        "demosaic.demosaicing_method": "Method",
        "demosaic.cs_enabled": "Capture sharpening",
        "demosaic.cs_radius": "Sharpening radius",
        "demosaic.cs_boost": "Corner boost",
        "demosaic.cs_iter": "Iterations",
        "toneequal.exposure_boost": "Mask exposure",
        "filmicrgb.white_point_source": "White relative exposure",
        "filmicrgb.black_point_source": "Black relative exposure",
        "filmicrgb.contrast": "Contrast",
        "filmicrgb.latitude": "Latitude",
        "filmicrgb.balance": "Shadows ↔ highlights",
        "filmicrgb.enable_highlight_reconstruction": "Reconstruct highlights",
        "filmicrgb.reconstruct_threshold": "Threshold",
        "filmicrgb.reconstruct_feather": "Transition",
        "filmicrgb.reconstruct_bloom_vs_details": "Bloom ↔ reconstruct",
        "filmicrgb.reconstruct_grey_vs_color": "Grey ↔ colourful details",
        "filmicrgb.reconstruct_structure_vs_texture": "Structure ↔ texture",
        "filmicrgb.saturation": "Highlight saturation",
        "filmicrgb.preserve_color": "Preserve chrominance",
        "filmicrgb.auto_hardness": "Automatic hardness",
        "filmicrgb.output_power": "Hardness",
        "filmicrgb.white_point_target": "Target white",
        "filmicrgb.black_point_target": "Target black",
        "filmicrgb.grey_point_target": "Target middle grey",
        "filmicrgb.security_factor": "Dynamic range scaling",
        "filmicrgb.custom_grey": "Custom middle grey",
        "filmicrgb.grey_point_source": "Middle grey luminance",
        "filmicrgb.version": "Colour science",
        "filmicrgb.highlights": "Highlights curve",
        "filmicrgb.shadows": "Shadows curve",
        "filmicrgb.high_quality_reconstruction": "Reconstruction iterations",
        "filmicrgb.noise_level": "Noise in highlights",
        "filmicrgb.noise_distribution": "Noise type",
        "filmicrgb.compensate_icc_black": "Compensate profile black point",
        "filmicrgb.spline_version": "Spline handling",
        "toneequal.contrast_boost": "Mask contrast",
    ]

    /// Card layouts: named groups of fields, the first shown openly, the rest
    /// as disclosures; anything not listed goes under "Advanced".
    struct Section {
        let title: String?
        let fields: [String]
    }

    static let layouts: [String: [Section]] = [
        // filmic: darktable's five tabs become a main section and disclosures
        "filmicrgb": [
            Section(title: nil, fields: ["white_point_source", "black_point_source", "contrast", "latitude", "balance"]),
            Section(title: "Highlight reconstruction", fields: [
                "enable_highlight_reconstruction", "reconstruct_threshold", "reconstruct_feather",
                "reconstruct_bloom_vs_details", "reconstruct_grey_vs_color", "reconstruct_structure_vs_texture"]),
            Section(title: "Look", fields: ["saturation", "preserve_color", "auto_hardness", "output_power"]),
            Section(title: "Display", fields: ["white_point_target", "black_point_target", "grey_point_target"]),
            Section(title: "Scene", fields: ["security_factor", "custom_grey", "grey_point_source"]),
        ],
        "colorbalancergb": [
            Section(title: nil, fields: ["vibrance", "contrast", "chroma_global", "saturation_global", "brilliance_global"]),
            Section(title: "Shadows, midtones and highlights", fields: [
                "chroma_shadows", "chroma_midtones", "chroma_highlights",
                "saturation_shadows", "saturation_midtones", "saturation_highlights",
                "brilliance_shadows", "brilliance_midtones", "brilliance_highlights"]),
            Section(title: "Colour grading", fields: [
                "shadows_Y", "shadows_C", "shadows_H", "midtones_Y", "midtones_C", "midtones_H",
                "highlights_Y", "highlights_C", "highlights_H", "global_Y", "global_C", "global_H"]),
        ],
        "toneequal": [
            Section(title: "Zones", fields: ["noise", "ultra_deep_blacks", "deep_blacks", "blacks", "shadows",
                                             "midtones", "highlights", "whites", "speculars"]),
        ],
    ]

    /// Tone equalizer's two main sliders, as weights over its exposure zones,
    /// following darktable's own zone names: once the mask is fitted to the
    /// photo (−7 to −1 EV, centred on −4 EV "mid-tones"), Shadows works on
    /// darktable's blacks to light shadows (−8 to −5 EV) and Highlights on its
    /// highlights to speculars (−2 to 0 EV), each falling off smoothly. The
    /// anchor zone (weight 1) is where each slider reads its value.
    static let toneZoneWeights: (shadows: [String: Double], highlights: [String: Double]) = (
        ["noise": 0.5, "ultra_deep_blacks": 0.8, "deep_blacks": 1.0, "blacks": 0.7, "shadows": 0.25],
        ["midtones": 0.25, "highlights": 0.7, "whites": 1.0, "speculars": 0.8]
    )
    static let toneAnchors = (shadows: "deep_blacks", highlights: "whites")

    static func isVisible(_ field: EngineField, in module: EngineModule) -> Bool {
        let key = "\(module.op).\(field.name)"
        if hidden.contains(key) { return false }
        if let rule = visibleIf[key] { return rule(module) }
        guard let rule = visibleWhen["\(module.op).\(field.name)"],
              let controller = module.fields.first(where: { $0.name == rule.field }) else { return true }
        return rule.values.contains(Int(controller.value.number))
    }

    /// Modules with an automatic mode, for the card's wand button: the enum
    /// field and its automatic and manual values.
    static let autoModes: [String: AutoMode] = [
        // darktable's "automatic" (deflicker) exposure
        // Auto sets the Exposure slider from darktable's automatic rule (EditorModel.setAuto)
        "exposure": AutoMode(field: "mode", auto: 1, manual: 0) { _ in
            "Auto: sets Exposure from the photo, bringing its middle tone to a standard level, as darktable's automatic exposure does. Adjust the slider from there."
        },
    ]

    struct AutoMode: Sendable {
        let field: String
        let auto: Int
        let manual: Int
        let help: @Sendable (EngineModule) -> String
    }

    /// Units shown after slider values, keyed "op.field".
    static let units: [String: String] = [
        "colorbalancergb.shadows_H": "°", "colorbalancergb.midtones_H": "°",
        "colorbalancergb.highlights_H": "°", "colorbalancergb.global_H": "°",
        "colorbalancergb.hue_angle": "°",
        "toneequal.noise": "EV", "toneequal.ultra_deep_blacks": "EV", "toneequal.deep_blacks": "EV",
        "toneequal.blacks": "EV", "toneequal.shadows": "EV", "toneequal.midtones": "EV",
        "toneequal.highlights": "EV", "toneequal.whites": "EV", "toneequal.speculars": "EV",
        "exposure.exposure": "EV",
        "exposure.deflicker_target_level": "EV",
        "exposure.deflicker_percentile": "%",
        "sigmoid.display_white_target": "%",
        "sigmoid.display_black_target": "%",
        "sigmoid.hue_preservation": "%",
        "filmicrgb.white_point_source": "EV",
        "filmicrgb.black_point_source": "EV",
        "filmicrgb.grey_point_source": "%",
        "filmicrgb.white_point_target": "%",
        "filmicrgb.black_point_target": "%",
        "filmicrgb.latitude": "%",
    ]

    /// Coloured tracks, as for white balance in Photos and Photomator. darktable's
    /// white balance stores channel multipliers, so each track runs from the
    /// colour that channel suppresses to the colour it adds.
    static let hueTrack: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 0.8, brightness: 0.9) }

    static let trackColors: [String: [Color]] = [
        "colorbalancergb.shadows_H": hueTrack, "colorbalancergb.midtones_H": hueTrack,
        "colorbalancergb.highlights_H": hueTrack, "colorbalancergb.global_H": hueTrack,
        "temperature.red": [.cyan, .red],
        "temperature.green": [Color(red: 0.85, green: 0.3, blue: 0.85), .green],
        "temperature.g2": [Color(red: 0.85, green: 0.3, blue: 0.85), .green],
        "temperature.blue": [.yellow, .blue],
    ]

    static func range(op: String, field: EngineField) -> ClosedRange<Double>? {
        if let soft = softRanges["\(op).\(field.name)"] { return soft }
        guard let lo = field.min, let hi = field.max, lo < hi else { return nil }
        return lo...hi
    }
}

extension String {
    /// darktable names modules in lower case ("white balance"); macOS wants sentence case.
    var capitalizedSentence: String { prefix(1).uppercased() + dropFirst() }
}
