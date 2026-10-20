import CoreGraphics
import CoreImage
import Foundation

/// Runs darkroom-helper (the darktable engine) as a child process.
///
/// Requests go out as JSON lines on the helper's stdin and replies come back
/// in order on its stdout, so a FIFO of continuations is all the matching
/// needed. Pixels don't travel through the pipe: the helper writes BGRA8 into
/// a shared frame file that we read after each render.
actor Engine {
    /// darktable's configuration folder (watermarks, presets and styles live here)
    let configDir: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let frameURL: URL
    private var pending: [CheckedContinuation<Data, Error>] = []
    private var exited = false

    /// Called on the main actor if the helper dies, so the UI can recover.
    private let onExit: @Sendable (Int32) -> Void

    /// `workflow` is darktable's default tone mapper for unedited photos, e.g.
    /// "scene-referred (filmic)". darktable fixes it at startup.
    init(workflow: String, backend: GPUBackend, onExit: @escaping @Sendable (Int32) -> Void) throws {
        let fm = FileManager.default
        // EngineConfigDir: launch argument (-EngineConfigDir /path) for testing: darktable's
        // settings and lock elsewhere, so a test copy runs beside the user's
        let support = try UserDefaults.standard.string(forKey: "EngineConfigDir").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Darkslide/darktable", isDirectory: true)
        configDir = support
        let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)
            .appendingPathComponent("Darkslide", isDirectory: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)

        Engine.removeOrphanFrames(in: caches)
        frameURL = caches.appendingPathComponent("frame-\(ProcessInfo.processInfo.processIdentifier).bin")
        self.onExit = onExit

        process.executableURL = try Engine.helperURL()
        process.arguments = [
            "--frame", frameURL.path,
            "--configdir", support.path,
            "--cachedir", caches.appendingPathComponent("darktable").path,
            "--workflow", workflow,
            // darktable's own settings for its GPU path follow "--"
            "--",
        ] + Engine.gpuArguments(backend)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
    }

    /// Frames left by app processes that quit without stopping the engine
    /// (a crash, a force quit, a test run): each is a full-size render.
    private static func removeOrphanFrames(in caches: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: caches.path) else { return }
        for name in names where name.hasPrefix("frame-") {
            let pid = name.dropFirst("frame-".count).prefix { $0.isNumber }
            guard let id = Int32(pid), id != ProcessInfo.processInfo.processIdentifier else { continue }
            // kill with no signal: fails with ESRCH when no such process
            if kill(id, 0) == -1 && errno == ESRCH {
                try? fm.removeItem(at: caches.appendingPathComponent(name))
            }
        }
    }

    /// darktable settings for the chosen GPU backend. Metal is MetalCL, which
    /// darktable loads in place of Apple's OpenCL library (Engine/metalcl).
    private static func gpuArguments(_ backend: GPUBackend) -> [String] {
        switch backend {
        case .cpu:
            return ["--conf", "opencl=FALSE"]
        case .openCL:
            return ["--conf", "opencl=TRUE"]
        case .metal:
            guard let helper = try? helperURL() else { return ["--conf", "opencl=TRUE"] }
            // engine/bin/darkroom-helper -> engine/lib/libMetalCL.dylib
            let lib = helper.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lib/libMetalCL.dylib")
            guard FileManager.default.fileExists(atPath: lib.path) else { return ["--conf", "opencl=TRUE"] }
            return ["--conf", "opencl=TRUE", "--conf", "opencl_library=\(lib.path)"]
        }
    }

    /// The bundled helper, or DARKSLIDE_ENGINE for running from a dev checkout.
    private static func helperURL() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["DARKSLIDE_ENGINE"] {
            return URL(fileURLWithPath: path)
        }
        if let url = Bundle.main.resourceURL?.appendingPathComponent("engine/bin/darkroom-helper"),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        throw EngineError(message: "The darktable engine is missing from the app bundle.")
    }

    /// Launches the helper and waits for its ready event.
    func start() async throws {
        let ready = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            pending.append(c)
            process.terminationHandler = { [weak self] p in
                Task { await self?.handleExit(p.terminationStatus) }
            }
            do { try process.run() } catch {
                pending.removeAll()
                c.resume(throwing: error)
                return
            }
            let handle = output.fileHandleForReading
            Task.detached { [weak self] in
                do {
                    for try await line in handle.bytes.lines {
                        await self?.deliver(Data(line.utf8))
                    }
                } catch {}
            }
        }
        _ = ready
    }

    /// Asks the helper to quit and waits for it (up to 3 s, then terminates
    /// it), so a replacement can take darktable's database lock.
    func stop() async {
        guard process.isRunning else { return }
        try? send(raw: ["cmd": "quit"])
        for _ in 0..<30 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: frameURL)
    }

    // MARK: Commands

    /// `hdrSource`: an image already rendered with highlights above SDR white
    /// (see sdrFromHDR and the helper's "HDR white"), decoded by macOS
    func open(_ url: URL, hdrSource: Bool = false) async throws -> OpenReply {
        sdrFromHDR = hdrSource
        // the last photo's frame mustn't stand in for this one
        lastHDRSource = nil
        lastSDRBase = nil
        // Opening has hung once on a lock inside darktable that an earlier call
        // left held. Rather than wait for ever, a stuck open stops the engine,
        // which fails the request and makes the app start a fresh one.
        openGeneration += 1
        let generation = openGeneration
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled else { return }
            await self?.stopIfStillOpening(generation)
        }
        defer { watchdog.cancel() }
        do {
            // the HDR limit caps the helper's HDR curve (see its _sync_hdr_white)
            return try await request(["cmd": "open", "path": url.photoFile.path, "version": url.versionNumber, "hdrSource": hdrSource,
                                      "hdrLimitStops": UserDefaults.standard.double(forKey: SettingsKey.hdrLimitStops)],
                                     as: OpenReply.self)
        } catch where hungOnOpen {
            throw EngineError(message: "The engine stopped responding while opening it, so it has been restarted. Try opening it again.")
        }
    }

    private var openGeneration = 0
    private var hungOnOpen = false

    private func stopIfStillOpening(_ generation: Int) {
        guard generation == openGeneration, process.isRunning, !pending.isEmpty else { return }
        hungOnOpen = true
        process.terminate()
    }

    func set(module: String, field: String, value: FieldValue) async throws {
        _ = try await request(["cmd": "set", "module": module, "field": field, "value": value.json])
    }

    /// several settings in one round trip
    func setMany(_ items: [(module: String, field: String, value: FieldValue)]) async throws {
        guard !items.isEmpty else { return }
        let reply = try await request(["cmd": "set_many",
                                       "items": items.map { ["module": $0.module, "field": $0.field, "value": $0.value.json] }])
        if UserDefaults.standard.bool(forKey: "LogRenderTimes"),
           let ms = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["ms"] as? Int {
            FileHandle.standardError.write("Darkslide set_many \(items.count) in helper \(ms) ms\n".data(using: .utf8)!)
        }
    }

    /// the app's undo step ends here: the next change starts a history item of its own
    func newStep() async throws {
        _ = try await request(["cmd": "new_step"])
    }

    func enable(module: String, on: Bool) async throws {
        _ = try await request(["cmd": "enable", "module": module, "on": on])
    }

    func reset(module: String) async throws -> [EngineModule] {
        try await request(["cmd": "reset", "module": module], as: ModulesReply.self).modules
    }

    func styles() async throws -> [String] {
        try await request(["cmd": "styles"], as: StylesReply.self).styles
    }

    /// Appends a style to the current edit, as darktable's default apply mode does.
    struct StyleReply: Decodable { let historyEndBefore: Int; let modules: [EngineModule] }

    func applyStyle(_ name: String) async throws -> StyleReply {
        try await request(["cmd": "apply_style", "name": name], as: StyleReply.self)
    }

    /// the HDR limit changed: the helper's HDR curve rises to the new peak
    func setHDRLimit(stops: Double) async throws -> [EngineModule] {
        try await request(["cmd": "hdr_limit", "stops": stops], as: ModulesReply.self).modules
    }

    /// steps the edit's history to `end` items (darktable's history stack)
    func setHistoryEnd(_ end: Int) async throws -> [EngineModule] {
        try await request(["cmd": "history_end", "end": end], as: ModulesReply.self).modules
    }

    /// Fits the tone equalizer's mask to the photo, as darktable's two wand
    /// buttons do. Returns the updated modules.
    func fitToneEqualizer() async throws -> [EngineModule] {
        try await request(["cmd": "toneequal_fit"], as: ModulesReply.self).modules
    }

    struct ExportReply: Decodable { let file: String; let ms: Int }

    /// Exports through darktable's own export path. `path` has no extension;
    /// darktable adds the format's. `maxEdge` 0 keeps the full size.
    /// `profile` is darktable's colour profile type, or nil for the edit's own.
    /// `sdrFromHDR`: an SDR file from an edit with an HDR profile, exported as
    /// its SDR rendition (no HDR white scaling, tone mappers at 100% white)
    /// `source`: another photo, exported with its own saved edit, instead of the open one.
    func export(path: String, format: String, quality: Int, bitDepth: Int, maxEdge: Int,
                profile: Int?, sdrFromHDR: Bool = false, source: URL? = nil) async throws -> URL {
        var body: [String: Any] = ["cmd": "export", "path": path, "format": format, "quality": quality,
                                   "bpp": bitDepth, "max": maxEdge, "icc": profile ?? -1, "sdrFromHDR": sdrFromHDR]
        if let source { body["source"] = source.path }
        let reply = try await request(body, as: ExportReply.self)
        return URL(fileURLWithPath: reply.file)
    }

    /// filmic's "auto tune levels": white and black relative exposure from the photo
    func filmicAutoTune() async throws -> [EngineModule] {
        try await request(["cmd": "filmic_autotune"], as: ModulesReply.self).modules
    }

    /// discards the edit; darktable re-applies its defaults for a new photo
    func resetAll() async throws -> [EngineModule] {
        try await request(["cmd": "reset_all"], as: ModulesReply.self).modules
    }

    /// Geotags a photo (open or not) in its XMP sidecar, as darktable's map
    /// view does; nil removes the location.
    func setLocation(path: String, latitude: Double?, longitude: Double?) async throws {
        var body: [String: Any] = ["cmd": "set_location", "path": path]
        if let latitude, let longitude { body["lat"] = latitude; body["lon"] = longitude }
        _ = try await request(body)
    }

    /// Sets a photo's title and/or star rating (0-5, -1 rejected) in its sidecar.
    func setInfo(path: String, title: String? = nil, caption: String? = nil, addKeyword: String? = nil,
                 removeKeyword: String? = nil, rating: Int? = nil) async throws {
        var body: [String: Any] = ["cmd": "set_info", "path": path]
        if let title { body["title"] = title }
        if let caption { body["caption"] = caption }
        if let addKeyword { body["addTag"] = addKeyword }
        if let removeKeyword { body["removeTag"] = removeKeyword }
        if let rating { body["rating"] = rating }
        _ = try await request(body)
    }

    struct CurveReply: Decodable {
        let enabled: Bool
        let compensated: Bool
        let linked: Bool
        let nodes: [[[Double]]]   // per channel: [x, y] points
        let histogram: [Int]      // the curve's input, 256 bins on its scale
        var channels: [[Int]]? = nil   // the same, per red, green and blue
    }

    struct LensfunLens: Decodable, Hashable, Identifiable {
        let maker: String
        let model: String
        let minFocal: Double
        let maxFocal: Double
        let aperture: Double
        var id: String { model }
    }
    struct LensfunCamera: Decodable, Hashable, Identifiable {
        let maker: String
        let model: String
        let mount: String
        let crop: Double
        var id: String { maker + " " + model }
    }
    private struct LensesReply: Decodable { let camera: String; let lenses: [LensfunLens] }
    private struct CamerasReply: Decodable { let cameras: [LensfunCamera] }

    /// Lensfun's lenses that fit the lens module's camera
    func lensfunLenses() async throws -> (camera: String, lenses: [LensfunLens]) {
        let r = try await request(["cmd": "lens_lenses", "query": ""], as: LensesReply.self)
        return (r.camera, r.lenses)
    }

    /// Lensfun's cameras matching a search
    func lensfunCameras(matching query: String) async throws -> [LensfunCamera] {
        try await request(["cmd": "lens_cameras", "query": query], as: CamerasReply.self).cameras
    }

    /// sets a text setting (a char array), such as the lens module's lens, and returns the modules
    func setText(module: String, field: String, value: String) async throws -> [EngineModule] {
        _ = try await request(["cmd": "set_text", "module": module, "field": field, "value": value])
        return try await request(["cmd": "modules"], as: ModulesReply.self).modules
    }

    /// a local adjustment's shape in output pixels (see the helper's "shape")
    struct ShapeReply: Decodable {
        let kind: String
        let points: [Double]
        var compression: Double? = nil
        var border: Double? = nil
        /// a subject's traced outlines, each x, y, x, y…
        var outlines: [[Double]]? = nil
    }

    /// A local adjustment masked to a subject: `mask` holds one byte a pixel
    /// (255 inside), `width` × `height`, over the photo as processed. The
    /// engine traces it into darktable paths, as darktable's AI masks are.
    func addSubject(base: String, name: String, mask: URL, width: Int, height: Int) async throws -> InstanceReply {
        try await request(["cmd": "add_local", "module": base, "shape": "subject", "name": name,
                           "mask": mask.path, "maskWidth": width, "maskHeight": height], as: InstanceReply.self)
    }

    func addLocal(base: String, shape: String, name: String) async throws -> InstanceReply {
        try await request(["cmd": "add_local", "module": base, "shape": shape, "name": name], as: InstanceReply.self)
    }

    /// another module for a local adjustment, masked by the same shape as `shareWith`
    func addLocal(base: String, shareWith: String, name: String) async throws -> InstanceReply {
        try await request(["cmd": "add_local", "module": base, "shareWith": shareWith, "name": name], as: InstanceReply.self)
    }

    /// a local adjustment masked by a brush stroke, in output pixels
    func addBrush(base: String, name: String, points: [CGPoint], radius: Double, hardness: Double) async throws -> InstanceReply {
        try await request(["cmd": "add_local", "module": base, "shape": "brush", "name": name,
                           "points": points.flatMap { [$0.x, $0.y] }, "radius": radius, "hardness": hardness], as: InstanceReply.self)
    }

    /// another stroke on a brushed adjustment; `also` are its other instances, sharing its strokes
    func addStroke(module: String, also: [String], points: [CGPoint], radius: Double, hardness: Double, erase: Bool) async throws {
        _ = try await request(["cmd": "add_stroke", "module": module, "also": also, "points": points.flatMap { [$0.x, $0.y] },
                               "radius": radius, "hardness": hardness, "erase": erase])
    }

    func setGradient(module: String, anchor: CGPoint, toward: CGPoint, compression: Double?) async throws {
        var body: [String: Any] = ["cmd": "set_shape", "module": module,
                                   "anchor": [anchor.x, anchor.y], "toward": [toward.x, toward.y]]
        if let compression { body["compression"] = compression }
        _ = try await request(body)
    }

    func setEllipse(module: String, center: CGPoint, a: CGPoint, b: CGPoint, border: Double?) async throws {
        var body: [String: Any] = ["cmd": "set_shape", "module": module, "center": [center.x, center.y],
                                   "a": [a.x, a.y], "b": [b.x, b.y]]
        if let border { body["border"] = border }
        _ = try await request(body)
    }

    // MARK: Spots (darktable's retouch module)

    struct Spot: Decodable, Identifiable, Equatable, Sendable {
        let id: Int
        var x, y, r, sx, sy: Double
        var clone: Bool
        var center: CGPoint { CGPoint(x: x, y: y) }
        var source: CGPoint { CGPoint(x: sx, y: sy) }
    }
    struct SpotsReply: Decodable {
        let spots: [Spot]
        var added: Int? = nil
        var modules: [EngineModule]? = nil
    }

    func spots() async throws -> [Spot] { try await request(["cmd": "spots"], as: SpotsReply.self).spots }

    /// a spot healed (or cloned) from `source`, in output pixels
    func addSpot(at c: CGPoint, radius: Double, source: CGPoint, clone: Bool) async throws -> SpotsReply {
        try await request(["cmd": "add_spot", "x": c.x, "y": c.y, "r": radius, "sx": source.x, "sy": source.y, "clone": clone],
                          as: SpotsReply.self)
    }

    func moveSpot(_ s: Spot) async throws {
        _ = try await request(["cmd": "move_spot", "id": s.id, "x": s.x, "y": s.y, "r": s.r, "sx": s.sx, "sy": s.sy])
    }

    func removeSpot(_ id: Int) async throws -> [Spot] {
        try await request(["cmd": "remove_spot", "id": id], as: SpotsReply.self).spots
    }

    func renameInstance(_ module: String, to name: String) async throws -> [EngineModule] {
        try await request(["cmd": "rename_instance", "module": module, "name": name], as: ModulesReply.self).modules
    }

    private struct PointsReply: Decodable { let points: [Double] }

    /// points 0...1 across the photo as the camera framed it, to where they
    /// land in the photo as processed (output pixels), through crop, rotation
    /// and lens corrections (see the helper's "to_output")
    func toOutput(_ points: [CGPoint]) async throws -> [CGPoint] {
        let r = try await request(["cmd": "to_output", "points": points.flatMap { [$0.x, $0.y] }], as: PointsReply.self)
        return stride(from: 0, to: r.points.count - 1, by: 2).map { CGPoint(x: r.points[$0], y: r.points[$0 + 1]) }
    }

    /// output pixels to darktable's input, normalised: the inverse of toOutput
    func toInput(_ points: [CGPoint]) async throws -> [CGPoint] {
        let r = try await request(["cmd": "to_input", "points": points.flatMap { [$0.x, $0.y] }], as: PointsReply.self)
        return stride(from: 0, to: r.points.count - 1, by: 2).map { CGPoint(x: r.points[$0], y: r.points[$0 + 1]) }
    }

    func shape(module: String) async throws -> ShapeReply {
        try await request(["cmd": "shape", "module": module], as: ShapeReply.self)
    }

    struct PresetInfo: Decodable, Hashable {
        let op: String
        let name: String        // as stored; darktable's own start "_builtin_"
        let title: String       // as shown
        let builtin: Bool
    }
    private struct PresetsReply: Decodable { let presets: [PresetInfo] }

    /// darktable's presets for the open photo's modules (its own and the user's)
    func presets() async throws -> [PresetInfo] {
        try await request(["cmd": "presets"], as: PresetsReply.self).presets
    }

    func applyPreset(_ name: String, module: String) async throws -> [EngineModule] {
        try await request(["cmd": "apply_preset", "module": module, "name": name], as: ModulesReply.self).modules
    }

    func savePreset(_ name: String, module: String) async throws {
        _ = try await request(["cmd": "save_preset", "module": module, "name": name])
    }

    func deletePreset(_ name: String, op: String) async throws {
        _ = try await request(["cmd": "delete_preset", "op": op, "name": name])
    }

    struct LookReply: Decodable {
        let file: String
        let strength: Double
        let modules: [EngineModule]
    }

    /// a film look: `file` relative to `folder` ("" for none), `strength` 0 to
    /// 100; with neither, only reports the current look
    func look(folder: String?, file: String?, strength: Double?) async throws -> LookReply {
        var body: [String: Any] = ["cmd": "look"]
        if let folder { body["folder"] = folder }
        if let file { body["file"] = file }
        if let strength { body["strength"] = strength }
        return try await request(body, as: LookReply.self)
    }

    struct PasteReply: Decodable {
        let pasted: Int
        var modules: [EngineModule]? = nil
    }

    /// pastes `source`'s adjustments (only `modules`, if given) onto `targets`;
    /// modules come back when the open photo was one of them
    func paste(from source: URL, modules: [String]?, onto targets: [URL]) async throws -> PasteReply {
        var body: [String: Any] = ["cmd": "paste", "source": source.path, "targets": targets.map(\.path)]
        if let modules { body["modules"] = modules }
        return try await request(body, as: PasteReply.self)
    }

    /// the open raw's Bayer mosaic, written to `file` as float32 sensor values
    func rawMosaic(to file: URL) async throws -> RawDenoise.Layout {
        try await request(["cmd": "raw_mosaic", "path": file.path], as: RawDenoise.Layout.self)
    }

    /// a Bayer DNG at `path` from a uint16 mosaic of the open raw's size, with
    /// the original's Exif and the open photo's edit in its sidecar
    func writeDNG(mosaic: URL, to path: URL) async throws {
        _ = try await request(["cmd": "write_dng", "mosaic": mosaic.path, "path": path.path])
    }

    /// AI raw denoise on the open raw, in place (see RawDenoise): `mosaic`,
    /// a uint16 file of the raw denoised at full strength, is sent once;
    /// `amount` (0 to 1) blends it with the original. Closing the photo puts
    /// the original back, and the before view always shows it.
    func setDenoise(mosaic: URL?, amount: Double) async throws {
        var command: [String: Any] = ["cmd": "denoise", "amount": amount]
        if let mosaic { command["mosaic"] = mosaic.path }
        _ = try await request(command)
    }

    struct InstanceReply: Decodable {
        let added: String
        let modules: [EngineModule]
    }

    /// a new instance of a module, after it, off and at defaults; `name` is
    /// kept in the sidecar, so the app can find the instance again
    func addInstance(of module: String, name: String) async throws -> InstanceReply {
        try await request(["cmd": "add_instance", "module": module, "name": name], as: InstanceReply.self)
    }

    /// an rgb curve's points and the histogram of its input (from the last render)
    func curve(module: String) async throws -> CurveReply {
        try await request(["cmd": "curve", "module": module], as: CurveReply.self)
    }

    private struct AutoExposureReply: Decodable { let exposure: Double }

    /// the manual exposure darktable's automatic mode would give this photo,
    /// worked out for any file (darktable's own only runs on mosaic raws);
    /// `standard` uses darktable's default rule, else the module's own settings
    func autoExposure(module: String, standard: Bool = true) async throws -> Double {
        try await request(["cmd": "auto_exposure", "module": module, "standard": standard], as: AutoExposureReply.self).exposure
    }

    /// sets one channel of an rgb curve; points on the middle-grey-compensated scale
    func setCurve(module: String, channel: Int, nodes: [CGPoint], linked: Bool) async throws {
        _ = try await request(["cmd": "set_curve", "module": module, "channel": channel, "linked": linked,
                               "nodes": nodes.map { [Double($0.x), Double($0.y)] }])
    }

    func save() async throws {
        _ = try await request(["cmd": "save"])
    }

    /// A rendered frame. HDR frames carry their analysis and an overlay
    /// marking pixels brighter than the display can show.
    struct Frame: Sendable {
        let image: CGImage
        let isHDR: Bool
        let analysis: HDRAnalysis?
        let overlay: CGImage?
        let histogram: RGBHistogram?   // SDR frames only; HDR has its own analysis
        let ms: Int
        /// SDR: BGRA8 sRGB. HDR: RGBA float32, linear, on the EDR scale.
        let pixels: Data
        let width: Int, height: Int
        /// the full-size output, which crop and rotation change
        var processedSize: CGSize = .zero
        /// the size reaching rotate and perspective, for its crop margins
        var rotateInSize: CGSize?
    }

    /// Renders to fit within `maxPixels` on the long edge.
    /// `before` renders the photo as it was when opened, for comparison.
    /// A region of the image at a given scale (1 = full resolution), in pixels
    /// of the scaled image: what the zoomed canvas shows.
    struct Crop: Sendable, Equatable {
        var scale: Double
        var x: Int, y: Int, w: Int, h: Int
    }

    /// A setting changed for one render only, e.g. an SDR target white.
    struct Override: Sendable {
        let module: String, field: String, value: Double
        var enable = false
        var disable = false
    }

    func render(maxPixels: Int, hdr: Bool, displayHeadroom: Double, wantOverlay: Bool,
                before: Bool = false, crop: Crop? = nil, overrides: [Override] = [],
                hdrLimit: Double? = nil, keepForRefresh: Bool = false) async throws -> Frame {
        // an HDR source's SDR render is its HDR render, tone mapped (see sdrFromHDR)
        let toneMapped = !hdr && sdrFromHDR
        var body: [String: Any] = ["cmd": "render", "max": maxPixels, "hdr": hdr || toneMapped, "before": before]
        if !overrides.isEmpty {
            body["overrides"] = overrides.map {
                ["module": $0.module, "field": $0.field, "value": $0.value, "enable": $0.enable, "disable": $0.disable] as [String: Any]
            }
        }
        if let crop {
            body.merge(["scale": crop.scale, "x": crop.x, "y": crop.y, "w": crop.w, "h": crop.h]) { $1 }
        }
        let reply = try await request(body, as: RenderReply.self)
        if UserDefaults.standard.bool(forKey: "LogRenderTimes") {
            FileHandle.standardError.write("Darkslide render hdr \(hdr) toneMapped \(toneMapped) profile \(reply.outputProfile)\n".data(using: .utf8)!)
        }
        var frame = toneMapped
            ? try toneMappedFrame(try self.frame(from: reply, hdr: true, keepForRefresh: false, displayHeadroom: 16,
                                                 wantOverlay: false, hdrLimit: nil))
            : try self.frame(from: reply, hdr: hdr, keepForRefresh: keepForRefresh,
                             displayHeadroom: displayHeadroom, wantOverlay: wantOverlay, hdrLimit: hdrLimit)
        frame.processedSize = CGSize(width: reply.processedWidth, height: reply.processedHeight)
        if let w = reply.rotateInWidth, let h = reply.rotateInHeight { frame.rotateInSize = CGSize(width: w, height: h) }
        return frame
    }

    private func frame(from reply: RenderReply, hdr: Bool, keepForRefresh: Bool,
                       displayHeadroom: Double, wantOverlay: Bool, hdrLimit: Double?) throws -> Frame {
        let (w, h) = (reply.width, reply.height)
        // map rather than read: the HDR pass reads it once, straight from the page cache
        let mapped = try Data(contentsOf: frameURL, options: .alwaysMapped)
        let bytes = w * h * (hdr ? 16 : 4)
        guard mapped.count >= bytes else { throw EngineError(message: "Could not read the rendered frame.") }
        guard hdr else {
            // copied, because the helper overwrites the frame file on the next render
            let pixels = Data(mapped.prefix(bytes))
            return Frame(image: try makeImage(pixels, width: w, height: h, space: CGColorSpace.sRGB, hdr: false),
                         isHDR: false, analysis: nil, overlay: nil,
                         histogram: RGBHistogram(bgra: pixels, width: w, height: h), ms: reply.ms,
                         pixels: pixels, width: w, height: h)
        }
        let target = HDRTarget(darktableProfile: reply.outputProfile)
        if keepForRefresh {
            // the photo as the main view shows it, kept so the peak limit and
            // headroom preview can change without a render
            lastHDRSource = HDRSource(data: Data(mapped.prefix(bytes)), width: w, height: h, target: target)
            lastSDRBase = nil
        }
        let (pixels, analysis, overlay) = mapped.withUnsafeBytes { src in
            HDRAnalysis.process(source: UnsafeRawBufferPointer(rebasing: src[0..<bytes]), width: w, height: h,
                                target: target, displayHeadroom: displayHeadroom, wantOverlay: wantOverlay,
                                limit: hdrLimit)
        }
        let space = target.primaries == .p3 ? CGColorSpace.extendedLinearDisplayP3
                                            : CGColorSpace.extendedLinearITUR_2020
        // tag the image with its headroom: without it macOS 26 shows it as SDR
        let headroom = Float(max(analysis.peak, 1))
        return Frame(image: try makeImage(pixels, width: w, height: h, space: space, hdr: true, headroom: headroom),
                     isHDR: true, analysis: analysis, overlay: overlay, histogram: nil, ms: reply.ms,
                     pixels: pixels, width: w, height: h)
    }

    /// Set while the open photo came from an HDR source (a gain map, HLG or
    /// PQ image, or Apple's rendering of a raw): it is already rendered, with
    /// highlights above SDR white and no tone mapper to bring them down, so an
    /// SDR render would clip them. SDR renders are then the HDR render tone
    /// mapped to SDR by Core Image, as macOS makes the SDR version of an HDR photo.
    private var sdrFromHDR = false

    /// An HDR frame tone mapped to SDR white, as an SDR frame (BGRA8 sRGB).
    private func toneMappedFrame(_ hdr: Frame) throws -> Frame {
        let (w, h) = (hdr.width, hdr.height)
        var rolled = hdr.pixels
        rolled.withUnsafeMutableBytes { GainMapPreview.rollOffToSDR($0.bindMemory(to: Float.self)) }
        guard let space = hdr.image.colorSpace else { throw EngineError(message: "Couldn't tone map the HDR render.") }
        let out = CIImage(bitmapData: rolled, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: space)
        var pixels = Data(count: w * h * 4)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        pixels.withUnsafeMutableBytes { buf in
            Self.toneMapContext.render(out, toBitmap: buf.baseAddress!, rowBytes: w * 4,
                                       bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .BGRA8, colorSpace: srgb)
        }
        return Frame(image: try makeImage(pixels, width: w, height: h, space: CGColorSpace.sRGB, hdr: false),
                     isHDR: false, analysis: nil, overlay: nil,
                     histogram: RGBHistogram(bgra: pixels, width: w, height: h), ms: hdr.ms,
                     pixels: pixels, width: w, height: h)
    }

    private static let toneMapContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!])

    /// The edit's position in darktable's history after the last reply; the
    /// undo stack records it.
    private(set) var historyEnd = 0

    /// The last HDR render's pipe output, before the app's HDR pass.
    private struct HDRSource { let data: Data; let width: Int, height: Int; let target: HDRTarget }
    private var lastHDRSource: HDRSource?
    /// the SDR base rendered for the last HDR frame's headroom preview
    private var lastSDRBase: Frame?

    /// Redoes the app's HDR pass on the last HDR render with a new limit or
    /// preview headroom: no engine round trip, so these controls can follow a
    /// slider. Nil when there's nothing to reuse and a render is needed.
    func reprocessLastHDR(displayHeadroom: Double, wantOverlay: Bool, limit: Double?,
                          previewStops: Double?, darktableBase: Bool) throws -> Frame? {
        guard let src = lastHDRSource else { return nil }
        if previewStops != nil, darktableBase, lastSDRBase == nil { return nil }
        let (pixels, analysis, overlay) = src.data.withUnsafeBytes { raw in
            HDRAnalysis.process(source: raw, width: src.width, height: src.height, target: src.target,
                                displayHeadroom: displayHeadroom, wantOverlay: wantOverlay, limit: limit)
        }
        let space = src.target.primaries == .p3 ? CGColorSpace.extendedLinearDisplayP3
                                                : CGColorSpace.extendedLinearITUR_2020
        var frame = Frame(image: try makeImage(pixels, width: src.width, height: src.height, space: space, hdr: true,
                                               headroom: Float(max(analysis.peak, 1))),
                          isHDR: true, analysis: analysis, overlay: overlay, histogram: nil, ms: 0,
                          pixels: pixels, width: src.width, height: src.height)
        if let stops = previewStops {
            frame = Frame(image: try gainMapPreview(hdr: frame, sdr: darktableBase ? lastSDRBase : nil, stops: stops),
                          isHDR: true, analysis: analysis, overlay: nil, histogram: nil, ms: 0,
                          pixels: frame.pixels, width: src.width, height: src.height)
        }
        return frame
    }

    /// What a gain map viewer shows on a display with `stops` of headroom:
    /// the SDR base and the HDR rendition blended per pixel in log space, by
    /// the ISO 21496-1 weight (display headroom over the HDR headroom, in
    /// stops). `sdr` is the SDR base frame, nil for the automatic base.
    func gainMapPreview(hdr: Frame, sdr: Frame?, stops: Double) throws -> CGImage {
        if let sdr { lastSDRBase = sdr }
        guard let analysis = hdr.analysis else { return hdr.image }
        let hdrStops = log2(max(analysis.peak, 1))
        let weight = hdrStops > 0 ? Float(min(max(stops / hdrStops, 0), 1)) : 1
        let primaries = analysis.target.primaries
        let space = primaries == .p3 ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.extendedLinearITUR_2020
        guard weight < 1 else { return hdr.image }
        let base = try sdr.map { try GainMapPreview.linearize(sdr: $0, primaries: primaries) }
            ?? GainMapPreview.toneMapped(hdr: hdr.image, peak: analysis.peak, space: space)
        let pixels = GainMapPreview.blend(sdr: base, hdr: hdr.pixels, weight: weight)
        return try makeImage(pixels, width: hdr.width, height: hdr.height, space: space, hdr: true,
                             headroom: Float(max(pow(2, Double(weight) * hdrStops), 1)))
    }

    // MARK: Plumbing

    private func request<T: Decodable>(_ body: [String: Any], as type: T.Type) async throws -> T {
        let data = try await request(body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func request(_ body: [String: Any]) async throws -> Data {
        if exited { throw EngineError(message: "The engine has stopped.") }
        let data = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            pending.append(c)
            do { try send(raw: body) } catch {
                pending.removeLast()
                c.resume(throwing: error)
            }
        }
        if let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if status["ok"] as? Bool == false {
                throw EngineError(message: status["error"] as? String ?? "Unknown engine error")
            }
            if let end = status["historyEnd"] as? Int { historyEnd = end }
        }
        return data
    }

    private func send(raw body: [String: Any]) throws {
        var line = try JSONSerialization.data(withJSONObject: body)
        line.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: line)
    }

    private func deliver(_ line: Data) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: line)
    }

    private func handleExit(_ status: Int32) {
        exited = true
        let waiting = pending
        pending.removeAll()
        waiting.forEach { $0.resume(throwing: EngineError(message: "The engine stopped (status \(status)).")) }
        onExit(status)
    }

    private func makeImage(_ data: Data, width: Int, height: Int, space name: CFString, hdr: Bool,
                           headroom: Float = 0) throws -> CGImage {
        // SDR: darktable's backbuf is BGRA8 sRGB (little-endian, alpha byte unused).
        // HDR: RGBA float32, linear, on the EDR scale (see HDRAnalysis); values
        // above 1.0 are shown as highlights on displays with headroom.
        let space = CGColorSpace(name: name)!
        let info: UInt32 = hdr
            ? CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              | CGImageAlphaInfo.noneSkipLast.rawValue
            : CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        let bpp = hdr ? 128 : 32
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw EngineError(message: "Could not build an image from the rendered frame.")
        }
        let image: CGImage?
        if hdr, headroom >= 1, #available(macOS 15.0, *) {
            image = CGImage(headroom: headroom, width: width, height: height,
                            bitsPerComponent: 32, bitsPerPixel: bpp, bytesPerRow: width * bpp / 8,
                            space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        } else {
            image = CGImage(width: width, height: height,
                            bitsPerComponent: hdr ? 32 : 8, bitsPerPixel: bpp, bytesPerRow: width * bpp / 8,
                            space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        guard let image else { throw EngineError(message: "Could not build an image from the rendered frame.") }
        return image
    }
}
