import Foundation

/// Film speeds, for darktable's grain: its coarseness is a film speed (darktable
/// shows 20 to 6400; it stores that divided by 213.2). The slider works in
/// stops, so a third of a stop is the same distance at ISO 25 and ISO 3200, and
/// reads the nominal speed for each third.
enum FilmSpeed {
    /// darktable's GRAIN_SCALE_FACTOR
    static let grainFactor = 213.2
    static let range = 20.0...6400.0

    /// the speeds printed on film boxes, a third of a stop apart
    static let nominal: [Double] = [20, 25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640,
                                    800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400]

    /// stops from ISO 100
    static func stops(_ iso: Double) -> Double { log2(max(iso, 1) / 100) }

    /// the speed at `stops` from ISO 100: the nominal one if it's within a sixth of a stop
    static func iso(stops: Double) -> Double {
        let raw = 100 * pow(2, stops)
        if let near = nominal.min(by: { abs(log2($0 / raw)) < abs(log2($1 / raw)) }), abs(log2(near / raw)) < 1.0 / 6 {
            return near
        }
        return raw.rounded()
    }

    /// The film's speed, pushed or pulled a stop for each + or −: from the
    /// number in its name (Tri-X 400, Portra 160 NC, Fuji 400H), or for films
    /// whose name doesn't give it (Polaroid's pack numbers, HP5, XP2), known.
    /// Nil for looks that aren't a film.
    static func of(_ look: FilmLook) -> Double? {
        guard let base = of(film: look.film) else { return nil }
        let push = (look.variant ?? "").reduce(0) { $0 + ($1 == "+" ? 1 : $1 == "−" || $1 == "-" ? -1 : 0) }
        return min(max(base * pow(2, Double(push)), range.lowerBound), range.upperBound)
    }

    static func of(film name: String) -> Double? {
        let lower = name.lowercased()
        for (key, iso) in known where lower.contains(key) { return iso }
        // the first number in the name that's a film speed: "TMAX 3200 3 Alt" is 3200, "Retro 80s" 80
        for word in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            // digits then letters only ("400", "160C", "80s"); "HP5" or "3" (a variant number) aren't speeds
            let digits = word.prefix { $0.isNumber }
            guard digits.count >= 2, digits.count <= 4, word.dropFirst(digits.count).allSatisfy(\.isLetter),
                  let n = Double(digits), n >= 12, n <= 6400 else { continue }
            return n
        }
        return nil
    }

    /// films whose name has no speed, or a number that isn't one; checked first, in order
    private static let known: KeyValuePairs<String, Double> = [
        "polaroid 664": 100, "polaroid 665": 80, "polaroid 667": 3000, "polaroid 672": 3000,
        "polaroid 669": 80, "polaroid 690": 100, "px-680": 640, "px-70": 100, "px-100": 100,
        "polachrome": 40, "time zero": 160, "fp-3000": 3200, "fp-100": 100,
        "hp5": 400, "xp2": 400, "hie": 400,
    ]
}
