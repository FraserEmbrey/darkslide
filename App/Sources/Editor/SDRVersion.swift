import Foundation

/// Adjustments to the SDR rendition of an HDR edit only, like Lightroom's
/// SDR settings. The SDR rendition is what displays without HDR show, and the
/// base image of a JPEG with HDR gain map, so it's worth tuning on its own.
/// darktable's sidecar has nowhere for these, so they're kept per photo here.
struct SDRVersion: Codable, Equatable {
    var brightness = 0.0   // EV
    var contrast = 0.0     // -1...1, scales the tone mapper's contrast
    var saturation = 0.0   // -1...1, added to color balance rgb's saturation

    var isNeutral: Bool { self == SDRVersion() }

    private static let key = "SDRVersions"

    static func load(for photo: URL) -> SDRVersion {
        guard let all = UserDefaults.standard.dictionary(forKey: key),
              let data = all[photo.path] as? Data,
              let v = try? JSONDecoder().decode(SDRVersion.self, from: data) else { return SDRVersion() }
        return v
    }

    func save(for photo: URL) {
        var all = UserDefaults.standard.dictionary(forKey: Self.key) ?? [:]
        all[photo.path] = isNeutral ? nil : try? JSONEncoder().encode(self)
        UserDefaults.standard.set(all, forKey: Self.key)
    }
}
