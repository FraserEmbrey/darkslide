import Foundation

/// darktable's bundled styles, parsed from their names, plus the camera
/// matching darktable's own apply_camera_style.lua does.
///
/// Camera styles are named like
///   _l10n_darktable|_l10n_camera styles|Sony|ILCE...|ILCE-7M3
///   _l10n_darktable|_l10n_camera styles|Canon|EOS...|EOS R? series
///   _l10n_darktable|_l10n_camera styles|Canon|EOS...|EOS [200D Mark II,250D]
///   _l10n_darktable|_l10n_camera styles|Canon|_l10n_generic
/// where "?" stands for one optional character and "[a,b]" for alternatives.
struct StyleInfo: Identifiable, Hashable, Sendable {
    let name: String        // darktable's full style name, used to apply it
    let path: [String]      // display path, "_l10n_" markers removed
    let cameraMaker: String?
    let isGeneric: Bool
    fileprivate let exactModels: [String]
    fileprivate let patterns: [String]   // regex sources, anchored

    var id: String { name }
    var isCameraStyle: Bool { cameraMaker != nil }

    var title: String {
        if isGlobalGeneric { return "Generic camera look" }
        if let maker = cameraMaker, isGeneric { return "\(maker) (generic)" }
        if let maker = cameraMaker { return "\(maker) \(path.last ?? "")" }
        return path.last ?? name
    }

    /// The group shown in menus, e.g. "Camera styles › Sony" or "Examples › Colours".
    var group: [String] { Array(path.dropLast().drop { $0 == "darktable" }) }

    init(name: String) {
        self.name = name
        let parts = name.split(separator: "|").map { String($0).replacingOccurrences(of: "_l10n_", with: "") }
        path = parts.first == "darktable" ? Array(parts.dropFirst()) : parts

        guard path.first == "camera styles", path.count >= 2 else {
            cameraMaker = nil; isGeneric = false; exactModels = []; patterns = []
            return
        }
        if path.count == 2, path[1] == "generic" {
            cameraMaker = nil; isGeneric = true; exactModels = []; patterns = []
            // global generic: kept as a camera style with no maker
            self.globalGeneric = true
            return
        }
        cameraMaker = path[1]
        isGeneric = path.last == "generic"
        if isGeneric { exactModels = []; patterns = []; return }

        var exact: [String] = []
        var regexes: [String] = []
        for model in Self.expandSets(path.last ?? "") {
            var m = model.lowercased()
            let isSeries = m.hasSuffix(" series")
            if isSeries { m.removeLast(" series".count) }
            if isSeries || m.contains("?") {
                // "?" is one optional character; spaces are optional too
                var re = NSRegularExpression.escapedPattern(for: m)
                re = re.replacingOccurrences(of: "\\?", with: "[a-z0-9]?")
                re = re.replacingOccurrences(of: " ", with: " ?")
                regexes.append("^\(re)$")
            } else {
                exact.append(Self.squash(m))
            }
        }
        exactModels = exact
        patterns = regexes
    }

    private var globalGeneric = false
    var isGlobalGeneric: Bool { globalGeneric }

    /// "EOS [200D Mark II,250D]" -> ["EOS 200D Mark II", "EOS 250D"]
    static func expandSets(_ s: String) -> [String] {
        guard let open = s.firstIndex(of: "["), let close = s[open...].firstIndex(of: "]") else { return [s] }
        let head = s[..<open], tail = s[s.index(after: close)...]
        return s[s.index(after: open)..<close].split(separator: ",").map {
            "\(head)\($0.trimmingCharacters(in: .whitespaces))\(tail)"
        }
    }

    /// Lower case without spaces or hyphens, so "EOS-1D X" matches "EOS 1D X".
    static func squash(_ s: String) -> String {
        s.lowercased().filter { $0 != " " && $0 != "-" }
    }

    fileprivate func matchesExactly(_ models: [String]) -> Bool {
        models.contains { exactModels.contains(Self.squash($0)) }
    }

    fileprivate func matchesPattern(_ models: [String]) -> Bool {
        patterns.contains { p in
            models.contains { $0.lowercased().range(of: p, options: .regularExpression) != nil }
        }
    }
}

enum CameraStyles {
    /// Best camera style for a camera: exact model, then a series pattern,
    /// then the maker's generic look, then darktable's generic one.
    static func suggestion(in styles: [StyleInfo], maker: String, model: String, alias: String) -> StyleInfo? {
        let makerKey = normaliseMaker(maker)
        let forMaker = styles.filter { $0.cameraMaker.map(normaliseMaker) == makerKey }
        let models = [model, alias].filter { !$0.isEmpty }
        // only a style made for this camera or its series: the maker's and
        // darktable's generic styles aren't that camera's look (a Leica M11
        // Monochrom would get a colour look made for nothing in particular)
        return forMaker.first { !$0.isGeneric && $0.matchesExactly(models) }
            ?? forMaker.first { !$0.isGeneric && $0.matchesPattern(models) }
    }

    private static func normaliseMaker(_ m: String) -> String {
        let l = m.lowercased()
        for prefix in ["fujifilm", "leica", "minolta", "olympus", "om digital", "ricoh", "pentax", "sony", "panasonic"]
        where l.hasPrefix(prefix) { return prefix }
        return l
    }
}
