import CryptoKit
import Foundation

/// The Core ML models behind Denoise, Rescue Focus and Remove Objects. They're 30 to 50 MB
/// each, more than the rest of the app together, and most people never use
/// them, so a release leaves them out: each is downloaded the first time it's
/// wanted, from the GitHub release named in ModelManifest (made by
/// Scripts/publish-models.sh), checked against its SHA-256 and kept in
/// Application Support. A build with Models/ (Scripts/fetch-models.sh) has
/// them inside instead.
enum ModelStore {
    enum Model: String, CaseIterable, Sendable {
        case rawDenoise = "RawDenoise"
        case rescueFocus = "RescueFocus"
        case rescueMotion = "RescueMotion"
        case removeObjects = "RemoveObjects"

        var title: String {
            switch self {
            case .rawDenoise: "Denoise"
            case .rescueFocus: "Rescue Focus"
            case .rescueMotion: "Rescue Focus for camera shake"
            case .removeObjects: "Remove Objects"
            }
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Darkslide/Models", isDirectory: true)
    }

    /// the compiled model, inside the app or downloaded; nil until it's here
    static func installedURL(_ model: Model) -> URL? {
        if let inside = Bundle.main.url(forResource: model.rawValue, withExtension: "mlmodelc", subdirectory: "Models") {
            return inside
        }
        let downloaded = folder.appendingPathComponent("\(model.rawValue).mlmodelc")
        return FileManager.default.fileExists(atPath: downloaded.path) ? downloaded : nil
    }

    /// whether the model is here or can be downloaded
    static func isOffered(_ model: Model) -> Bool {
        installedURL(model) != nil || (ModelManifest.models[model.rawValue] != nil && downloadURL(model) != nil)
    }

    /// the download's size in bytes, for asking first
    static func downloadSize(_ model: Model) -> Int? { ModelManifest.models[model.rawValue]?.bytes }

    private static func downloadURL(_ model: Model) -> URL? {
        guard !ModelManifest.release.isEmpty,
              let source = Bundle.main.object(forInfoDictionaryKey: "DarkslideSourceURL") as? String else { return nil }
        return URL(string: "\(source)/releases/download/\(ModelManifest.release)/\(model.rawValue).mlmodelc.zip")
    }

    /// Downloads the model, checks it and unpacks it into the folder,
    /// reporting progress from 0 to 1.
    static func download(_ model: Model, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let url = installedURL(model) { return url }
        guard let entry = ModelManifest.models[model.rawValue], let source = downloadURL(model) else {
            throw Failure(message: "There's no download for the \(model.title) model.")
        }
        let (bytes, response) = try await URLSession.shared.bytes(from: source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(message: "The \(model.title) model couldn't be downloaded (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        var data = Data()
        data.reserveCapacity(entry.bytes)
        var buffer = [UInt8]()
        buffer.reserveCapacity(1 << 16)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == 1 << 16 {
                data.append(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                progress(min(Double(data.count) / Double(entry.bytes), 1))
            }
        }
        data.append(contentsOf: buffer)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256 else {
            throw Failure(message: "The \(model.title) model downloaded didn't match the one published, so it wasn't kept.")
        }
        // unpacked beside, then moved into place, so a half-unpacked model is never found
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent("\(model.rawValue).download.zip")
        let staging = folder.appendingPathComponent("\(model.rawValue).unpacking", isDirectory: true)
        defer {
            try? fm.removeItem(at: zip)
            try? fm.removeItem(at: staging)
        }
        try? fm.removeItem(at: staging)
        try data.write(to: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        try ditto.run()
        ditto.waitUntilExit()
        let unpacked = staging.appendingPathComponent("\(model.rawValue).mlmodelc")
        guard ditto.terminationStatus == 0, fm.fileExists(atPath: unpacked.path) else {
            throw Failure(message: "The \(model.title) model couldn't be unpacked.")
        }
        let dest = folder.appendingPathComponent("\(model.rawValue).mlmodelc")
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: unpacked, to: dest)
        return dest
    }
}
