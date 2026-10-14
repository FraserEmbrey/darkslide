import Foundation

/// darktable's "auto-apply pixel workflow defaults": the tone mapper an
/// unedited photo starts with.
enum ToneMapper: String, CaseIterable, Identifiable {
    case filmic, sigmoid, agx

    var id: String { rawValue }

    var title: String {
        switch self {
        case .filmic: "Filmic"
        case .sigmoid: "Sigmoid"
        case .agx: "AgX"
        }
    }

    var detail: String {
        switch self {
        case .filmic: "darktable's classic film-like curve, with the most tone controls."
        case .sigmoid: "darktable's current default: simpler controls, smooth highlight roll-off."
        case .agx: "Newest option, aimed at natural colour in saturated highlights."
        }
    }

    /// the value of darktable's plugins/darkroom/workflow setting
    var workflow: String {
        switch self {
        case .filmic: "scene-referred (filmic)"
        case .sigmoid: "scene-referred (sigmoid)"
        case .agx: "scene-referred (AgX)"
        }
    }
}

enum CameraStyleMode: String, CaseIterable, Identifiable {
    case suggest, automatic, off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .suggest: "Suggest"
        case .automatic: "Apply automatically"
        case .off: "Off"
        }
    }
}

/// Where darktable's GPU code runs. Metal is the default; Apple's OpenCL is
/// deprecated but kept for comparison, and CPU only is the fallback.
enum GPUBackend: String, CaseIterable, Identifiable {
    case metal, openCL, cpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .metal: "Metal"
        case .openCL: "Apple OpenCL"
        case .cpu: "CPU only"
        }
    }
}

enum SettingsKey {
    static let toneMapper = "ToneMapper"
    static let cameraStyleMode = "CameraStyleMode"
    static let canvasBackground = "CanvasBackground"
    static let gpuBackend = "GPUBackend"
    static let essentials = "Essentials"
    static let autoExposure = "AutoExposureForNewPhotos"
    static let lensCorrection = "LensCorrectionForNewPhotos"
    static let hdrLimitStops = "HDRLimitStops"
    static let autoTuneForNewPhotos = "AutoTuneForNewPhotos"
    static let newPhotoColour = "NewPhotoColour"
    static let noiseReductionFromISO = "NoiseReductionFromISO"
}

/// darktable's colour balance rgb "basic colorfulness" presets, for new photos:
/// darktable's own defaults add no colour, which looks flat next to a camera JPEG.
enum NewPhotoColour: String, CaseIterable, Identifiable {
    case none, standard, naturalSkin, vibrant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .standard: "Standard"
        case .naturalSkin: "Natural skin"
        case .vibrant: "Vibrant"
        }
    }

    /// the preset's title as darktable shows it
    var presetTitle: String? {
        switch self {
        case .none: nil
        case .standard: "basic colorfulness | standard"
        case .naturalSkin: "basic colorfulness | natural skin"
        case .vibrant: "basic colorfulness | vibrant colors"
        }
    }
}

/// What surrounds the photo. A neutral grey avoids the simultaneous-contrast
/// shift a dark or white surround gives, which is why darktable defaults to grey.
enum CanvasBackground: String, CaseIterable, Identifiable {
    case dark, grey, white

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: "Dark"
        case .grey: "Neutral Grey"
        case .white: "White"
        }
    }

    /// sRGB grey level. Neutral grey is L* 50 (#777777).
    var level: Double {
        switch self {
        case .dark: 0.13
        case .grey: 119.0 / 255
        case .white: 1
        }
    }
}
