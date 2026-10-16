import CoreImage
import CryptoKit
import Foundation

/// One of the Apple raw engine's own settings (Core Image's CIRAWFilter), shown
/// when it decodes the open photo. Its default is the camera's, as macOS sets it.
struct AppleRawControl: Identifiable, Sendable {
    enum Group: Sendable { case tone, detail }

    let id: String
    let title: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    let unit: String?
    let group: Group
}

/// The Apple raw engine settings changed for one photo, kept per photo like
/// the decoder choice. Applied when macOS decodes it; the decoded TIFF is
/// cached per set of settings.
struct AppleRawSettings: Codable, Equatable, Sendable {
    var values: [String: Double] = [:]
    var lensCorrection: Bool?

    var isEmpty: Bool { values.isEmpty && lensCorrection == nil }

    private static let key = "AppleRawSettings"

    static func stored(for photo: URL) -> AppleRawSettings {
        guard let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Data],
              let data = all[photo.path],
              let s = try? JSONDecoder().decode(AppleRawSettings.self, from: data) else { return AppleRawSettings() }
        return s
    }

    func store(for photo: URL) {
        var all = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        all[photo.path] = isEmpty ? nil : try? JSONEncoder().encode(self)
        UserDefaults.standard.set(all, forKey: Self.key)
    }

    /// part of the cached TIFF's name, so each set of settings has its own decode
    var cacheSuffix: String {
        guard !isEmpty else { return "" }
        let text = values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            + "|lens=\(lensCorrection.map { "\($0)" } ?? "-")"
        return "-" + SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Darkslide's HDR amount when it isn't changed: Apple's rendering as Photos
    /// shows it, in HDR (see AppleRawFallback.decodedTIFF)
    static let defaultHDRAmount = 1.0

    func apply(to filter: CIRAWFilter) {
        filter.extendedDynamicRangeAmount = Float(values["hdr"] ?? Self.defaultHDRAmount)
        for (key, value) in values where key != "hdr" { Self.set(key, Float(value), on: filter) }
        if let lensCorrection, filter.isLensCorrectionSupported { filter.isLensCorrectionEnabled = lensCorrection }
    }

    /// The controls this photo's decoder offers, with the camera's defaults.
    static func controls(for filter: CIRAWFilter) -> [AppleRawControl] {
        var list: [AppleRawControl] = [
            AppleRawControl(id: "exposure", title: "Exposure", range: -3...3, defaultValue: Double(filter.exposure), unit: "EV", group: .tone),
            AppleRawControl(id: "boost", title: "Boost", range: 0...1, defaultValue: Double(filter.boostAmount), unit: nil, group: .tone),
            AppleRawControl(id: "shadowBoost", title: "Shadow boost", range: 0...2, defaultValue: Double(filter.boostShadowAmount), unit: nil, group: .tone),
        ]
        if filter.isLocalToneMapSupported {
            list.append(AppleRawControl(id: "localToneMap", title: "Local tone mapping", range: 0...1, defaultValue: Double(filter.localToneMapAmount), unit: nil, group: .tone))
        }
        list.append(AppleRawControl(id: "hdr", title: "HDR amount", range: 0...2, defaultValue: defaultHDRAmount, unit: nil, group: .tone))
        if filter.isLuminanceNoiseReductionSupported {
            list.append(AppleRawControl(id: "luminanceNR", title: "Luminance noise reduction", range: 0...1, defaultValue: Double(filter.luminanceNoiseReductionAmount), unit: nil, group: .detail))
        }
        if filter.isColorNoiseReductionSupported {
            list.append(AppleRawControl(id: "colorNR", title: "Colour noise reduction", range: 0...1, defaultValue: Double(filter.colorNoiseReductionAmount), unit: nil, group: .detail))
        }
        if filter.isSharpnessSupported {
            list.append(AppleRawControl(id: "sharpness", title: "Sharpness", range: 0...1, defaultValue: Double(filter.sharpnessAmount), unit: nil, group: .detail))
        }
        if filter.isContrastSupported {
            list.append(AppleRawControl(id: "contrast", title: "Contrast", range: 0...1, defaultValue: Double(filter.contrastAmount), unit: nil, group: .detail))
        }
        if filter.isDetailSupported {
            list.append(AppleRawControl(id: "detail", title: "Detail", range: 0...1, defaultValue: Double(filter.detailAmount), unit: nil, group: .detail))
        }
        if filter.isMoireReductionSupported {
            list.append(AppleRawControl(id: "moire", title: "Moiré reduction", range: 0...1, defaultValue: Double(filter.moireReductionAmount), unit: nil, group: .detail))
        }
        return list
    }

    private static func set(_ key: String, _ v: Float, on f: CIRAWFilter) {
        switch key {
        case "exposure": f.exposure = v
        case "boost": f.boostAmount = v
        case "shadowBoost": f.boostShadowAmount = v
        case "localToneMap": if f.isLocalToneMapSupported { f.localToneMapAmount = v }
        case "luminanceNR": if f.isLuminanceNoiseReductionSupported { f.luminanceNoiseReductionAmount = v }
        case "colorNR": if f.isColorNoiseReductionSupported { f.colorNoiseReductionAmount = v }
        case "sharpness": if f.isSharpnessSupported { f.sharpnessAmount = v }
        case "contrast": if f.isContrastSupported { f.contrastAmount = v }
        case "detail": if f.isDetailSupported { f.detailAmount = v }
        case "moire": if f.isMoireReductionSupported { f.moireReductionAmount = v }
        default: break
        }
    }
}
