import AppKit
import Foundation

// Headless export: another app (the home photo library) hands Darkslide raws
// and gets the exports back, each with its own edit or Auto, as Export with
// Preset makes them. Launch arguments:
//
//   -HeadlessExport /out/folder        where the exports go
//   -HeadlessFiles /tmp/list.txt       the photos, one path per line
//   -HeadlessPreset "HDR HEIC"         an export preset's name (HDR HEIC if left out)
//   -HeadlessResult /tmp/result.json   {"written": [...], "error": ...}, written last
//
// The photos are copied to a temporary folder with their sidecars and edited
// there, so nothing is written beside the originals (Auto's edit included).
// The window stays hidden, the session and workspace aren't kept (see
// Session.isTestRun), and the app quits when done.

enum HeadlessExport {
    static var outFolder: URL? { UserDefaults.standard.string(forKey: "HeadlessExport").map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static var requested: Bool { outFolder != nil }
    /// the editor, for the app delegate to start the export with
    @MainActor static var model: EditorModel?
}

extension EditorModel {
    /// Exports, writes the result, and quits: exit status 0 when something was
    /// exported, 1 otherwise. The app's own quit (applicationShouldTerminate)
    /// isn't used: it waits on main-actor tasks this would be holding up.
    func runHeadlessExport() async {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Darkslide-headless-\(UUID().uuidString)", isDirectory: true)
        let (written, problem) = await headlessExport(in: work)
        // leaving the photo saves Auto's edit, into the copy
        await prepareToQuit()
        await stopEngine()
        try? FileManager.default.removeItem(at: work)
        if let result = UserDefaults.standard.string(forKey: "HeadlessResult") {
            let body: [String: Any] = ["written": written, "error": problem ?? NSNull()]
            try? JSONSerialization.data(withJSONObject: body).write(to: URL(fileURLWithPath: result))
        }
        exit(problem == nil ? 0 : 1)
    }

    private func headlessExport(in work: URL) async -> (written: [String], problem: String?) {
        guard let out = HeadlessExport.outFolder else { return ([], "no folder for the exports") }
        let defaults = UserDefaults.standard
        let presetName = defaults.string(forKey: "HeadlessPreset") ?? "HDR HEIC"
        let list = defaults.string(forKey: "HeadlessFiles").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let photos = list.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        guard !photos.isEmpty else { return ([], "no photos given") }
        guard let preset = exportPresets.first(where: { $0.name == presetName }) else { return ([], "no export preset called \(presetName)") }
        for _ in 0..<300 where !engineReady { try? await Task.sleep(for: .milliseconds(100)) }
        guard engineReady else { return ([], "the engine didn't start") }

        // copies, each in its own folder so two photos with one name can't meet
        var copies: [URL] = []
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for (i, photo) in photos.enumerated() {
                let folder = work.appendingPathComponent("\(i)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let copy = folder.appendingPathComponent(photo.lastPathComponent)
                try FileManager.default.copyItem(at: photo, to: copy)
                let sidecar = URL(fileURLWithPath: photo.path + ".xmp")
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    try FileManager.default.copyItem(at: sidecar, to: URL(fileURLWithPath: copy.path + ".xmp"))
                }
                copies.append(copy)
            }
        } catch {
            return ([], "couldn't copy the photos: \(error.localizedDescription)")
        }

        let started = Date.now
        errorMessage = nil
        // the batch path for one photo too: it makes an SDR edit HDR for a gain map and runs Auto on unedited raws
        await exportPhotos(copies, settings: preset.settings, to: out, autoAdjust: preset.autoAdjust)
        let files = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let written = files.filter { ((try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) >= started.addingTimeInterval(-1) }
            .map(\.path).sorted()
        return (written, errorMessage ?? (written.isEmpty ? "nothing was exported" : nil))
    }
}
