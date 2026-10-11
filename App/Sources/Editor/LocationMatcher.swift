import CoreLocation
import Foundation
import ImageIO
import Photos

/// Gives photos without GPS a location from a track: a GPX file from a GPS
/// logger, watch or phone app, or the positions and times of photos that have
/// GPS, such as an iPhone's in the Photos library. A photo
/// taken between two track points goes partway along between them, in
/// proportion to the time; one near a single point takes its position.
enum LocationMatcher {
    struct TrackPoint: Sendable {
        let date: Date
        let coordinate: CLLocationCoordinate2D
    }

    enum Source: String, CaseIterable, Identifiable {
        case gpx, photosLibrary, thisView
        var id: String { rawValue }
        var title: String {
            switch self {
            case .gpx: "GPX track files"
            case .photosLibrary: "Photos library (iPhone)"
            case .thisView: "Located photos here"
            }
        }
    }

    struct Match: Sendable {
        let coordinate: CLLocationCoordinate2D
        /// how far in time from the nearest track point
        let gap: TimeInterval
    }

    // MARK: Capture times

    /// When the photo was taken. Cameras record local time, often without its
    /// zone (OffsetTimeOriginal); then `zone` is assumed. `clockOffset` corrects
    /// a camera clock that's fast (negative) or slow (positive).
    static func captureDate(of url: URL, zone: TimeZone, clockOffset: TimeInterval) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String, let z = zoneFromOffset(offset) {
            f.timeZone = z
        } else {
            f.timeZone = zone
        }
        guard var date = f.date(from: text) else { return nil }
        if let sub = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String, let frac = Double("0." + sub) {
            date += frac
        }
        return date + clockOffset
    }

    private static func zoneFromOffset(_ s: String) -> TimeZone? {
        // "+01:00"
        let sign: Int = s.hasPrefix("-") ? -1 : 1
        let parts = s.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return TimeZone(secondsFromGMT: sign * (parts[0] * 3600 + parts[1] * 60))
    }

    // MARK: Tracks

    /// photos with a location in the Photos library, between two dates
    static func photosLibraryTrack(from start: Date, to end: Date) async throws -> [TrackPoint] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw EngineError(message: "Develop needs access to Photos to use your iPhone's locations. Allow it in System Settings › Privacy & Security › Photos.")
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", start as NSDate, end as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: options)
        var points: [TrackPoint] = []
        assets.enumerateObjects { asset, _, _ in
            if let date = asset.creationDate, let location = asset.location,
               !(location.coordinate.latitude == 0 && location.coordinate.longitude == 0) {
                points.append(TrackPoint(date: date, coordinate: location.coordinate))
            }
        }
        return points
    }

    /// The timed points of GPX files (track, route and waypoints), as GPS
    /// loggers, watches and apps such as Arc, Strava or Garmin export them.
    /// GPX times are UTC; points without a time are left out.
    static func gpxTrack(_ files: [URL]) throws -> [TrackPoint] {
        var points: [TrackPoint] = []
        for file in files {
            guard let parser = XMLParser(contentsOf: file) else {
                throw EngineError(message: "Couldn't read \(file.lastPathComponent).")
            }
            let reader = GPXReader()
            parser.delegate = reader
            guard parser.parse() else {
                throw EngineError(message: "\(file.lastPathComponent) isn't a GPX file Develop can read.")
            }
            points += reader.points
        }
        return points.sorted { $0.date < $1.date }
    }

    private final class GPXReader: NSObject, XMLParserDelegate {
        var points: [TrackPoint] = []
        private var coordinate: CLLocationCoordinate2D?
        private var inTime = false
        private var time = ""
        private let iso = ISO8601DateFormatter()
        private let isoFraction: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch name {
            case "trkpt", "rtept", "wpt":
                if let lat = attributes["lat"].flatMap(Double.init), let lon = attributes["lon"].flatMap(Double.init) {
                    coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                }
                time = ""
            case "time" where coordinate != nil:
                inTime = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inTime { time += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "time":
                inTime = false
            case "trkpt", "rtept", "wpt":
                let t = time.trimmingCharacters(in: .whitespacesAndNewlines)
                if let c = coordinate, let date = isoFraction.date(from: t) ?? iso.date(from: t) {
                    points.append(TrackPoint(date: date, coordinate: c))
                }
                coordinate = nil
            default: break
            }
        }
    }

    /// photos with a location among the ones given (times from their EXIF)
    static func photosTrack(_ located: [(URL, CLLocationCoordinate2D)], zone: TimeZone) -> [TrackPoint] {
        located.compactMap { url, c in
            captureDate(of: url, zone: zone, clockOffset: 0).map { TrackPoint(date: $0, coordinate: c) }
        }
        .sorted { $0.date < $1.date }
    }

    // MARK: Matching

    /// Positions for photos taken at `dates`, from a track sorted by time.
    /// Between two points no more than `maxGap` apart, interpolated; otherwise
    /// the nearest point within `maxGap`, if any.
    static func match(_ dates: [URL: Date], track: [TrackPoint], maxGap: TimeInterval) -> [URL: Match] {
        guard !track.isEmpty else { return [:] }
        var result: [URL: Match] = [:]
        for (url, date) in dates {
            // first track point at or after the photo
            var lo = 0, hi = track.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if track[mid].date < date { lo = mid + 1 } else { hi = mid }
            }
            let after = lo < track.count ? track[lo] : nil
            let before = lo > 0 ? track[lo - 1] : nil
            if let b = before, let a = after,
               a.date.timeIntervalSince(b.date) <= maxGap * 2,
               date.timeIntervalSince(b.date) <= maxGap || a.date.timeIntervalSince(date) <= maxGap {
                let span = a.date.timeIntervalSince(b.date)
                let t = span > 0 ? date.timeIntervalSince(b.date) / span : 0
                let c = CLLocationCoordinate2D(
                    latitude: b.coordinate.latitude + (a.coordinate.latitude - b.coordinate.latitude) * t,
                    longitude: b.coordinate.longitude + (a.coordinate.longitude - b.coordinate.longitude) * t)
                result[url] = Match(coordinate: c, gap: min(date.timeIntervalSince(b.date), a.date.timeIntervalSince(date)))
            } else {
                let nearest = [before, after].compactMap { $0 }
                    .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                if let n = nearest, abs(n.date.timeIntervalSince(date)) <= maxGap {
                    result[url] = Match(coordinate: n.coordinate, gap: abs(n.date.timeIntervalSince(date)))
                }
            }
        }
        return result
    }
}
