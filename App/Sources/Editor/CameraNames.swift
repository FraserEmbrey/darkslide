import Foundation

/// Cameras as they're sold, not as their EXIF spells them: "NIKON
/// CORPORATION" / "NIKON Z 6_2" is a Nikon Z6 II, "SONY" / "ILCE-7M3" a
/// Sony α7 III. Unknown models keep their EXIF name, with the maker's name
/// tidied and not repeated.
enum CameraNames {
    static func display(make: String?, model: String?) -> String? {
        let maker = make.map(tidyMaker)
        guard var model = model?.trimmingCharacters(in: .whitespaces), !model.isEmpty else { return maker }
        // the maker's name again at the start of the model ("NIKON Z 6_2", "Canon EOS R5")
        for prefix in [make, maker, make?.split(separator: " ").first.map(String.init)].compactMap({ $0 }) where !prefix.isEmpty {
            if model.lowercased().hasPrefix(prefix.lowercased() + " ") { model = String(model.dropFirst(prefix.count + 1)) }
        }
        model = marketingName(model, maker: maker ?? "")
        return [maker, model].compactMap { $0 }.joined(separator: " ")
    }

    private static let makers: [String: String] = [
        "nikon": "Nikon", "sony": "Sony", "canon": "Canon", "fujifilm": "Fujifilm", "olympus": "Olympus",
        "om digital solutions": "OM System", "panasonic": "Panasonic", "leica": "Leica", "ricoh": "Ricoh",
        "pentax": "Pentax", "hasselblad": "Hasselblad", "apple": "Apple", "dji": "DJI", "sigma": "Sigma",
        "samsung": "Samsung", "google": "Google", "phase one": "Phase One", "gopro": "GoPro",
    ]

    private static func tidyMaker(_ raw: String) -> String {
        var m = raw.trimmingCharacters(in: .whitespaces)
        for suffix in [" CORPORATION", " Corporation", " Corp.", " CORP.", " Co., Ltd.", " CO.,LTD", " CO., LTD.",
                       " IMAGING CORP.", " Imaging Corp.", " OPTICAL CO.,LTD", " ELECTRIC CO.,LTD.", " AG", " Camera AG", " Inc."] {
            if m.hasSuffix(suffix) { m = String(m.dropLast(suffix.count)) }
        }
        m = m.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",.")))
        for (key, name) in makers where m.lowercased().hasPrefix(key) { return name }
        return m
    }

    private static func roman(_ n: Int) -> String {
        ["", "", "II", "III", "IV", "V", "VI", "VII", "VIII"][min(max(n, 0), 8)]
    }

    private static func marketingName(_ model: String, maker: String) -> String {
        switch maker {
        case "Nikon":
            // "Z 6_2" -> Z6 II, "Z6_3" -> Z6 III, "Z 50" -> Z50, "Z f" -> Zf
            if let m = model.wholeMatch(of: #/Z ?(\d+|f|fc)(?:_(\d))?/#) {
                let mark = m.output.2.flatMap { Int($0) }.map { " " + roman($0) } ?? ""
                return "Z\(m.output.1)\(mark)"
            }
            return model
        case "Sony":
            // "ILCE-7M3" -> α7 III, "ILCE-7RM5" -> α7R V, "ILCE-6400" -> α6400, "ILCE-1" -> α1
            if let m = model.wholeMatch(of: #/ILCE-(\d+)([A-Z]*?)(?:M(\d))?/#) {
                let mark = m.output.3.flatMap { Int($0) }.map { " " + roman($0) } ?? ""
                return "α\(m.output.1)\(m.output.2)\(mark)"
            }
            return model
        default:
            return model
        }
    }
}
