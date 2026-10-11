import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import Vision
import ImageIO
import UniformTypeIdentifiers
import CoreLocation

@MainActor
@Observable
final class EditorModel {
    enum Filter: String, CaseIterable, Identifiable {
        case essentials = "Essentials"
        case active = "Active"
        case all = "All"
        var id: String { rawValue }
    }

    // Document
    private(set) var url: URL?
    private(set) var camera = ""
    private(set) var sensor = "bayer"
    private(set) var image: CGImage?

    // Before and after: the photo as opened on the left of a movable divider
    // StartComparing: launch argument (-StartComparing YES) for testing
    var comparing = UserDefaults.standard.bool(forKey: "StartComparing") { didSet { if comparing != oldValue, comparing, url != nil { requestRender() } } }
    var compareSplit: Double = 0.5
    private(set) var beforeImage: CGImage?
    private var beforeKey = ""   // size and mode the before image was rendered for
    private(set) var imageIsHDR = false
    private(set) var imageIsZoomed = false   // the image is a crop at the zoom scale
    private(set) var frameID = 0               // counts frames shown, so views can wait for the next one
    /// the crop the current zoomed frame shows
    private(set) var shownCrop: Engine.Crop?
    /// canvas size in screen pixels
    var canvasPixelSize: CGSize { canvasSizePx }
    private(set) var hdrAnalysis: HDRAnalysis?
    private(set) var rgbHistogram: RGBHistogram?
    private(set) var headroomOverlay: CGImage?
    private(set) var modules: [EngineModule] = []
    private(set) var hasUnsavedChanges = false

    private static var testLibraryRan = false
    private static var decoderSwitchTested = false

    /// when darktable couldn't decode the raw: the TIFF macOS decoded it to,
    /// which darktable is editing (see AppleRawFallback)
    private(set) var decodedTIFF: URL?
    /// the photo held HDR (a gain map, HLG or PQ) and was opened with it
    private(set) var openedAsHDR = false
    /// the photo opened with an edit in its sidecar, not yet reset
    private var openedWithEdit = false
    /// Reset is for photos with something to reset: an edit from the sidecar,
    /// or edits since opening (the new-photo defaults don't count)
    var canReset: Bool { url != nil && (openedWithEdit || !undoStack.isEmpty) }
    fileprivate var reopening = false

    /// opens the same photo again, as when its decoder changes
    func reopen() async {
        guard let photo = url else { return }
        reopening = true
        defer { reopening = false }
        await open(photo)
    }

    /// the lens as the photo's EXIF records it, for the lens correction card
    struct LensInfo: Sendable { var model: String?; var focal: Double?; var maxAperture: Double? }
    private(set) var lensInfo = LensInfo()

    /// which raw decoder read the open photo: "darktable" or "Apple RAW 9" etc.
    private(set) var decoderInUse: String?
    /// Apple raw engine versions offered for the open raw, newest first
    private(set) var appleDecoderVersions: [String] = []
    private(set) var canDecodeWithApple = false
    /// a passing note for the window's subtitle
    var statusNote: String?

    // Library (see the Library extension at the end)
    let library = Library(catalog: Catalog())
    var catalog: Catalog { library.catalog }
    /// the grid of the folder's photos, instead of the photo being edited
    var showingLibrary = false
    /// the latest whole-photo frame, which becomes the photo's thumbnail
    fileprivate var thumbnailFrame: CGImage?
    fileprivate var editedSinceOpen = false

    /// bumped when a photo's title or rating changes, so the Info window rereads it
    var infoRevision = 0

    // Curves (see the Curves extension at the end)
    /// the rgb curve whose editor is showing, so renders collect its histogram
    var curveEditorModule: String? {
        didSet { if curveEditorModule != oldValue, curveEditorModule != nil, url != nil { requestRender() } }
    }
    private(set) var curveInfo: Engine.CurveReply?
    /// the last whole-photo frame, drawn soft under a zoomed crop so panning
    /// shows the photo at once where the sharp render hasn't reached
    private(set) var panBackdrop: (image: CGImage, isHDR: Bool)?
    /// the local adjustment being edited, whose shape shows on the photo
    var selectedLocal: String? {
        didSet { if selectedLocal != oldValue { localShape = nil; if selectedLocal != nil { Task { await fetchLocalShape() } } } }
    }
    /// its shape in output pixels, as the engine has it
    var localShape: LocalShape?
    /// Vision is looking for the subject
    var isFindingSubject = false
    var pendingShape: ShapeEdit?
    var sendingShape = false
    /// the folder of film-look LUTs (Settings, or the Look card) and what's in it
    var lutFolder: URL? = UserDefaults.standard.url(forKey: "LUTFolder") {
        didSet {
            UserDefaults.standard.set(lutFolder, forKey: "LUTFolder")
            filmLooks = lutFolder.map(FilmLook.scan) ?? []
            Task { await loadLook() }
        }
    }
    var filmLooks: [FilmLook] = [] {
        didSet { films = Film.gather(filmLooks) }
    }
    var films: [Film] = []
    /// starred films, by Film.id
    var favouriteLooks = Set(UserDefaults.standard.stringArray(forKey: "FavouriteLooks") ?? []) {
        didSet { UserDefaults.standard.set(Array(favouriteLooks).sorted(), forKey: "FavouriteLooks") }
    }
    var lookBrowserOpen = false
    /// a small render of the photo without its film look, for the look previews
    var lookPreviewBase: CGImage?
    var lookPreviewBaseID = 0
    /// the open photo's film look (a path in the folder) and its strength, 0 to 100
    var currentLook: String?
    var lookStrength = 100.0
    var pendingLookStrength: Double?
    var sendingLook = false
    /// Photos' albums for the sidebar, once Photos is allowed
    var photosAlbums: [PhotosLibrary.Album] = []
    /// darktable's presets for the open photo's modules
    var presetList: [Engine.PresetInfo] = []
    /// adjustments copied for pasting onto other photos
    var copiedAdjustments: CopiedAdjustments?
    var choosingAdjustmentsToCopy = false
    /// the Photos asset open, when the photo came from Photos (its original
    /// is edited from a cache file)
    private(set) var photosAsset: String?
    fileprivate var openingPhotosAsset: String?
    var isSavingToPhotos = false
    /// the open photo as the library knows it: its Photos address, or its file
    var libraryURL: URL? { photosAsset.map(PhotosLibrary.url(for:)) ?? url }
    /// the RGB curve card's tab: 0 RGB, 1 red, 2 green, 3 blue
    var curveChannel = 0
    /// the module curveInfo describes
    private(set) var curveInfoKey: String?
    /// the latest curve edit, sent before the next render
    private var pendingCurve: (module: String, channel: Int, nodes: [CGPoint], linked: Bool)?

    // Crop and straighten (see the Crop extension at the end)
    private(set) var isCropping = false
    /// the crop being edited, 0...1 in the straightened photo
    var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var cropAspect: CropAspect = .free { didSet { if cropAspect != oldValue { fitCropToAspect() } } }
    var cropPortrait = false { didSet { if cropPortrait != oldValue { fitCropToAspect() } } }
    /// the size reaching rotate and perspective
    private var rotateInSize: CGSize?
    /// the straighten angle the frame on screen was rendered with; the canvas
    /// turns that frame by the difference until the new render arrives
    private(set) var frameStraighten = 0.0
    /// straighten and crop as they were when cropping began, for Cancel
    private var cropStart: (rotation: Double, rect: CGRect, cropEnabled: Bool)?

    // Undo (see the Undo extension at the end)
    private(set) var undoStack: [UndoStep] = []
    private(set) var redoStack: [UndoStep] = []
    /// while above zero, edits join the step already recorded (Auto, opening a photo)
    private var undoGroupDepth = 0
    private var restoringUndo = false
    private var lastGesture: (key: String, time: ContinuousClock.Instant)?
    private var nextUndoID = 0

    // Styles
    private(set) var styles: [StyleInfo] = []
    private(set) var suggestedStyle: StyleInfo?
    /// shown as a banner for unedited photos when the mode is "suggest"
    var offerSuggestedStyle = false
    private(set) var appliedStyles: [String] = []
    /// history length before each applied style, for undo
    private var styleHistoryEnds: [Int] = []
    /// edits since the last style; undo is only offered while this is zero
    private(set) var editsSinceStyle = 0
    private var creatingChannelCurve = false
    private var stashedChannelCurve: (Int, [CGPoint])?
    /// the exposure Auto sets for the open photo (darktable's automatic rule)
    private(set) var autoExposure: Double?

    // Settings
    var toneMapper = ToneMapper(rawValue: UserDefaults.standard.string(forKey: SettingsKey.toneMapper) ?? "")
        ?? .filmic {
        didSet {
            guard toneMapper != oldValue else { return }
            UserDefaults.standard.set(toneMapper.rawValue, forKey: SettingsKey.toneMapper)
            Task { await restartEngineForSettings() }
        }
    }
    /// The Essentials tab: the user's own modules, in their order.
    var essentials = EditorModel.loadEssentials() {
        didSet { UserDefaults.standard.set(essentials, forKey: SettingsKey.essentials) }
    }

    /// Lists saved before Scene white existed get White balance swapped for it,
    /// and lists saved before the recommended order get put in that order
    /// (anything the user added stays, after the standard modules). Once each.
    private static func loadEssentials() -> [String] {
        let d = UserDefaults.standard
        guard var list = d.stringArray(forKey: SettingsKey.essentials) else { return Presentation.defaultEssentials }
        if !d.bool(forKey: "EssentialsRecommendedOrder") {
            d.set(true, forKey: "EssentialsRecommendedOrder")
            let rank = Dictionary(uniqueKeysWithValues: Presentation.defaultEssentials.enumerated().map { ($1, $0) })
            list = list.enumerated().sorted { a, b in
                (rank[a.element] ?? 1000 + a.offset, a.offset) < (rank[b.element] ?? 1000 + b.offset, b.offset)
            }.map(\.element)
            if !list.contains("agx"), let i = list.firstIndex(of: "sigmoid") { list.insert("agx", at: i + 1) }
            d.set(list, forKey: SettingsKey.essentials)
        }
        if !d.bool(forKey: "EssentialsCurveAdded") {
            d.set(true, forKey: "EssentialsCurveAdded")
            if !list.contains("rgbcurve") {
                let at = list.firstIndex(of: "colorbalancergb").map { $0 + 1 } ?? list.count
                list.insert("rgbcurve", at: at)
                d.set(list, forKey: SettingsKey.essentials)
            }
        }
        if !d.bool(forKey: "EssentialsSceneWhiteMigrated") {
            d.set(true, forKey: "EssentialsSceneWhiteMigrated")
            if let i = list.firstIndex(of: "temperature"), !list.contains("channelmixerrgb") {
                list[i] = "channelmixerrgb"
                d.set(list, forKey: SettingsKey.essentials)
            }
        }
        return list
    }
    /// on unless switched off: darktable leaves lens correction off by default
    var lensCorrectionForNewPhotos = UserDefaults.standard.object(forKey: SettingsKey.lensCorrection) as? Bool ?? true {
        didSet { UserDefaults.standard.set(lensCorrectionForNewPhotos, forKey: SettingsKey.lensCorrection) }
    }
    var autoExposureForNewPhotos = UserDefaults.standard.bool(forKey: SettingsKey.autoExposure) {
        didSet { UserDefaults.standard.set(autoExposureForNewPhotos, forKey: SettingsKey.autoExposure) }
    }
    var gpuBackend = GPUBackend(rawValue: UserDefaults.standard.string(forKey: SettingsKey.gpuBackend) ?? "") ?? .metal {
        didSet {
            guard gpuBackend != oldValue else { return }
            UserDefaults.standard.set(gpuBackend.rawValue, forKey: SettingsKey.gpuBackend)
            Task { await restartEngineForSettings() }
        }
    }
    var canvasBackground = CanvasBackground(rawValue: UserDefaults.standard.string(forKey: SettingsKey.canvasBackground) ?? "")
        ?? .dark {
        didSet { UserDefaults.standard.set(canvasBackground.rawValue, forKey: SettingsKey.canvasBackground) }
    }
    var cameraStyleMode = CameraStyleMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.cameraStyleMode) ?? "")
        ?? .suggest {
        didSet { UserDefaults.standard.set(cameraStyleMode.rawValue, forKey: SettingsKey.cameraStyleMode) }
    }

    // Status
    private(set) var engineReady = false
    private(set) var isOpening = false
    /// time from request to frame on screen, including the app's HDR pass
    private(set) var lastRenderMs: Int?
    private(set) var lastRenderWasDraft = false
    var errorMessage: String?

    // HDR viewing
    // StartInHDR: launch argument (-StartInHDR YES) for testing
    var viewHDR = UserDefaults.standard.bool(forKey: "StartInHDR") {
        didSet {
            guard viewHDR != oldValue else { return }
            watchHeadroom()
            if viewHDR { useHDRProfileIfSDR() }
            if url != nil { requestRender() }
        }
    }
    var showHeadroomOverlay = false { didSet { if showHeadroomOverlay != oldValue, viewHDR, url != nil { requestRender() } } }

    /// Caps how far above reference white the HDR rendition goes, in stops
    /// (0 = no limit). Applied to the HDR view and the gain map export alike;
    /// darktable writes HEIF and JPEG XL itself, so those aren't capped.
    var hdrLimitStops = UserDefaults.standard.double(forKey: SettingsKey.hdrLimitStops) {
        didSet {
            guard hdrLimitStops != oldValue else { return }
            UserDefaults.standard.set(hdrLimitStops, forKey: SettingsKey.hdrLimitStops)
            refreshHDRDisplay()
        }
    }
    var hdrLimit: Double? { hdrLimitStops > 0 ? pow(2, hdrLimitStops) : nil }

    /// Shows the HDR view as a gain map viewer would on a display with this
    /// many stops of headroom; nil shows this display's full range.
    /// Adjustments to the SDR rendition only; see SDRVersion.
    var sdrVersion = SDRVersion() {
        didSet {
            guard sdrVersion != oldValue, let url else { return }
            recordUndoStep(label: "SDR Version", gesture: "sdr", sdrBefore: oldValue)
            sdrVersion.save(for: url)
            if showsSDRVersion { requestRender() }
        }
    }
    /// The SDR view of an HDR edit shows its SDR rendition, as a gain map
    /// JPEG's base and displays without HDR would.
    var showsSDRVersion: Bool { !viewHDR && exportTarget.isHDR }

    /// StartPreviewHeadroom: launch argument (-StartPreviewHeadroom 2) for testing
    var previewHeadroomStops: Double? = UserDefaults.standard.object(forKey: "StartPreviewHeadroom").flatMap { Double("\($0)") } {
        didSet { if previewHeadroomStops != oldValue { refreshHDRDisplay() } }
    }

    private var hdrRefreshing = false
    private var hdrRefreshAgain = false

    /// After a change to the peak limit, preview headroom or display headroom:
    /// redoes only the app's HDR pass on the last frame, coalescing changes
    /// that arrive while one is running. Falls back to a render when the frame
    /// can't be reused (an edit is pending, or the view is zoomed, where the
    /// histogram needs the whole photo).
    private func refreshHDRDisplay() {
        guard viewHDR, url != nil, let engine else { return }
        guard !pumping, !renderRequested, pendingSets.isEmpty, shownCrop == nil else {
            if shownCrop != nil { hdrAnalysis = nil }   // so the zoomed render redoes the whole-photo one
            requestRender()
            return
        }
        if hdrRefreshing { hdrRefreshAgain = true; return }
        hdrRefreshing = true
        Task {
            defer { hdrRefreshing = false }
            repeat {
                hdrRefreshAgain = false
                let stops = previewHeadroomStops
                let start = ContinuousClock.now
                defer {
                    if UserDefaults.standard.bool(forKey: "LogRenderTimes") {
                        FileHandle.standardError.write("Develop HDR refresh \(ContinuousClock.now - start), limit \(hdrLimitStops), preview \(stops.map { "\($0)" } ?? "off"), peak \(hdrAnalysis?.peak ?? 0)\n".data(using: .utf8)!)
                    }
                }
                let frame = try? await engine.reprocessLastHDR(
                    displayHeadroom: displayHeadroom, wantOverlay: showHeadroomOverlay && stops == nil,
                    limit: hdrLimit, previewStops: stops, darktableBase: ExportSettings.load().sdrBase == .darktable)
                guard let frame, viewHDR, !pumping else { requestRender(); return }
                image = frame.image
                hdrAnalysis = frame.analysis
                headroomOverlay = frame.overlay
                isSimulatingHeadroom = stops != nil
                frameID += 1
            } while hdrRefreshAgain
        }
    }
    /// the preview is simulating a dimmer display
    private(set) var isSimulatingHeadroom = false

    /// Brightest value the display can show right now, × its SDR white. It
    /// drops as screen brightness goes up, so it's polled while viewing HDR
    /// (EDRImageView's probe layer makes macOS report the true figure).
    private(set) var displayHeadroom = Double(NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1)
    private var headroomWatch: Task<Void, Never>?

    private func watchHeadroom() {
        headroomWatch?.cancel()
        guard viewHDR else { return }
        headroomWatch = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let now = Double(NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
                // ignore tiny drift; re-analyse when it moves by more than ~1/20 stop
                if abs(log2(max(now, 1)) - log2(max(displayHeadroom, 1))) > 0.05 {
                    displayHeadroom = now
                    refreshHDRDisplay()   // only the app's HDR pass reruns
                }
            }
        }
    }

    // Inspector state
    var filter: Filter = .essentials
    // StartSearch: launch argument (-StartSearch text) for testing
    var search = UserDefaults.standard.string(forKey: "StartSearch") ?? ""
    // StartExpanded: launch argument (-StartExpanded lens:0,rgbcurve:0) for testing
    var expanded: Set<String> = UserDefaults.standard.string(forKey: "StartExpanded").map { Set($0.split(separator: ",").map(String.init)) }
        ?? ["exposure:0", "channelmixerrgb:0", "toneequal:0", "colorbalancergb:0", "filmicrgb:0", "sigmoid:0"]

    private var engine: Engine?
    /// for read-only lookups from pickers (Lensfun's lists), which change nothing
    var engineForPickers: Engine? { engine }
    private var canvasPixels = 1600
    private var canvasSizePx = CGSize(width: 1600, height: 1000)

    // Zoom: fit the whole photo, or a crop at a scale where 1 = one image pixel
    // per screen pixel. darktable runs its full-quality demosaic at 100%.
    enum Zoom: Equatable { case fit, scale(Double) }
    var zoom: Zoom = .fit {
        didSet { if zoom != oldValue, url != nil { requestRender() } }
    }
    /// the point of the photo at the centre of the view while zoomed, 0...1
    var zoomCenter = CGPoint(x: 0.5, y: 0.5) {
        didSet { if case .scale = zoom, zoomCenter != oldValue { requestRender() } }
    }
    /// full size of the processed photo, in pixels
    private(set) var imageSize = CGSize(width: 1, height: 1)

    static let zoomSteps: [Double] = [0.25, 0.5, 1, 2, 4]

    func zoomIn() {
        let s = { if case .scale(let s) = zoom { return s } else { return fitScale } }()
        zoom = .scale(Self.zoomSteps.first { $0 > s + 0.001 } ?? 4)
    }

    func zoomOut() {
        guard case .scale(let s) = zoom else { return }
        let next = Self.zoomSteps.last { $0 < s - 0.001 }
        zoom = next.map { $0 > fitScale ? .scale($0) : .fit } ?? .fit
    }

    /// the scale at which the whole photo fits, for zoom steps
    var fitScale: Double {
        min(canvasSizePx.width / imageSize.width, canvasSizePx.height / imageSize.height)
    }

    /// the crop the canvas needs at the current zoom, clamped to the photo
    var currentCrop: Engine.Crop? {
        guard case .scale(let s) = zoom else { return nil }
        let iw = imageSize.width * s, ih = imageSize.height * s
        let w = min(Int(canvasSizePx.width), Int(iw)), h = min(Int(canvasSizePx.height), Int(ih))
        let x = Int(zoomCenter.x * iw) - w / 2, y = Int(zoomCenter.y * ih) - h / 2
        return Engine.Crop(scale: s, x: max(0, min(x, Int(iw) - w)), y: max(0, min(y, Int(ih) - h)), w: w, h: h)
    }

    /// pan by a distance in screen pixels
    func pan(byPixels d: CGSize) {
        guard case .scale(let s) = zoom else { return }
        let nx = zoomCenter.x - d.width / (imageSize.width * s)
        let ny = zoomCenter.y - d.height / (imageSize.height * s)
        zoomCenter = CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
    }
    private var openWhenReady: URL?
    private var restarting = false
    private var restartPending = false

    // Edits are coalesced: a slider can fire far faster than the engine
    // renders, so only the latest value per field is sent, then one render.
    private var pendingSets: [(module: String, field: String, value: FieldValue)] = []
    /// Undo steps waiting for their history position: each is resolved once
    /// the sets queued before it (`position` of them) have reached the engine.
    private var pendingCheckpoints: [(position: Int, id: Int)] = []
    private var renderRequested = false
    private var pumping = false
    private var settleTask: Task<Void, Never>?
    /// recent full-resolution render times, to decide whether drafts are needed
    private var fullRenderMs: Double = 0
    private var framesSinceOpen = 0

    // MARK: Engine lifecycle

    // only the current engine's exit counts; starts never overlap
    private var engineGeneration = 0
    private var startingEngine = false
    private var failedStarts = 0

    func startEngine() async {
        // the window's start-up task can run again (opening a file can bring
        // it back), and a second helper would fail on darktable's database lock
        guard !startingEngine, engine == nil else { return }
        startingEngine = true
        defer { startingEngine = false }
        engineGeneration += 1
        let generation = engineGeneration
        do {
            let engine = try Engine(workflow: toneMapper.workflow, backend: gpuBackend) { [weak self] status in
                Task { @MainActor in self?.engineDidExit(status, generation: generation) }
            }
            try await engine.start()
            self.engine = engine
            engineReady = true
            failedStarts = 0
            watchHeadroom()
            styles = (try? await engine.styles())?.map(StyleInfo.init(name:)) ?? []
            if let url = openWhenReady {
                openWhenReady = nil
                await open(url)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopEngine() async {
        await engine?.stop()
    }

    /// darktable reads the default tone mapper at startup, so a change needs a
    /// fresh engine. Unsaved edits are never discarded: with edits pending,
    /// the restart waits until the next photo is opened.
    private func restartEngineForSettings() async {
        guard !hasUnsavedChanges else { restartPending = true; return }
        await restartEngine()
        if let url { await open(url) }
    }

    private func restartEngine() async {
        restarting = true
        engineReady = false
        await engine?.stop()
        engine = nil
        restarting = false
        restartPending = false
        await startEngine()
    }

    /// Restarts a crashed engine, backing off (1, 2, 4, 8 s) and giving up
    /// after five failures in a row, rather than looping. Exits of engines that
    /// were already replaced are ignored.
    private func engineDidExit(_ status: Int32, generation: Int) {
        guard !restarting, generation == engineGeneration else { return }
        engineReady = false
        engine = nil
        failedStarts += 1
        guard failedStarts <= 5 else {
            errorMessage = "The darktable engine keeps stopping (status \(status)). Another copy of Develop may still be running; quit it and reopen Develop."
            return
        }
        if failedStarts == 1 {
            errorMessage = "The darktable engine stopped unexpectedly (status \(status)). Restarting it."
        }
        let delay = min(1 << (failedStarts - 1), 8)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await startEngine()
            if engineReady, let url { await open(url) }
        }
    }

    // MARK: Document

    /// darktable hides deprecated modules unless the photo uses one, and
    /// modules that can't work on this image (raw-only ones on a non-raw)
    private var usableModules: [EngineModule] {
        // the colour curves instance shows through the RGB curve card: the card
        // is on, and in Active, when either curve is
        let channels = channelCurveModule
        return modules.filter { ($0.applicable ?? true) && (!($0.deprecated ?? false) || $0.enabled || $0.inHistory)
            && !Self.isChannelCurve($0) && !Self.isLocal($0)
            && $0.instanceName != Self.deletedLocalName && $0.instanceName != Self.deletedInstanceName
            && $0.instanceName != Self.hdrWhiteName }
            .map { m in
                guard let channels, m.op == "rgbcurve" else { return m }
                var shown = m
                shown.enabled = m.enabled || channels.enabled
                return shown
            }
    }

    var visibleModules: [EngineModule] {
        let base: [EngineModule] = switch filter {
        case .active: usableModules.filter { $0.enabled || $0.inHistory }
        case .essentials:
            // only the tone mapper in use, when one is
            essentials.compactMap { op in usableModules.first { $0.op == op } }
                .filter { m in
                    !Presentation.toneMappers.contains(m.op) || m.enabled
                        || !modules.contains { Presentation.toneMappers.contains($0.op) && $0.enabled }
                }
        case .all: usableModules
        }
        guard !search.isEmpty else { return base }
        // search covers every module, whichever tab is showing
        return usableModules.filter { Presentation.matches($0, search: search) }
    }

    func open(_ url: URL) async {
        if restartPending { await restartEngine() }
        guard let engine else { openWhenReady = url; return }
        // a Photos photo: its original is fetched to a file, which is what's edited
        if let id = PhotosLibrary.assetID(url) {
            if photosAsset == id, self.url != nil { showingLibrary = false; return }
            statusNote = "Getting the original from Photos…"
            let file: URL
            do {
                file = try await PhotosLibrary.original(id)
            } catch {
                statusNote = nil
                errorMessage = "Couldn't get the photo from Photos: \(error.localizedDescription)"
                return
            }
            statusNote = nil
            openingPhotosAsset = id
            defer { openingPhotosAsset = nil }
            await open(file)
            return
        }
        if !reopening, let current = self.url, current.standardizedFileURL == url.standardizedFileURL {
            showingLibrary = false
            return
        }
        await leaveCurrentPhoto()
        isOpening = true
        defer { isOpening = false }
        // stay in the folder or collection being worked through if it has this photo
        // (a Photos original's cache folder is never shown)
        if openingPhotosAsset == nil, !library.contains(url) { library.show(folder: url.deletingLastPathComponent()) }
        showingLibrary = false
        do {
            decodedTIFF = nil
            openedAsHDR = false
            decoderInUse = nil
            let reply: OpenReply
            let isRaw = UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) ?? false
            if !isRaw, await Task.detached(operation: { AppleRawFallback.isHDR(url) }).value {
                // a gain map or HLG/PQ image: darktable would read only the SDR
                // base, so edit macOS's HDR decode of it
                statusNote = "Decoding HDR with macOS…"
                defer { statusNote = nil }
                let tiff = try await Task.detached(priority: .userInitiated) { try AppleRawFallback.decodedHDR(for: url) }.value
                AppleRawFallback.sidecarToDecoded(original: url, decoded: tiff, raw: false)
                reply = try await engine.open(tiff, hdrSource: true)
                decodedTIFF = tiff
                openedAsHDR = true
            } else if !isRaw, AppleRawFallback.needsAppleDecode(url) {
                // a format darktable is built without (HEIC, AVIF, JPEG XL, WebP,
                // OpenEXR): macOS decodes it to a TIFF darktable edits
                statusNote = "Decoding with macOS…"
                defer { statusNote = nil }
                let exr = url.pathExtension.lowercased() == "exr"
                let tiff = try await Task.detached(priority: .userInitiated) {
                    exr ? try AppleRawFallback.decodedHDR(for: url) : try AppleRawFallback.decodedImage(for: url)
                }.value
                AppleRawFallback.sidecarToDecoded(original: url, decoded: tiff, raw: false)
                reply = try await engine.open(tiff, hdrSource: exr)
                decodedTIFF = tiff
                openedAsHDR = exr
            } else if isRaw, case .apple(let version) = RawDecoderChoice.stored(for: url) {
                // chosen in Image › Raw Decoder
                reply = try await openWithApple(url, version: version, engine: engine)
            } else { do {
                reply = try await engine.open(url)
                decoderInUse = isRaw ? "darktable" : nil
            } catch let error as EngineError where error.message.contains("could not decode") && AppleRawFallback.canDecode(url) {
                // darktable can't read this raw, but macOS can: edit Apple's decode of it
                reply = try await openWithApple(url, version: nil, engine: engine)
            } }
            appleDecoderVersions = isRaw ? await Task.detached { AppleRawFallback.decoderVersions(url) }.value : []
            canDecodeWithApple = isRaw && (!appleDecoderVersions.isEmpty || decodedTIFF != nil || AppleRawFallback.canDecode(url))
            undoGroupDepth += 1
            defer { undoGroupDepth -= 1 }
            self.url = url
            clearUndo()
            sdrVersion = SDRVersion.load(for: url)
            camera = reply.camera
            imageSize = CGSize(width: reply.width, height: reply.height)
            zoomCenter = CGPoint(x: 0.5, y: 0.5)
            // StartZoom: launch argument (-StartZoom 1) for testing
            let startZoom = UserDefaults.standard.double(forKey: "StartZoom")
            zoom = startZoom > 0 ? .scale(startZoom) : .fit
            // TestExport: launch arguments (-TestExport /path/file.jpg -TestExportFormat jpegGainMap
            // -TestExportProfile 1) for testing
            if let path = UserDefaults.standard.string(forKey: "TestExport") {
                FileHandle.standardError.write("Develop test export to \(path)\n".data(using: .utf8)!)
                var t = ExportSettings()
                t.format = ExportFormat(rawValue: UserDefaults.standard.string(forKey: "TestExportFormat") ?? "") ?? .jpeg
                t.longEdge = 3000
                if let p = ExportProfile(rawValue: UserDefaults.standard.integer(forKey: "TestExportProfile")) { t.profile = p }
                Task { await export(t, to: URL(fileURLWithPath: path), remember: false) }
            }
            // TestSDREdits: launch argument (-TestSDREdits YES) for testing, steps SDR brightness a few times
            if UserDefaults.standard.bool(forKey: "TestSDREdits") {
                Task { @MainActor in
                    for i in 1...6 {
                        try? await Task.sleep(for: .seconds(2))
                        sdrVersion.brightness = Double(i) / 10
                    }
                }
            }
            // TestHDRControls: launch argument (-TestHDRControls YES) for testing: steps the
            // peak limit and preview headroom, then switches to SDR and back
            if UserDefaults.standard.bool(forKey: "TestHDRControls") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    for l in [2.0, 1.5, 1.0, 0] { hdrLimitStops = l; try? await Task.sleep(for: .milliseconds(400)) }
                    previewHeadroomStops = 0.2
                    try? await Task.sleep(for: .seconds(2))
                    for p in [0.1, 0.05, 0] { previewHeadroomStops = p; try? await Task.sleep(for: .milliseconds(400)) }
                    previewHeadroomStops = nil
                    try? await Task.sleep(for: .seconds(1))
                    viewHDR = false
                    try? await Task.sleep(for: .seconds(2))
                    viewHDR = true
                }
            }
            // TestUndo: launch argument (-TestUndo YES) for testing: a drag, a toggle and
            // another module's edit, then undo three times and redo once, logging each
            if UserDefaults.standard.bool(forKey: "TestUndo") {
                Task { @MainActor in
                    @MainActor func log(_ s: String) {
                        FileHandle.standardError.write("Develop undo test: \(s), steps \(undoStack.map(\.label)), redo \(redoStack.map(\.label))\n".data(using: .utf8)!)
                    }
                    try? await Task.sleep(for: .seconds(4))
                    log("start")
                    guard let exposure = modules.first(where: { $0.op == "exposure" }) else { return }
                    let ev = exposure.fields.first { $0.name == "exposure" }?.value.number ?? 0
                    for i in 1...10 {   // a drag
                        setValue(.number(ev + Double(i) / 10), module: exposure.key, field: "exposure")
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    try? await Task.sleep(for: .seconds(2)); log("after drag")
                    if let lens = modules.first(where: { $0.op == "lens" }) { setEnabled(!lens.enabled, module: lens.key) }
                    try? await Task.sleep(for: .seconds(2)); log("after toggle")
                    if let cb = modules.first(where: { $0.op == "colorbalancergb" }) {
                        setValue(.number(0.5), module: cb.key, field: "saturation_global")
                    }
                    try? await Task.sleep(for: .seconds(2)); log("after saturation")
                    for _ in 0..<3 { await undo(); try? await Task.sleep(for: .seconds(2)); log("after undo") }
                    await redo(); try? await Task.sleep(for: .seconds(2)); log("after redo")
                }
            }
            // TestLibrary: launch argument (-TestLibrary YES) for testing: step past a photo
            // without editing, then edit one and move on, logging which sidecars exist
            if UserDefaults.standard.bool(forKey: "TestLibrary"), !Self.testLibraryRan {
                Self.testLibraryRan = true
                Task { @MainActor in
                    @MainActor func log(_ s: String) {
                        let xmps = library.items.filter { FileManager.default.fileExists(atPath: $0.url.path + ".xmp") }.map(\.name)
                        FileHandle.standardError.write("Develop library test: \(s): at \(self.url?.lastPathComponent ?? "-"), sidecars \(xmps), thumbnails \(library.thumbnails.count)\n".data(using: .utf8)!)
                    }
                    try? await Task.sleep(for: .seconds(3)); log("start")
                    await openNeighbour(1); try? await Task.sleep(for: .seconds(3)); log("after next, no edit")
                    if let e = modules.first(where: { $0.op == "exposure" }) {
                        setValue(.number((e.fields.first { $0.name == "exposure" }?.value.number ?? 0) + 0.5), module: e.key, field: "exposure")
                    }
                    try? await Task.sleep(for: .seconds(2))
                    await openNeighbour(1); try? await Task.sleep(for: .seconds(3)); log("after editing and next")
                }
            }
            // SwitchDecoderToApple: launch argument (-SwitchDecoderToApple YES) for testing, once
            if UserDefaults.standard.bool(forKey: "SwitchDecoderToApple"), !Self.decoderSwitchTested {
                Self.decoderSwitchTested = true
                Task { @MainActor in try? await Task.sleep(for: .seconds(5)); await setRawDecoder(.apple(nil)) }
            }
            // SwitchToHDR: launch argument (-SwitchToHDR YES) for testing, switches to HDR after opening
            if UserDefaults.standard.bool(forKey: "SwitchToHDR") {
                Task { @MainActor in try? await Task.sleep(for: .seconds(5)); viewHDR = true }
            }
            // StartLibrary: launch argument (-StartLibrary YES) for testing, shows the grid;
            // with -StartLibraryAdd YES the folder is added to the library too
            if UserDefaults.standard.bool(forKey: "StartLibrary") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    if UserDefaults.standard.bool(forKey: "StartLibraryAdd") { catalog.addFolders([url.deletingLastPathComponent().deletingLastPathComponent()]) }
                    await showLibrary()
                    // -StartMap YES: the sidebar's Map
                    if UserDefaults.standard.bool(forKey: "StartMap") { showSource(.map) }
                }
            }
            // StartCropping: launch argument (-StartCropping YES, optionally -StartStraighten 3) for testing
            if UserDefaults.standard.bool(forKey: "StartCropping") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    beginCrop()
                    try? await Task.sleep(for: .seconds(1))
                    setStraighten(UserDefaults.standard.double(forKey: "StartStraighten"))
                    if UserDefaults.standard.bool(forKey: "TestStraightenPreview") {
                        try? await Task.sleep(for: .seconds(4))
                        setStraighten(15)
                        FileHandle.standardError.write("Develop straighten preview now\n".data(using: .utf8)!)
                        return
                    }
                    cropAspect = .r3x2
                    cropRect = CGRect(x: 0.1, y: 0.15, width: 0.6, height: 0.6)
                    fitCropToAspect()
                }
            }
            // TestChannelCurve: launch argument (-TestChannelCurve YES) for testing: shows the
            // RGB curve card on its red tab and lifts red, logging the frame's means
            if UserDefaults.standard.bool(forKey: "TestChannelCurve") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    filter = .all
                    search = "rgb curve"
                    curveChannel = 1
                    if let base = modules.first(where: { $0.op == "rgbcurve" && !Self.isChannelCurve($0) }) { expanded.insert(base.key) }
                    try? await Task.sleep(for: .seconds(2))
                    guard let base = modules.first(where: { $0.op == "rgbcurve" && !Self.isChannelCurve($0) }) else { return }
                    setChannelCurve(base: base.key, channel: 0, nodes: [.zero, CGPoint(x: 0.5, y: 0.65), CGPoint(x: 1, y: 1)])
                    try? await Task.sleep(for: .seconds(4))
                    FileHandle.standardError.write("Develop channel test: instances \(modules.filter { $0.op == "rgbcurve" }.map { "\($0.key) '\($0.instanceName)' \($0.enabled)" }), shown \(curveInfoKey ?? "-")\n".data(using: .utf8)!)
                }
            }
            // TestHueCurves: launch argument (-TestHueCurves YES) for testing: shows the hue
            // curves card and lifts blue's saturation and shifts green's hue
            if UserDefaults.standard.bool(forKey: "TestHueCurves") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    filter = .all
                    search = "hue curves"
                    guard let m = modules.first(where: { $0.op == "colorequal" }) else { return }
                    expanded.insert(m.key)
                    setValue(.number(1.6), module: m.key, field: "sat_blue")
                    setValue(.number(30), module: m.key, field: "hue_green")
                }
            }
            // TestPan: launch argument (-TestPan YES) for testing: zooms to 100%, then pans
            // well past the rendered frame and says so, for a capture before the render lands
            if UserDefaults.standard.bool(forKey: "TestPan") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    zoom = .scale(1)
                    try? await Task.sleep(for: .seconds(4))
                    pan(byPixels: CGSize(width: 900, height: 300))
                    FileHandle.standardError.write("Develop pan test: panned\n".data(using: .utf8)!)
                }
            }
            // TestUpright: launch argument (-TestUpright YES) for testing: adds a vertical lens
            // shift, runs Upright, and logs the geometry and the corners of the result
            if UserDefaults.standard.bool(forKey: "TestUpright") {
                Task { @MainActor in
                    @MainActor func corners() -> String {
                        guard let img = image, let data = img.dataProvider?.data as Data? else { return "?" }
                        let (w, h, row) = (img.width, img.height, img.bytesPerRow)
                        return [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)].map { (x, y) in
                            let i = y * row + x * 4
                            return "\(data[i])/\(data[i + 1])/\(data[i + 2])"
                        }.joined(separator: " ")
                    }
                    @MainActor func log(_ s: String) {
                        FileHandle.standardError.write("Develop upright test: \(s): \(perspective), corners \(corners())\n".data(using: .utf8)!)
                    }
                    try? await Task.sleep(for: .seconds(4))
                    setGeometry(.init(rotation: 0, vertical: 0.4))
                    try? await Task.sleep(for: .seconds(3)); log("shifted")
                    await autoUpright()
                    try? await Task.sleep(for: .seconds(3)); log("upright")
                    await autoUpright()
                    try? await Task.sleep(for: .seconds(3)); log("again")
                    await autoStraighten()
                    try? await Task.sleep(for: .seconds(3)); log("level")
                }
            }
            // TestLocal: launch argument (-TestLocal YES) for testing: adds a linear gradient,
            // brightens it, moves it, and logs its shape
            if UserDefaults.standard.bool(forKey: "TestLocal") {
                Task { @MainActor in
                    @MainActor func log(_ s: String) {
                        FileHandle.standardError.write("Develop local test: \(s): selected \(selectedLocal ?? "-"), locals \(localAdjustments.map { "\($0.key) \($0.instanceName) \($0.enabled)" }), shape \(localShape.map { "\($0.kind) \($0.points.prefix(3).map { "(\(Int($0.x)),\(Int($0.y)))" })" } ?? "-")\n".data(using: .utf8)!)
                    }
                    try? await Task.sleep(for: .seconds(4))
                    addLocal(.gradient)
                    try? await Task.sleep(for: .seconds(3)); log("added")
                    if let key = selectedLocal { setValue(.number(1.5), module: key, field: "exposure") }
                    try? await Task.sleep(for: .seconds(3)); log("brightened")
                    if case .gradient = localShape?.kind, let s = localShape {
                        moveShape(.gradient(anchor: CGPoint(x: s.points[0].x, y: s.points[0].y + 600), toward: CGPoint(x: s.points[2].x, y: s.points[2].y + 600), compression: nil))
                    }
                    try? await Task.sleep(for: .seconds(3)); log("moved")
                    let first = selectedLocal
                    addLocal(.ellipse)
                    try? await Task.sleep(for: .seconds(3)); log("radial")
                    if let key = selectedLocal { setValue(.number(-1), module: key, field: "exposure") }
                    if let first { deleteLocal(first) }
                    try? await Task.sleep(for: .seconds(3)); log("deleted first")
                }
            }
            // TestPresets: launch argument (-TestPresets YES) for testing: a new exposure
            // instance, a darktable preset applied to diffuse, then the instance deleted
            if UserDefaults.standard.bool(forKey: "TestPresets") {
                Task { @MainActor in
                    @MainActor func log(_ s: String) {
                        let shown = visibleModules.filter { $0.op == "exposure" || $0.op == "diffuse" }.map { "\(Presentation.title(of: $0)) \($0.enabled)" }
                        FileHandle.standardError.write("Develop presets test: \(s): presets \(presetList.count), diffuse \(presets(for: "diffuse").prefix(3).map(\.title)), shown \(shown)\n".data(using: .utf8)!)
                    }
                    try? await Task.sleep(for: .seconds(4))
                    filter = .all
                    log("start")
                    newInstance(of: "exposure:0")
                    try? await Task.sleep(for: .seconds(3)); log("new instance")
                    if let p = presets(for: "diffuse").first(where: { $0.title.contains("dehaze") }), let d = modules.first(where: { $0.op == "diffuse" }) {
                        applyPreset(p, module: d.key)
                    }
                    try? await Task.sleep(for: .seconds(3)); log("preset")
                    if let extra = modules.first(where: { $0.op == "exposure" && !$0.key.hasSuffix(":0") && !Self.isLocal($0) }) { deleteInstance(extra.key) }
                    try? await Task.sleep(for: .seconds(3)); log("deleted")
                }
            }
            // TestLook: launch argument (-TestLook YES) for testing: applies the first Portra
            // look in the LUT folder, then 50% strength, and logs the catalogue and state
            if UserDefaults.standard.bool(forKey: "TestLook") {
                Task { @MainActor in
                    @MainActor func log(_ s: String) {
                        let films = Set(filmLooks.map(\.film)).count
                        FileHandle.standardError.write("Develop look test: \(s): looks \(filmLooks.count) in \(films) films, current \(currentLook ?? "none") at \(lookStrength)\n".data(using: .utf8)!)
                    }
                    try? await Task.sleep(for: .seconds(4))
                    log("start")
                    applyLook(filmLooks.first { $0.film.contains("Portra 400") && $0.variant == "Normal" })
                    try? await Task.sleep(for: .seconds(3)); log("applied")
                    setLookStrength(50)
                    try? await Task.sleep(for: .seconds(3)); log("half")
                    if let f = films.first(where: { $0.name.contains("Velvia") }) { favouriteLooks.insert(f.id) }
                    lookBrowserOpen = true
                    try? await Task.sleep(for: .seconds(6)); log("browser")
                }
            }
            // TestRename: launch argument (-TestRename name) for testing: renames the photo
            if let newName = UserDefaults.standard.string(forKey: "TestRename"), !newName.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    if let key = modules.first(where: { $0.op == "exposure" })?.key { setValue(.number(1), module: key, field: "exposure") }
                    try? await Task.sleep(for: .seconds(2))
                    renamePhoto(to: newName)
                    try? await Task.sleep(for: .seconds(5))
                    FileHandle.standardError.write("Develop rename test: now \(self.url?.lastPathComponent ?? "-"), files \((try? FileManager.default.contentsOfDirectory(atPath: self.url?.deletingLastPathComponent().path ?? "")) ?? [])\n".data(using: .utf8)!)
                }
            }
            // TestPaste: launch argument (-TestPaste /path/to/other.NEF) for testing: edits this
            // photo, copies, opens the other, pastes, then undoes
            if let other = UserDefaults.standard.string(forKey: "TestPaste"), !other.isEmpty, self.url?.path != other {
                Task { @MainActor in
                    @MainActor func ev() -> String { "\(modules.first { $0.key == "exposure:0" }?.fields.first { $0.name == "exposure" }?.value.number ?? -99)" }
                    try? await Task.sleep(for: .seconds(4))
                    setValue(.number(1.8), module: "exposure:0", field: "exposure")
                    try? await Task.sleep(for: .seconds(2))
                    copyAdjustments()
                    try? await Task.sleep(for: .seconds(1))
                    await open(URL(fileURLWithPath: other))
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write("Develop paste test: opened \(self.url?.lastPathComponent ?? "-") exposure \(ev()), can paste \(canPaste)\n".data(using: .utf8)!)
                    pasteAdjustments()
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write("Develop paste test: pasted, exposure \(ev()), undo \(undoTitle ?? "-")\n".data(using: .utf8)!)
                    await undo()
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write("Develop paste test: undone, exposure \(ev())\n".data(using: .utf8)!)
                }
            }
            // TestMultiPaste: launch argument (-TestMultiPaste YES) for testing: edits this photo,
            // copies, selects the folder's other photos with ⌘-click and pastes onto them
            if UserDefaults.standard.bool(forKey: "TestMultiPaste") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    setValue(.number(1.6), module: "exposure:0", field: "exposure")
                    try? await Task.sleep(for: .seconds(2))
                    copyAdjustments()
                    try? await Task.sleep(for: .seconds(1))
                    toggleLibrary()
                    try? await Task.sleep(for: .seconds(2))
                    let others = library.items.map(\.url).filter { $0 != self.url }
                    if let first = others.first { library.click(first, command: false, shift: false) }
                    for o in others.dropFirst() { library.click(o, command: true, shift: false) }
                    FileHandle.standardError.write("Develop multi test: selected \(library.selectedInOrder.map(\.lastPathComponent)), targets \(pasteTargets.count)\n".data(using: .utf8)!)
                    pasteAdjustments()
                    try? await Task.sleep(for: .seconds(4))
                    let dir = self.url?.deletingLastPathComponent().path ?? ""
                    FileHandle.standardError.write("Develop multi test: sidecars \(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".xmp") }.sorted())\n".data(using: .utf8)!)
                }
            }
            // MatchLocations: launch argument (-MatchLocations "/folder1:/folder2") to place
            // photos without a location from the iPhone photos in Photos and the camera's own
            // located photos, as Places' Match Locations does; logs counts only
            if let folders = UserDefaults.standard.string(forKey: "MatchLocations") {
                UserDefaults.standard.removeObject(forKey: "MatchLocations")
                Task { @MainActor in await matchLocations(in: folders.split(separator: ":").map { URL(fileURLWithPath: String($0)) }) }
            }
            // TestSubject: launch argument (-TestSubject YES) for testing: adds a subject
            // adjustment, brightens it by 2 EV and logs its outlines
            if UserDefaults.standard.bool(forKey: "TestSubject") {
                UserDefaults.standard.set(false, forKey: "TestSubject")
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    let t0 = Date()
                    addSubject()
                    try? await Task.sleep(for: .milliseconds(200))
                    while isFindingSubject { try? await Task.sleep(for: .milliseconds(50)) }
                    let found = Date().timeIntervalSince(t0)
                    try? await Task.sleep(for: .seconds(2))
                    if let key = selectedLocal { setValue(.number(2), module: key, field: "exposure") }
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write("Develop subject test: \(String(format: "%.2f", found))s, selected \(selectedLocal ?? "-"), kind \(String(describing: localShape?.kind)), outlines \(localShape?.outlines.map(\.count) ?? []), error \(errorMessage ?? "-")\n".data(using: .utf8)!)
                }
            }
            // TestPhotos: launch argument (-TestPhotos YES) for testing: reads Photos (access,
            // albums, the newest photos) and opens the newest, logging only counts and names
            if UserDefaults.standard.bool(forKey: "TestPhotos"), openingPhotosAsset == nil {
                UserDefaults.standard.set(false, forKey: "TestPhotos")
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write("Develop photos test: authorised \(PhotosLibrary.authorised)\n".data(using: .utf8)!)
                    let shown = Date()
                    showPhotos(UserDefaults.standard.bool(forKey: "TestPhotosPlaces") ? .photosPlaces : .photos(album: nil, title: "All Photos"))
                    while library.items.isEmpty || library.isScanning || library.isLoadingLocations { try? await Task.sleep(for: .milliseconds(50)) }
                    FileHandle.standardError.write("Develop photos test: shown in \(String(format: "%.2f", Date().timeIntervalSince(shown)))s\n".data(using: .utf8)!)
                    try? await Task.sleep(for: .seconds(6))
                    let t0 = Date()
                    library.loadLocations()
                    FileHandle.standardError.write("Develop photos test: albums \(photosAlbums.count), items \(library.items.count), thumbnails \(library.thumbnails.count), located \(library.items.filter { library.locations[$0.url] != nil }.count) in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s\n".data(using: .utf8)!)
                    if let first = library.items.first {
                        await open(first.url)
                        try? await Task.sleep(for: .seconds(4))
                        FileHandle.standardError.write("Develop photos test: opened \(self.url?.lastPathComponent ?? "-"), asset \(photosAsset != nil), library url matches \(libraryURL == first.url), modules \(modules.count), source \(library.source?.title ?? "-")\n".data(using: .utf8)!)
                    }
                }
            }
            // TestHEIF: launch argument (-TestHEIF /folder) for testing: exports this photo as
            // HEIC, 8-bit sRGB and 10-bit HLG P3, into the folder
            if let folder = UserDefaults.standard.string(forKey: "TestHEIF"), !folder.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    var s = ExportSettings(); s.format = .heif; s.longEdge = 1200; s.quality = 90
                    s.bitDepth = 8; s.profile = .sRGB
                    await export(s, to: URL(fileURLWithPath: folder + "/sdr8.heic"), remember: false)
                    s.bitDepth = 10; s.profile = .hlgP3
                    await export(s, to: URL(fileURLWithPath: folder + "/hlg10.heic"), remember: false)
                    FileHandle.standardError.write("Develop heif test: done, error \(errorMessage ?? "none")\n".data(using: .utf8)!)
                }
            }
            // TestExtras: launch argument (-TestExtras /folder) for testing: exports with a frame
            // and watermark as JPEG, PNG, HLG HEIF and a gain map JPEG, then one plain JPEG,
            // restoring the saved frame and watermark settings afterwards
            if let folder = UserDefaults.standard.string(forKey: "TestExtras"), !folder.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    let saved = ExportExtras.load()
                    var e = ExportExtras(); e.frameOn = true; e.frameShape = .even; e.frameWidth = 5
                    e.watermarkOn = true; e.watermarkText = "© Fraser Embrey"; e.watermarkPosition = 8
                    e.save()
                    var s = ExportSettings(); s.longEdge = 1200; s.quality = 90
                    s.format = .jpeg; s.bitDepth = 8; s.profile = .sRGB
                    await export(s, to: URL(fileURLWithPath: folder + "/x.jpg"), remember: false)
                    s.format = .png; s.bitDepth = 16
                    await export(s, to: URL(fileURLWithPath: folder + "/x.png"), remember: false)
                    s.format = .heif; s.bitDepth = 10; s.profile = .hlgP3
                    await export(s, to: URL(fileURLWithPath: folder + "/x.heic"), remember: false)
                    s.format = .jpegGainMap; s.bitDepth = 8; s.profile = .hlgP3
                    await export(s, to: URL(fileURLWithPath: folder + "/gainmap.jpg"), remember: false)
                    saved.save()
                    var none = ExportExtras(); none.frameOn = false; none.watermarkOn = false; none.save()
                    s.format = .jpeg; s.bitDepth = 8; s.profile = .sRGB
                    await export(s, to: URL(fileURLWithPath: folder + "/plain.jpg"), remember: false)
                    saved.save()
                    FileHandle.standardError.write("Develop extras test: done, error \(errorMessage ?? "none")\n".data(using: .utf8)!)
                }
            }
            // TestLevel: launch argument (-TestLevel YES) for testing: auto straighten from known rotations
            if UserDefaults.standard.bool(forKey: "TestLevel") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    beginCrop()
                    for deg in [0.0, 4, -3, 7] {
                        try? await Task.sleep(for: .seconds(1))
                        let frame = frameID
                        setStraighten(deg)
                        for _ in 0..<150 where frameID == frame { try? await Task.sleep(for: .milliseconds(30)) }
                        try? await Task.sleep(for: .seconds(1))
                        await autoStraighten()
                        FileHandle.standardError.write("Develop level test: from \(deg) -> \(straighten)\n".data(using: .utf8)!)
                    }
                }
            }
            // TestCrop: launch argument (-TestCrop YES) for testing: straighten 5°, check the
            // frame's shape and corners, auto straighten, then commit a centred half crop
            if UserDefaults.standard.bool(forKey: "TestCrop") {
                Task { @MainActor in
                    @MainActor func corners() -> String {
                        guard let img = image, let data = img.dataProvider?.data as Data? else { return "?" }
                        let (w, h, row) = (img.width, img.height, img.bytesPerRow)
                        let pts = [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)]
                        return pts.map { (x, y) in
                            let i = y * row + x * 4
                            return "\(data[i])/\(data[i + 1])/\(data[i + 2])"
                        }.joined(separator: " ")
                    }
                    @MainActor func log(_ s: String) {
                        FileHandle.standardError.write("Develop crop test: \(s): size \(imageSize), frame \(image.map { "\($0.width)x\($0.height)" } ?? "-"), straighten \(straighten), corners \(corners())\n".data(using: .utf8)!)
                    }
                    try? await Task.sleep(for: .seconds(4)); log("start")
                    beginCrop()
                    try? await Task.sleep(for: .seconds(2)); log("cropping")
                    setStraighten(5)
                    try? await Task.sleep(for: .seconds(3)); log("straightened 5")
                    await autoStraighten()
                    try? await Task.sleep(for: .seconds(3)); log("auto straightened")
                    setStraighten(5)
                    try? await Task.sleep(for: .seconds(2))
                    cropRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
                    commitCrop()
                    try? await Task.sleep(for: .seconds(3)); log("committed")
                    await undo()
                    try? await Task.sleep(for: .seconds(3)); log("undone crop")
                }
            }
            // StartExport: launch argument (-StartExport YES) for testing, opens as ⌘E would
            if UserDefaults.standard.bool(forKey: "StartExport") {
                Task { @MainActor in ExportPanel.present(model: self) }
            }
            sensor = reply.sensor ?? "bayer"
            photosAsset = openingPhotosAsset
            modules = reply.modules
            panBackdrop = nil
            selectedLocal = nil
            hasUnsavedChanges = false
            image = nil
            beforeImage = nil
            beforeKey = ""
            hdrAnalysis = nil
            headroomOverlay = nil
            appliedStyles = []
            styleHistoryEnds = []
            editsSinceStyle = 0
            fullRenderMs = 0
            framesSinceOpen = 0
            // camera looks are for raws: a JPEG or HEIC already has the camera's look
            suggestedStyle = isRaw ? CameraStyles.suggestion(in: styles, maker: reply.maker,
                                                             model: reply.model, alias: reply.alias) : nil
            // only unedited photos get the new-photo defaults; an existing
            // sidecar is the user's edit
            offerSuggestedStyle = false
            if viewHDR { useHDRProfileIfSDR() }
            openedWithEdit = reply.hadSidecar
            lensInfo = await Task.detached { Self.readLens(url) }.value
            await measureAutoExposure()
            await loadPresets()
            await loadLook()
            if !reply.hadSidecar { await applyNewPhotoDefaults() }
            requestRender()
        } catch {
            errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func save() async {
        guard let engine, url != nil else { return }
        do {
            try await engine.save()
            hasUnsavedChanges = false
            if let tiff = decodedTIFF, let url { AppleRawFallback.sidecarToOriginal(original: url, decoded: tiff, raw: decoderInUse != nil) }
            if let url {
                catalog.recordEdit(url)
                library.noteEdited(url)
            }
        } catch {
            errorMessage = "Couldn't save the XMP sidecar: \(error.localizedDescription)"
        }
    }

    // MARK: Essentials

    func isEssential(_ op: String) -> Bool { essentials.contains(op) }

    func toggleEssential(_ op: String) {
        if let i = essentials.firstIndex(of: op) { essentials.remove(at: i) } else { essentials.append(op) }
    }

    /// Moves `op` to just before `target` (drag and drop in the Essentials tab).
    func moveEssential(_ op: String, before target: String) {
        guard op != target, let from = essentials.firstIndex(of: op) else { return }
        essentials.remove(at: from)
        let to = essentials.firstIndex(of: target) ?? essentials.endIndex
        essentials.insert(op, at: to)
    }

    func resetEssentials() { essentials = Presentation.defaultEssentials }

    // MARK: Tone equalizer

    var toneEqualizerIsFitted: Bool {
        guard let te = modules.first(where: { $0.op == "toneequal" }) else { return false }
        let boost = { (n: String) in te.fields.first { $0.name == n }?.value.number ?? 0 }
        return boost("exposure_boost") != 0 || boost("contrast_boost") != 0
    }

    private var toneFitTask: Task<Void, Never>?

    /// Fits the tone equalizer once: callers arriving while a fit runs wait for
    /// that one instead of starting another.
    func ensureToneEqualizerFitted() async {
        if toneEqualizerIsFitted { return }
        if let toneFitTask { return await toneFitTask.value }
        let task = Task { await fitToneEqualizer() }
        toneFitTask = task
        await task.value
        toneFitTask = nil
    }

    func fitToneEqualizer() async {
        guard let engine else { return }
        recordUndoStep(label: "Tone Equalizer", gesture: modules.first { $0.op == "toneequal" }?.key)
        // any pending zone edits go first, so they land in the same history
        await settleEdits()
        do {
            modules = try await engine.fitToneEqualizer()
            hasUnsavedChanges = true
            requestRender()
        } catch {
            errorMessage = "Couldn't fit the tone equalizer: \(error.localizedDescription)"
        }
    }

    func autoTuneFilmic() async {
        guard let engine else { return }
        recordUndoStep(label: "Auto-Tune Filmic")
        await settleEdits()
        do {
            modules = try await engine.filmicAutoTune()
            hasUnsavedChanges = true
            requestRender()
        } catch {
            errorMessage = "Couldn't auto-tune filmic: \(error.localizedDescription)"
        }
    }

    /// Settings Develop applies to a photo without an edit: lens correction,
    /// optionally automatic exposure, and the camera style per the settings.
    /// a DNG's BaselineExposure (EV), if it has one
    nonisolated static func dngBaselineExposure(_ url: URL) -> Double? {
        guard url.pathExtension.lowercased() == "dng",
              let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let dng = props[kCGImagePropertyDNGDictionary] as? [CFString: Any] else { return nil }
        return (dng[kCGImagePropertyDNGBaselineExposure] as? NSNumber)?.doubleValue
    }

    private func applyNewPhotoDefaults() async {
        if lensCorrectionForNewPhotos, let lens = modules.first(where: { $0.op == "lens" }), !lens.enabled {
            // darktable picks the camera's embedded correction data if the raw
            // has it (Sony, Fujifilm, Olympus...), otherwise the Lensfun database
            setEnabled(true, module: lens.key)
        }
        if let url, decoderInUse == "darktable", sensor == "linear", let baseline = Self.dngBaselineExposure(url), abs(baseline) > 0.05,
           let exposure = modules.first(where: { $0.op == "exposure" }),
           let ev = exposure.fields.first(where: { $0.name == "exposure" })?.value.number {
            // darktable ignores a DNG's BaselineExposure, which says how much
            // brighter its data is meant to be shown. For a linear DNG (an HDR
            // merge from Capture One or Lightroom) it's large: Capture One's
            // carry +4 EV or so, and opened four stops too dark. Other raws
            // keep automatic exposure.
            setValue(.number(((ev + baseline) * 100).rounded() / 100), module: exposure.key, field: "exposure")
        } else if autoExposureForNewPhotos, let exposure = modules.first(where: { $0.op == "exposure" }) {
            setAuto(true, module: exposure)
        }
        if let style = suggestedStyle {
            switch cameraStyleMode {
            case .automatic: await applyStyle(style)
            case .suggest: offerSuggestedStyle = true
            case .off: break
            }
        }
    }

    /// Back to the photo as darktable would first show it, plus Develop's
    /// new-photo defaults. Not undoable, so the button asks first.
    func resetAll() async {
        guard let engine else { return }
        do {
            modules = try await engine.resetAll()
            appliedStyles = []
            styleHistoryEnds = []
            editsSinceStyle = 0
            pendingSets.removeAll()
            pendingCheckpoints.removeAll()
            undoGroupDepth += 1
            sdrVersion = SDRVersion()
            await applyNewPhotoDefaults()
            undoGroupDepth -= 1
            clearUndo()
            editedSinceOpen = true
            openedWithEdit = false
            if viewHDR { useHDRProfileIfSDR() }
            hasUnsavedChanges = true
            requestRender()
        } catch {
            errorMessage = "Couldn't reset: \(error.localizedDescription)"
        }
    }

    /// Everything automatic darktable can do for this photo: the camera style,
    /// automatic exposure, filmic's auto-tune and the tone equalizer's fit.
    var canAuto: Bool { url != nil }
    var confirmingReset = false

    func autoAll() async {
        recordUndoStep(label: "Auto")
        // one undo step for everything Auto does
        undoGroupDepth += 1
        defer { undoGroupDepth -= 1 }
        await matchCamera()
        if let filmic = modules.first(where: { $0.op == "filmicrgb" }), filmic.enabled { await autoTuneFilmic() }
        if let te = modules.first(where: { $0.op == "toneequal" }), te.enabled { await fitToneEqualizer() }
    }

    // MARK: Automatic modes

    /// Auto exposure sets the Exposure slider to a measured value, as
    /// Lightroom's does, rather than switching on darktable's automatic mode:
    /// that only runs on mosaic raws (silently doing nothing on monochrome raws,
    /// linear DNGs and other images) and hides the slider behind a percentile
    /// and a target level. The value is darktable's own rule, measured by the
    /// engine for any file. A photo saved in darktable's automatic mode is
    /// switched to the same value as a manual one when opened; for a raw that
    /// darktable could measure, the photo looks the same.
    private func measureAutoExposure() async {
        autoExposure = nil
        guard let engine, let m = modules.firstIndex(where: { $0.op == "exposure" }) else { return }
        let module = modules[m]
        // an HDR source is exposed already, as the camera (or Apple's raw
        // engine) rendered it; darktable's rule aims its middle tone at a
        // processed image's usual level, which lifted an iPhone HDR photo
        // by more than a stop, its highlights well past the format's peak
        autoExposure = openedAsHDR ? 0 : try? await engine.autoExposure(module: module.key)
        // an edit in darktable's automatic mode keeps its own percentile and target
        guard let mode = module.fields.firstIndex(where: { $0.name == "mode" }),
              Int(module.fields[mode].value.number) == 1,
              let value = try? await engine.autoExposure(module: module.key, standard: false),
              let ev = module.fields.firstIndex(where: { $0.name == "exposure" }) else { return }
        // not an edit of the user's: no undo step, nothing to save on its own
        modules[m].fields[mode].value = .number(0)
        modules[m].fields[ev].value = .number(value)
        pendingSets.append((module.key, "mode", .number(0)))
        pendingSets.append((module.key, "exposure", .number(value)))
    }

    func isAuto(_ module: EngineModule) -> Bool {
        if module.op == "exposure" {
            let mode = module.fields.first { $0.name == "mode" }?.value.number ?? 0
            let ev = module.fields.first { $0.name == "exposure" }?.value.number
            if mode == 1 { return true }
            guard let auto = autoExposure, let ev else { return false }
            return abs(ev - auto) < 0.005
        }
        guard let rule = Presentation.autoModes[module.op],
              let field = module.fields.first(where: { $0.name == rule.field }) else { return false }
        return Int(field.value.number) == rule.auto
    }

    func setAuto(_ on: Bool, module: EngineModule) {
        if module.op == "exposure" {
            // on: the measured value; off: darktable's default for the photo
            let ev = on ? autoExposure : module.fields.first { $0.name == "exposure" }?.defaultValue.number
            guard let ev else { return }
            setValue(.number(0), module: module.key, field: "mode")
            setValue(.number((ev * 100).rounded() / 100), module: module.key, field: "exposure")
            return
        }
        guard let rule = Presentation.autoModes[module.op] else { return }
        setValue(.number(Double(on ? rule.auto : rule.manual)), module: module.key, field: rule.field)
    }

    // MARK: Edits

    func applyStyle(_ style: StyleInfo) async {
        guard let engine else { return }
        recordUndoStep(label: "Apply \(style.title)")
        await settleEdits()
        do {
            let reply = try await engine.applyStyle(style.name)
            modules = reply.modules
            appliedStyles.append(style.name)
            styleHistoryEnds.append(reply.historyEndBefore)
            editsSinceStyle = 0
            offerSuggestedStyle = false
            hasUnsavedChanges = true
            requestRender()
        } catch {
            errorMessage = "Couldn't apply \(style.title): \(error.localizedDescription)"
        }
    }

    /// Removes the most recent style: with no edits since, that's the top undo step.
    func undoLastStyle() async {
        guard editsSinceStyle == 0, !appliedStyles.isEmpty else { return }
        await undo()
    }

    func setValue(_ value: FieldValue, module: String, field: String) {
        guard let m = modules.firstIndex(where: { $0.key == module }),
              let f = modules[m].fields.firstIndex(where: { $0.name == field }) else { return }
        modules[m].fields[f].value = value
        modules[m].enabled = true
        hasUnsavedChanges = true
        // by module, so controls that set several fields (tone equalizer zones,
        // scene white) make one step
        recordUndoStep(label: Presentation.title(of: modules[m]), gesture: module)
        editsSinceStyle += 1
        // only the latest value per field is sent, but never merged across an undo checkpoint
        let floor = pendingCheckpoints.last?.position ?? 0
        if let i = pendingSets.indices.last(where: { $0 >= floor && pendingSets[$0].module == module && pendingSets[$0].field == field }) {
            pendingSets.remove(at: i)
        }
        pendingSets.append((module, field, value))
        requestRender()
    }

    func setEnabled(_ on: Bool, module: String) {
        guard let m = modules.firstIndex(where: { $0.key == module }) else { return }
        modules[m].enabled = on
        hasUnsavedChanges = true
        recordUndoStep(label: "\(on ? "Turn On" : "Turn Off") \(Presentation.title(of: modules[m]))")
        // the RGB curve card switches its colour curves with it
        let channels = modules[m].op == "rgbcurve" ? channelCurveModule?.key : nil
        if let channels, let c = modules.firstIndex(where: { $0.key == channels }) { modules[c].enabled = on }
        // queued behind pending sets so the undo step resolves before it
        Task {
            await settleEdits()
            try? await engine?.enable(module: module, on: on)
            if let channels { try? await engine?.enable(module: channels, on: on) }
            requestRender()
        }
    }

    /// a text setting, such as the lens module's camera or lens, as one undo step
    func setText(_ value: String, module: String, field: String) {
        guard let m = modules.first(where: { $0.key == module }) else { return }
        recordUndoStep(label: Presentation.title(of: m))
        hasUnsavedChanges = true
        Task {
            guard let engine else { return }
            await settleEdits()
            do {
                modules = try await engine.setText(module: module, field: field, value: value)
                requestRender()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func reset(module: String) {
        recordUndoStep(label: "Reset \(modules.first { $0.key == module }.map(Presentation.title) ?? "Module")")
        Task {
            guard let engine else { return }
            await settleEdits()
            do {
                // the RGB curve card resets its colour curves too
                let channels = modules.first { $0.key == module }?.op == "rgbcurve" ? channelCurveModule?.key : nil
                modules = try await engine.reset(module: module)
                if let channels { modules = try await engine.reset(module: channels) }
                hasUnsavedChanges = true
                requestRender()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Rendering

    func canvasDidResize(toSize size: CGSize, displayScale: CGFloat) {
        let px = CGSize(width: size.width * displayScale, height: size.height * displayScale)
        let changed = abs(px.width - canvasSizePx.width) > 32 || abs(px.height - canvasSizePx.height) > 32
        canvasSizePx = px
        if changed, case .scale = zoom, url != nil { requestRender() }
        canvasDidResize(toPixels: Int(max(px.width, px.height)))
    }

    func canvasDidResize(toPixels px: Int) {
        // re-render only for meaningful size changes
        let clamped = max(400, min(px, 4096))
        guard abs(clamped - canvasPixels) > 64 else { return }
        canvasPixels = clamped
        if url != nil { requestRender() }
    }

    private func requestRender() {
        renderRequested = true
        pump()
    }

    /// While edits are arriving (a slider being dragged), frames render at full
    /// resolution if that's fast enough to keep up. Only when full renders are
    /// slow (heavy modules such as denoise) are they drafted at two-thirds size,
    /// with one full-resolution frame once edits pause.
    private func pump() {
        guard !pumping, let engine else { return }
        pumping = true
        Task {
            defer { pumping = false }
            while !pendingSets.isEmpty || !pendingCheckpoints.isEmpty || pendingCurve != nil || renderRequested {
                let sets = pendingSets
                let checkpoints = pendingCheckpoints
                pendingSets.removeAll()
                pendingCheckpoints.removeAll()
                renderRequested = false
                // ~110 ms is about where dragging starts to feel laggy; zoomed
                // crops are small already and must stay sharp, so never drafted
                let crop = currentCrop
                let renderStraighten = straighten
                let curve = pendingCurve
                pendingCurve = nil
                let draft = (!sets.isEmpty || curve != nil) && fullRenderMs > 110 && crop == nil
                let pixels = draft ? max(640, canvasPixels * 2 / 3) : canvasPixels
                let start = ContinuousClock.now
                do {
                    // sets go in segments split at undo checkpoints, so each
                    // checkpoint records the history position where it falls
                    var sent = 0
                    for c in checkpoints {
                        try await engine.setMany(Array(sets[sent..<c.position]))
                        sent = c.position
                        resolveUndoStep(c.id, end: await engine.historyEnd)
                    }
                    try await engine.setMany(Array(sets[sent...]))
                    if let c = curve {
                        try await engine.setCurve(module: c.module, channel: c.channel, nodes: c.nodes, linked: c.linked)
                    }
                    let simulate = viewHDR ? previewHeadroomStops : nil
                    let frame = try await engine.render(maxPixels: pixels, hdr: viewHDR,
                                                        displayHeadroom: displayHeadroom,
                                                        wantOverlay: showHeadroomOverlay && simulate == nil, crop: crop,
                                                        overrides: (showsSDRVersion ? sdrOverrides : []) + cropOverrides + curveOverrides,
                                                        hdrLimit: viewHDR ? hdrLimit : nil,
                                                        keepForRefresh: crop == nil)
                    if frame.processedSize.width > 0 { imageSize = frame.processedSize }
                    // the curve's histogram is of the module's input, which a curve edit
                    // doesn't change; and the points on screen are newer than the engine's
                    // a curve shown for the first time (or a new colour curves instance)
                    // is fetched whatever; asking turns its histogram on, so one more
                    // render fills it
                    if let key = curveEditorModule, crop == nil, (curve == nil && pendingCurve == nil) || curveInfoKey != key {
                        let fresh = curveInfoKey != key
                        curveInfo = try? await engine.curve(module: key)
                        curveInfoKey = key
                        if fresh { renderRequested = true }
                    }
                    // the shape may have changed with an undo, or been placed by the engine
                    if selectedLocal != nil, pendingShape == nil, !sendingShape { await fetchLocalShape() }
                    frameStraighten = renderStraighten
                    if crop == nil, !isCropping, !isSimulatingHeadroom {
                        thumbnailFrame = frame.image
                        panBackdrop = (frame.image, frame.isHDR)
                    }
                    if let r = frame.rotateInSize { rotateInSize = r }
                    if let simulate, frame.isHDR {
                        image = try await gainMapPreview(frame, stops: simulate, maxPixels: pixels, crop: crop, engine: engine)
                    } else {
                        image = frame.image
                    }
                    isSimulatingHeadroom = simulate != nil && frame.isHDR
                    if isSimulatingHeadroom, let img = image {
                        FileHandle.standardError.write("Develop preview at +\(simulate!) stops: headroom \(img.contentHeadroom), frame peak \(frame.analysis?.peak ?? 0)\n".data(using: .utf8)!)
                    }
                    imageIsZoomed = crop != nil
                    shownCrop = crop
                    frameID += 1
                    imageIsHDR = frame.isHDR
                    if crop == nil {
                        hdrAnalysis = frame.analysis
                        if let h = frame.histogram { rgbHistogram = h }
                    } else if !sets.isEmpty || (viewHDR ? hdrAnalysis == nil : rgbHistogram == nil) {
                        // while zoomed the histograms describe the whole photo, so after
                        // an edit render a small full frame just for them
                        let whole = try await engine.render(maxPixels: 600, hdr: viewHDR,
                                                            displayHeadroom: displayHeadroom, wantOverlay: false,
                                                            overrides: (showsSDRVersion ? sdrOverrides : []) + cropOverrides,
                                                            hdrLimit: viewHDR ? hdrLimit : nil)
                        hdrAnalysis = whole.analysis
                        if let h = whole.histogram { rgbHistogram = h }
                        if !isCropping { panBackdrop = (whole.image, whole.isHDR) }
                    }
                    headroomOverlay = frame.overlay
                    let elapsed = ContinuousClock.now - start
                    lastRenderMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
                    lastRenderWasDraft = draft
                    // DumpFrame: launch argument (-DumpFrame /path/frame.png) for testing, writes each full frame
                    if let path = UserDefaults.standard.string(forKey: "DumpFrame"), crop == nil, !draft,
                       let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, frame.image, nil)
                        CGImageDestinationFinalize(dest)
                    }
                    // LogRenderTimes: launch argument (-LogRenderTimes YES) for testing
                    if UserDefaults.standard.bool(forKey: "LogRenderTimes") {
                        // mean of the first channel, to check edits reach the frame
                        let mean = frame.pixels.withUnsafeBytes { raw -> Double in
                            if frame.isHDR {
                                let f = raw.bindMemory(to: Float.self)
                                let n = Double(f.count / (4 * 97))
                                let rgb = (0..<3).map { c in stride(from: c, to: f.count, by: 4 * 97).reduce(0) { $0 + Double(f[$1]) } / n }
                                FileHandle.standardError.write("Develop HDR frame RGB means \(rgb.map { String(format: "%.3f", $0) })\n".data(using: .utf8)!)
                                return rgb[0]
                            }
                            let b = raw.bindMemory(to: UInt8.self)
                            return stride(from: 0, to: b.count, by: 4 * 97).reduce(0) { $0 + Double(b[$1]) } / Double(b.count / (4 * 97))
                        }
                        FileHandle.standardError.write("Develop frame \(lastRenderMs ?? 0) ms (engine \(frame.ms) ms), mean \(String(format: "%.3f", mean))\n".data(using: .utf8)!)
                    }
                    framesSinceOpen += 1
                    // the first frame after opening fills the cache and is always slow
                    if !draft, crop == nil, framesSinceOpen > 1 {
                        // smoothed, so one slow frame doesn't flip the mode
                        let ms = Double(lastRenderMs ?? 0)
                        fullRenderMs = fullRenderMs == 0 ? ms : fullRenderMs * 0.6 + ms * 0.4
                    }
                } catch {
                    errorMessage = error.localizedDescription
                    return
                }
                if draft { settleAfterEdits() }
                await renderBeforeIfNeeded(engine)
            }
        }
    }

    /// The before image never changes with edits, so it's rendered once per
    /// canvas size and SDR/HDR mode, at full size.
    private func renderBeforeIfNeeded(_ engine: Engine) async {
        let crop = currentCrop
        let key = "\(canvasPixels)-\(viewHDR)-\(String(describing: crop))"
        guard comparing, key != beforeKey else { return }
        do {
            let frame = try await engine.render(maxPixels: canvasPixels, hdr: viewHDR,
                                                displayHeadroom: displayHeadroom, wantOverlay: false,
                                                before: true, crop: crop, hdrLimit: viewHDR ? hdrLimit : nil)
            beforeImage = frame.image
            beforeKey = key
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The HDR frame as a gain map viewer would show it with `stops` of
    /// headroom, using the SDR base the export is set to make.
    private func gainMapPreview(_ frame: Engine.Frame, stops: Double, maxPixels: Int, crop: Engine.Crop?,
                                engine: Engine) async throws -> CGImage {
        var sdr: Engine.Frame?
        if ExportSettings.load().sdrBase == .darktable {
            let f = try await engine.render(maxPixels: maxPixels, hdr: false, displayHeadroom: 1, wantOverlay: false,
                                            crop: crop, overrides: sdrOverrides)
            if f.width == frame.width, f.height == frame.height { sdr = f }
        }
        return try await engine.gainMapPreview(hdr: frame, sdr: sdr, stops: stops)
    }

    // MARK: Export

    private(set) var isExporting = false
    private(set) var lastExport: URL? {
        didSet { if lastExport != nil { showExportDone = true } }
    }
    var showExportDone = false

    /// the edit's export profile, as the HDR card describes it
    var exportTarget: HDRTarget { HDRTarget(darktableProfile: outputProfileType ?? 1) }

    /// pixel size of an export at the given long edge (0 = original)
    func exportSize(longEdge: Int) -> CGSize {
        let long = max(imageSize.width, imageSize.height)
        let scale = longEdge > 0 ? min(1, Double(longEdge) / long) : 1
        return CGSize(width: (imageSize.width * scale).rounded(), height: (imageSize.height * scale).rounded())
    }

    func export(_ settings: ExportSettings, to url: URL, remember: Bool = true) async {
        guard let engine else { return }
        isExporting = true
        defer { isExporting = false }
        if remember { settings.save() }
        do {
            if settings.format == .jpegGainMap {
                try await exportGainMapJPEG(settings, to: url, engine: engine)
                lastExport = url
                FileHandle.standardError.write("Develop exported \(url.path)\n".data(using: .utf8)!)
            } else if settings.format == .heif || ExportExtras.load().any || toneMapsExport(settings) {
                // HEIF, anything with a frame or watermark, and an HDR source made SDR, through Core Image
                try await exportThroughCoreImage(settings, to: url, engine: engine)
                lastExport = url
            } else {
                // darktable adds the extension itself
                lastExport = try await engine.export(
                    path: url.deletingPathExtension().path, format: settings.format.darktableName ?? "jpeg",
                    quality: settings.quality, bitDepth: settings.bitDepth, maxEdge: settings.longEdge,
                    profile: settings.profile == .fromEdit ? nil : settings.profile.rawValue)
            }
            if let photo = self.url, let file = lastExport {
                catalog.recordExport(photo, file: file, format: settings.format.title)
            }
        } catch {
            FileHandle.standardError.write("Develop export failed: \(error)\n".data(using: .utf8)!)
            errorMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }

    /// Exports through Core Image: darktable exports a 16-bit (or float) TIFF
    /// already encoded in the export's profile (sRGB, Display P3, PQ, HLG and
    /// so on), the frame and watermark are drawn on it, and Core Image writes
    /// it as HEIF, JPEG, PNG or TIFF, tagged with the matching colour space.
    /// Colour management is off for the encoding step, so nothing is converted
    /// twice; the TIFF's metadata (EXIF and the rest) goes into the file.
    /// Used for HEIF always, and for the others when there's a frame or watermark.
    /// whether an export is an HDR source (see Engine.sdrFromHDR) made SDR:
    /// darktable's own export would clip its highlights, so it's tone mapped
    private func toneMapsExport(_ settings: ExportSettings) -> Bool {
        guard openedAsHDR, settings.format != .jpegGainMap else { return false }
        let profile = settings.profile == .fromEdit ? (outputProfileType ?? 1) : settings.profile.rawValue
        return !HDRTarget(darktableProfile: profile).isHDR
    }

    private func exportThroughCoreImage(_ settings: ExportSettings, to url: URL, engine: Engine) async throws {
        let profile = settings.profile == .fromEdit ? (outputProfileType ?? 1) : settings.profile.rawValue
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("develop-export-\(UUID().uuidString)")
        let toneMap = toneMapsExport(settings)
        let float = toneMap || (settings.format == .tiff && settings.bitDepth == 32)
        let extras = ExportExtras.load()
        // smaller by the frame's share, so the framed picture is the size chosen;
        // an HDR source to be tone mapped comes out linear and unclipped
        let tiff = try await engine.export(path: temp.path, format: "tiff", quality: 100, bitDepth: float ? 32 : 16,
                                           maxEdge: extras.any ? extras.photoLongEdge(for: settings.longEdge, photo: imageSize) : settings.longEdge,
                                           profile: toneMap ? 4 : profile)
        defer { try? FileManager.default.removeItem(at: tiff) }
        let quality = Double(settings.quality) / 100
        try await Task.detached(priority: .userInitiated) {
            let tagged = toneMap ? nil : Self.colourSpace(forDarktableProfile: profile)
            // the values as darktable encoded them, or through its ICC profile
            var image: CIImage
            let space: CGColorSpace
            if toneMap {
                guard let linear = CIImage(contentsOf: tiff, options: [.colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!]) else {
                    throw EngineError(message: "Couldn't read darktable's export.")
                }
                image = Self.toneMappedToSDR(linear)
                space = Self.colourSpace(forDarktableProfile: profile) ?? CGColorSpace(name: CGColorSpace.sRGB)!
            } else {
                guard let read = tagged != nil ? CIImage(contentsOf: tiff, options: [.colorSpace: NSNull()]) : CIImage(contentsOf: tiff),
                      let s = tagged ?? CIImage(contentsOf: tiff)?.colorSpace else {
                    throw EngineError(message: "Couldn't read darktable's export.")
                }
                (image, space) = (read, s)
            }
            if extras.any { image = extras.composite(image, white: tagged != nil ? Self.whiteLevel(forDarktableProfile: profile) : 1) }
            let context = tagged != nil ? CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]) : CIContext()
            let lossy = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
            switch settings.format {
            case .heif:
                if settings.bitDepth >= 10 {
                    try context.writeHEIF10Representation(of: image, to: url, colorSpace: space, options: lossy)
                } else {
                    try context.writeHEIFRepresentation(of: image, to: url, format: .RGBA8, colorSpace: space, options: lossy)
                }
            case .jpeg:
                try context.writeJPEGRepresentation(of: image, to: url, colorSpace: space, options: lossy)
            case .png:
                try context.writePNGRepresentation(of: image, to: url, format: settings.bitDepth >= 16 ? .RGBA16 : .RGBA8,
                                                   colorSpace: space, options: [:])
            case .tiff:
                let format: CIFormat = settings.bitDepth >= 32 ? .RGBAf : settings.bitDepth >= 16 ? .RGBA16 : .RGBA8
                try context.writeTIFFRepresentation(of: image, to: url, format: format, colorSpace: space, options: [:])
            case .jpegGainMap:
                throw EngineError(message: "A gain map JPEG is made from renders, not an export.")
            }
        }.value
        FileHandle.standardError.write("Develop exported \(url.path)\n".data(using: .utf8)!)
    }

    /// An HDR image (SDR white at 1, linear Rec.2020) brought within SDR
    /// white, as the engine's SDR renders of an HDR source are.
    nonisolated static func toneMappedToSDR(_ image: CIImage) -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        let extent = image.extent.integral
        let (w, h) = (Int(extent.width), Int(extent.height))
        var px = Data(count: w * h * 16)
        px.withUnsafeMutableBytes { raw in
            CIContext(options: [.workingColorSpace: space])
                .render(image, toBitmap: raw.baseAddress!, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: space)
            GainMapPreview.rollOffToSDR(raw.bindMemory(to: Float.self))
        }
        return CIImage(bitmapData: px, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: space)
    }

    /// the value that is white (203 nits, reference white) in darktable's
    /// export encodings: 1 for SDR and linear ones, the HLG and PQ signal for it
    nonisolated static func whiteLevel(forDarktableProfile type: Int) -> Double {
        switch type {
        case 23, 25: 0.75          // HLG: reference white at 75% signal (BT.2408)
        case 22, 24:               // PQ: 203 of 10,000 nits
            {
                let y = 203.0 / 10_000, m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
                let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
                let p = pow(y, m1)
                return pow((c1 + c2 * p) / (1 + c3 * p), m2)
            }()
        default: 1
        }
    }

    /// macOS's colour space for darktable's export profiles that have one
    nonisolated static func colourSpace(forDarktableProfile type: Int) -> CGColorSpace? {
        let name: CFString? = switch type {
        case 1: CGColorSpace.sRGB
        case 2: CGColorSpace.adobeRGB1998
        case 4: CGColorSpace.linearITUR_2020
        case 26: CGColorSpace.displayP3
        case 22: CGColorSpace.itur_2100_PQ
        case 23: CGColorSpace.itur_2100_HLG
        case 24: CGColorSpace.displayP3_PQ
        case 25: CGColorSpace.displayP3_HLG
        default: nil
        }
        return name.flatMap { CGColorSpace(name: $0) }
    }

    /// A JPEG with an ISO 21496-1 HDR gain map, written by Core Image.
    /// The HDR image is exactly what the HDR preview shows: darktable's output
    /// in the edit's HDR profile, on the EDR scale. The SDR base is, by default,
    /// darktable's own SDR rendering of the edit (the tone mapper's target white
    /// back at 100%); Core Image computes the gain map between the two. Viewers
    /// without HDR, or with little headroom, mostly see that SDR base.
    private func exportGainMapJPEG(_ settings: ExportSettings, to url: URL, engine: Engine) async throws {
        var target = exportTarget
        if settings.profile != .fromEdit { target = HDRTarget(darktableProfile: settings.profile.rawValue) }
        guard target.isHDR else {
            throw EngineError(message: "A gain map needs an HDR edit: choose an HLG or PQ export format in the HDR card, or an HDR colour profile here.")
        }
        if settings.profile != .fromEdit { setOutputProfile(settings.profile.rawValue) }
        // smaller by the frame's share, if there is one, so the framed picture is the size chosen
        let extrasForSize = ExportExtras.load()
        let size = exportSize(longEdge: extrasForSize.any ? extrasForSize.photoLongEdge(for: settings.longEdge, photo: imageSize) : settings.longEdge)
        let maxPixels = Int(max(size.width, size.height))

        let hdrFrame = try await engine.render(maxPixels: maxPixels, hdr: true, displayHeadroom: 16, wantOverlay: false,
                                               hdrLimit: hdrLimit)
        let hdr = CIImage(cgImage: hdrFrame.image)

        let sdr: CIImage
        switch settings.sdrBase {
        case .darktable:
            let sdrFrame = try await engine.render(maxPixels: maxPixels, hdr: false, displayHeadroom: 1, wantOverlay: false,
                                                   overrides: sdrOverrides)
            sdr = CIImage(cgImage: sdrFrame.image)
        case .automatic:
            let toneMap = CIFilter.toneMapHeadroom()
            toneMap.inputImage = hdr
            toneMap.sourceHeadroom = Float(max(hdrFrame.analysis?.peak ?? 1, 1))
            toneMap.targetHeadroom = 1
            guard let out = toneMap.outputImage else { throw EngineError(message: "Couldn't make the SDR base image.") }
            sdr = out
        }

        // the frame and watermark on both, so the gain map between them is the photo's
        let extras = ExportExtras.load()
        let framedHDR = extras.any ? extras.composite(hdr) : hdr
        let framedSDR = extras.any ? extras.composite(sdr) : sdr
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): Double(settings.quality) / 100,
            .hdrImage: framedHDR,
        ]
        try CIContext().writeJPEGRepresentation(of: framedSDR, to: url, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                                options: options)
        // render the preview again at its own size (the frame file was reused)
        requestRender()
    }

    /// settings that turn the edit into its SDR rendition: tone mappers back to
    /// 100% white, plus the SDR version's own adjustments
    private var sdrOverrides: [Engine.Override] {
        var overrides = modules.compactMap { m -> Engine.Override? in
            switch m.op {
            case "sigmoid": Engine.Override(module: m.key, field: "display_white_target", value: 100)
            case "filmicrgb": Engine.Override(module: m.key, field: "white_point_target", value: 100)
            default: nil
            }
        }
        func current(_ m: EngineModule, _ field: String) -> Double? {
            m.fields.first { $0.name == field }?.value.number
        }
        let v = sdrVersion
        if v.brightness != 0, let exposure = modules.first(where: { $0.op == "exposure" && $0.enabled }) {
            // in automatic mode darktable sets exposure from its target level
            let field = current(exposure, "mode") == 1 ? "deflicker_target_level" : "exposure"
            if let value = current(exposure, field) {
                overrides.append(.init(module: exposure.key, field: field, value: value + v.brightness))
            }
        }
        if v.contrast != 0 {
            let fields = ["sigmoid": "middle_grey_contrast", "filmicrgb": "contrast", "agx": "curve_contrast_around_pivot"]
            for m in modules where m.enabled {
                if let field = fields[m.op], let value = current(m, field) {
                    overrides.append(.init(module: m.key, field: field, value: value * pow(2, v.contrast / 2)))
                }
            }
        }
        if v.saturation != 0, let balance = modules.first(where: { $0.op == "colorbalancergb" }),
           let value = current(balance, "saturation_global") {
            overrides.append(.init(module: balance.key, field: "saturation_global",
                                   value: min(max(value + v.saturation, -1), 1), enable: true))
        }
        return overrides
    }

    // MARK: Output profile

    /// darktable's export profile (output color profile module), as its enum value.
    var outputProfileType: Int? {
        modules.first { $0.key == "colorout:0" }?.fields.first { $0.name == "type" }.map { Int($0.value.number) }
    }

    /// Viewing HDR with an SDR export profile shows nothing above white, so
    /// switch to HLG P3, the most widely supported HDR format. It's an edit like
    /// any other: saved with the photo and undone by choosing SDR again.
    private func useHDRProfileIfSDR() {
        guard url != nil, let type = outputProfileType, !HDRTarget(darktableProfile: type).isHDR else { return }
        setOutputProfile(25)   // HLG P3
    }

    func setOutputProfile(_ type: Int) {
        setValue(.number(Double(type)), module: "colorout:0", field: "type")
    }

    // MARK: Match Camera

    /// Camera style plus darktable's automatic exposure: roughly what the
    /// camera's own JPEG would look like. Nothing here analyses the content.
    var canMatchCamera: Bool {
        guard url != nil else { return false }
        let styleDone = suggestedStyle.map { appliedStyles.contains($0.name) } ?? true
        let exposureDone = modules.first { $0.op == "exposure" }.map(isAuto) ?? true
        return !(styleDone && exposureDone)
    }

    func matchCamera() async {
        if let style = suggestedStyle, !appliedStyles.contains(style.name) { await applyStyle(style) }
        if let exposure = modules.first(where: { $0.op == "exposure" }), !isAuto(exposure) {
            setAuto(true, module: exposure)
        }
    }

    private func settleAfterEdits() {
        settleTask?.cancel()
        settleTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, pendingSets.isEmpty else { return }
            requestRender()
        }
    }
}

// MARK: - Undo

/// A point to return to: darktable's history position, plus the app-side
/// state that isn't in darktable's history.
struct UndoStep {
    let id: Int
    let label: String
    var end: Int?             // nil until the edits queued before it reach the engine
    let sdr: SDRVersion
    let styles: [String]
    let styleEnds: [Int]
    let editsSinceStyle: Int
}

/// Undo and redo step darktable's history position back and forward, as its
/// own history stack does; the next edit after an undo discards what's above.
/// A slider drag (changes to one module less than a second apart) is one step.
extension EditorModel {
    var undoTitle: String? { undoStack.last.map { "Undo \($0.label)" } }
    var redoTitle: String? { redoStack.last.map { "Redo \($0.label)" } }

    fileprivate func recordUndoStep(label: String, gesture: String? = nil, sdrBefore: SDRVersion? = nil) {
        guard url != nil, undoGroupDepth == 0, !restoringUndo else { return }
        // anything recordable is the user's own edit (opening a photo's defaults aren't)
        editedSinceOpen = true
        let now = ContinuousClock.now
        if let gesture, let last = lastGesture, last.key == gesture, now - last.time < .seconds(1) {
            lastGesture = (gesture, now)
            return
        }
        lastGesture = gesture.map { ($0, now) }
        nextUndoID += 1
        undoStack.append(snapshot(id: nextUndoID, label: label, end: nil, sdr: sdrBefore ?? sdrVersion))
        redoStack.removeAll()
        pendingCheckpoints.append((pendingSets.count, nextUndoID))
        pump()
    }

    fileprivate func resolveUndoStep(_ id: Int, end: Int) {
        if let i = undoStack.lastIndex(where: { $0.id == id }) { undoStack[i].end = end }
    }

    fileprivate func clearUndo() {
        undoStack.removeAll()
        redoStack.removeAll()
        pendingCheckpoints.removeAll()
        lastGesture = nil
    }

    /// Waits until queued edits have reached the engine (and with them any
    /// undo checkpoints), so a direct engine command lands after them.
    fileprivate func settleEdits() async {
        for _ in 0..<500 where pumping || !pendingSets.isEmpty || !pendingCheckpoints.isEmpty {
            if engine == nil { return }
            if !pumping { pump() }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private func snapshot(id: Int, label: String, end: Int?, sdr: SDRVersion) -> UndoStep {
        UndoStep(id: id, label: label, end: end, sdr: sdr, styles: appliedStyles,
                 styleEnds: styleHistoryEnds, editsSinceStyle: editsSinceStyle)
    }

    func undo() async { await step(back: true) }
    func redo() async { await step(back: false) }

    private func step(back: Bool) async {
        guard let engine, !restoringUndo, !(back ? undoStack : redoStack).isEmpty else { return }
        restoringUndo = true
        defer { restoringUndo = false }
        await settleEdits()
        guard let target = (back ? undoStack : redoStack).last, let end = target.end else { return }
        // where we are now becomes the step in the other direction
        let here = snapshot(id: target.id, label: target.label, end: await engine.historyEnd, sdr: sdrVersion)
        do {
            modules = try await engine.setHistoryEnd(end)
        } catch {
            errorMessage = "Couldn't \(back ? "undo" : "redo"): \(error.localizedDescription)"
            return
        }
        if back {
            undoStack.removeLast()
            redoStack.append(here)
        } else {
            redoStack.removeLast()
            undoStack.append(here)
        }
        sdrVersion = target.sdr
        appliedStyles = target.styles
        styleHistoryEnds = target.styleEnds
        editsSinceStyle = target.editsSinceStyle
        lastGesture = nil
        hasUnsavedChanges = true
        editedSinceOpen = true
        requestRender()
    }
}

// MARK: - Crop and straighten

/// Crop aspect ratios, as long side to short side.
enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, r5x4, r7x5, r3x2, r16x9

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Freeform"
        case .original: "Original"
        case .square: "Square"
        case .r5x4: "5:4"
        case .r7x5: "7:5"
        case .r3x2: "3:2"
        case .r16x9: "16:9"
        }
    }

    /// long side over short side; nil for freeform, and the photo's own for original
    func ratio(original: Double) -> Double? {
        switch self {
        case .free: nil
        case .original: original
        case .square: 1
        case .r5x4: 5.0 / 4
        case .r7x5: 7.0 / 5
        case .r3x2: 3.0 / 2
        case .r16x9: 16.0 / 9
        }
    }
}

/// Straighten is darktable's rotate and perspective module (ashift): its
/// rotation, with crop margins that keep the photo's shape and cut off the
/// corners rotation brings in, as its "original format" automatic cropping
/// would (that fit runs in darktable's interface, so it's worked out here).
/// The crop is darktable's crop module, which comes after it, so the crop is
/// relative to the straightened photo. While cropping, renders open the crop
/// out so the whole straightened photo shows under the crop box.
extension EditorModel {
    private var cropModule: EngineModule? { modules.first { $0.op == "crop" } }
    private var rotateModule: EngineModule? { modules.first { $0.op == "ashift" } }

    /// How far to turn the frame on screen, and how much to enlarge it so it
    /// still fills its frame: the instant preview while straightening.
    var straightenPreview: (degrees: Double, scale: Double) {
        let d = straighten - frameStraighten
        guard abs(d) > 0.001, let image else { return (0, 1) }
        let a = abs(d) * .pi / 180
        let (w, h) = (Double(image.width), Double(image.height))
        return (d, max(cos(a) + h / w * sin(a), w / h * sin(a) + cos(a)))
    }

    private func number(_ m: EngineModule?, _ field: String) -> Double? {
        m?.fields.first { $0.name == field }?.value.number
    }

    /// degrees; positive turns the photo anticlockwise, as darktable does
    var straighten: Double {
        guard let m = rotateModule, m.enabled else { return 0 }
        return number(m, "rotation") ?? 0
    }

    fileprivate var cropOverrides: [Engine.Override] {
        guard isCropping, let m = cropModule, m.enabled else { return [] }
        return [.init(module: m.key, field: "cx", value: 0), .init(module: m.key, field: "cy", value: 0),
                .init(module: m.key, field: "cw", value: 1), .init(module: m.key, field: "ch", value: 1)]
    }

    /// the straightened photo's full size in pixels while cropping
    var imageSizeForCrop: CGSize { imageSize }
    /// the straightened photo's aspect (width over height) while cropping
    var croppingImageAspect: Double { imageSize.width / max(imageSize.height, 1) }

    func beginCrop() {
        guard url != nil, !isCropping, !showingLibrary else { return }
        let crop = cropModule
        let enabled = crop?.enabled ?? false
        if enabled, let cx = number(crop, "cx"), let cy = number(crop, "cy"),
           let cw = number(crop, "cw"), let ch = number(crop, "ch"), cw > cx, ch > cy {
            cropRect = CGRect(x: cx, y: cy, width: cw - cx, height: ch - cy)
        } else {
            cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        cropStart = (straighten, cropRect, enabled)
        cropAspect = .free
        comparing = false
        zoom = .fit
        isCropping = true
        requestRender()
    }

    func commitCrop() {
        guard isCropping else { return }
        isCropping = false
        cropStart = nil
        let r = cropRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let full = r.width > 0.999 && r.height > 0.999
        if let m = cropModule {
            if full {
                if m.enabled { setEnabled(false, module: m.key) }
            } else {
                setValue(.number(r.minX), module: m.key, field: "cx")
                setValue(.number(r.minY), module: m.key, field: "cy")
                setValue(.number(r.maxX), module: m.key, field: "cw")
                setValue(.number(r.maxY), module: m.key, field: "ch")
            }
        }
        requestRender()
    }

    func cancelCrop() {
        guard isCropping, let start = cropStart else { return }
        isCropping = false
        cropStart = nil
        if abs(straighten - start.rotation) > 0.001 { setStraighten(start.rotation) }
        requestRender()
    }

    func resetCrop() {
        cropAspect = .free
        cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        if perspective != Perspective.Geometry() { setGeometry(.init()) }
    }

    /// rotation and perspective as darktable's rotate and perspective module holds them
    var perspective: Perspective.Geometry {
        guard let m = rotateModule, m.enabled else { return .init() }
        return .init(rotation: number(m, "rotation") ?? 0, vertical: number(m, "lensshift_v") ?? 0,
                     horizontal: number(m, "lensshift_h") ?? 0, shear: number(m, "shear") ?? 0)
    }

    /// Turns the photo by `degrees` and crops off the corners that brings in,
    /// keeping its shape and any perspective correction.
    func setStraighten(_ degrees: Double) {
        var g = perspective
        g.rotation = degrees
        setGeometry(g)
    }

    /// Sets rotation and perspective, with the crop margins darktable's
    /// "automatic cropping: original format" would fit: the largest rectangle
    /// of the photo's shape inside the corrected photo (Perspective.cropMargins).
    func setGeometry(_ g: Perspective.Geometry) {
        guard let m = rotateModule, let size = rotateInSize, size.width > 0, size.height > 0 else { return }
        let margins = Perspective.cropMargins(g, width: size.width, height: size.height)
        setValue(.number(g.rotation), module: m.key, field: "rotation")
        setValue(.number(g.vertical), module: m.key, field: "lensshift_v")
        setValue(.number(g.horizontal), module: m.key, field: "lensshift_h")
        setValue(.number(g.shear), module: m.key, field: "shear")
        setValue(.number(margins.cl), module: m.key, field: "cl")
        setValue(.number(margins.cr), module: m.key, field: "cr")
        setValue(.number(margins.ct), module: m.key, field: "ct")
        setValue(.number(margins.cb), module: m.key, field: "cb")
        setValue(.number(2), module: m.key, field: "cropmode")   // "original format", as computed here
    }

    /// The photo as darktable's rotate and perspective module receives it, for
    /// measuring: no rotation, perspective or crop, and no orientation flip
    /// (which comes after it), so what's found is in the module's own terms.
    private func renderUncorrected(_ engine: Engine) async -> CGImage? {
        var overrides: [Engine.Override] = []
        if let r = rotateModule, r.enabled {
            overrides += [("rotation", 0.0), ("lensshift_v", 0), ("lensshift_h", 0), ("shear", 0),
                          ("cl", 0), ("cr", 1), ("ct", 0), ("cb", 1)].map { .init(module: r.key, field: $0.0, value: $0.1) }
        }
        if let c = cropModule, c.enabled {
            overrides += [("cx", 0.0), ("cy", 0), ("cw", 1), ("ch", 1)].map { .init(module: c.key, field: $0.0, value: $0.1) }
        }
        if let f = modules.first(where: { $0.op == "flip" }), f.enabled {
            overrides.append(.init(module: f.key, field: "orientation", value: 0))   // ORIENTATION_NONE
        }
        return try? await engine.render(maxPixels: 1200, hdr: false, displayHeadroom: 1, wantOverlay: false,
                                        overrides: overrides).image
    }

    /// Like Lightroom's Upright "Vertical": the rotation and vertical
    /// perspective that make the photo's near-vertical lines vertical.
    func autoUpright() async {
        guard let engine, url != nil, let size = rotateInSize else { return }
        await settleEdits()
        guard let image = await renderUncorrected(engine) else { return }
        let fit = await Task.detached(priority: .userInitiated) { Perspective.fitUpright(image, inputSize: size) }.value
        guard let fit else {
            errorMessage = "Upright needs clear vertical lines, such as buildings, door frames or poles, and this photo hasn't enough of them, so it was left as it is."
            return
        }
        var g = perspective
        g.rotation = fit.rotation
        g.vertical = fit.vertical
        if g != perspective { setGeometry(g) }
    }

    /// Levels the photo, the way Lightroom's and Photomator's levelling do:
    /// from its straight lines (LevelDetector), or failing those from Vision's
    /// horizon detection. It always measures the same picture, the photo
    /// unrotated and uncropped at a fixed size, in one pass, so the answer
    /// depends only on the photo: pressing it again gives the same angle.
    func autoStraighten() async {
        guard let engine, url != nil else { return }
        await settleEdits()
        guard let image = await renderUncorrected(engine) else { return }
        let degrees = await Task.detached(priority: .userInitiated) { () -> Double? in
            if let tilt = LevelDetector.tilt(of: image) { return tilt }
            let request = VNDetectHorizonRequest()
            try? VNImageRequestHandler(cgImage: image).perform([request])
            return request.results?.first.map { Double($0.angle) * 180 / .pi }
        }.value
        guard let degrees else {
            errorMessage = "No horizon or straight lines found in this photo."
            return
        }
        // measured on the unrotated photo, so the tilt is the rotation that levels it
        let target = (degrees.clamped(to: -45...45) * 10).rounded() / 10
        if abs(target - straighten) >= 0.05 { setStraighten(target) }
    }

    /// Keeps the crop box's centre and fits the largest box of the chosen
    /// ratio inside it (or inside the photo, if it was full).
    func fitCropToAspect() {
        let imageAspect = croppingImageAspect
        guard let ratio = cropAspect.ratio(original: max(imageAspect, 1 / imageAspect)) else { return }
        let landscape = cropAspect == .original ? imageAspect >= 1 : !cropPortrait
        let target = landscape ? ratio : 1 / ratio        // width over height, in pixels
        let normalised = target / imageAspect             // width over height, in 0...1 units
        let r = cropRect
        var w = r.width, h = w / normalised
        if h > r.height { h = r.height; w = h * normalised }
        cropRect = CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    /// width over height of the crop box in 0...1 units, when a ratio is chosen
    var cropNormalisedRatio: Double? {
        let imageAspect = croppingImageAspect
        guard let ratio = cropAspect.ratio(original: max(imageAspect, 1 / imageAspect)) else { return nil }
        let landscape = cropAspect == .original ? imageAspect >= 1 : !cropPortrait
        return (landscape ? ratio : 1 / ratio) / imageAspect
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

// MARK: - Library

extension EditorModel {
    /// Before moving to another photo: finish any crop, save unsaved edits to
    /// the sidecar (as darktable and Lightroom do), and make the last render
    /// the photo's thumbnail if it was edited.
    fileprivate func leaveCurrentPhoto() async {
        guard let current = url else { return }
        if isCropping { commitCrop() }
        await settleEdits()
        // only the user's own edits are saved: a photo just looked at keeps no sidecar
        if editedSinceOpen, hasUnsavedChanges { await save() }
        if editedSinceOpen, let frame = thumbnailFrame {
            library.updateThumbnail(for: current, from: frame)
        }
        editedSinceOpen = false
        thumbnailFrame = nil
    }

    /// Anything dropped on the window or the Dock icon, or opened from Finder:
    /// a folder shows in the library, a photo opens, anything else is ignored.
    func openDropped(_ urls: [URL]) async {
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isFolder {
                showFolder(url.standardizedFileURL)
                return
            }
        }
        if let photo = urls.first(where: Library.isPhoto) { await open(photo) }
    }

    func showFolder(_ folder: URL) {
        library.show(folder: folder)
        showingLibrary = true
    }

    /// View › as Grid or as Map: the sidebar's Map has no grid, so asking
    /// for one goes back to the folder last shown
    func showLibrary(as mode: Library.ViewMode) {
        if mode == .grid, library.source == .map, let folder = library.lastFolder { library.show(folder: folder) }
        library.viewMode = mode
        if !showingLibrary { Task { await showLibrary() } }
    }

    /// Places a photo on the map, or takes it off with nil. The location goes
    /// in the photo's sidecar, through darktable, so its map view agrees.
    func setLocation(_ coordinate: CLLocationCoordinate2D?, for photo: URL) async {
        // a Photos photo is placed in Photos
        if let id = PhotosLibrary.assetID(photo) {
            do {
                try await PhotosLibrary.setLocation(coordinate, for: id)
                library.setLocation(coordinate, for: photo)
            } catch {
                errorMessage = "Couldn't place the photo: \(error.localizedDescription)"
            }
            return
        }
        guard let engine else { return }
        do {
            try await engine.setLocation(path: photo.path, latitude: coordinate?.latitude, longitude: coordinate?.longitude)
            library.setLocation(coordinate, for: photo)
        } catch {
            errorMessage = "Couldn't save the location of \(photo.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Places every photo in these folders that has no location, from a track
    /// of the iPhone photos in Photos and the folders' own located photos,
    /// within 30 minutes (LocationMatcher). For the MatchLocations launch argument.
    func matchLocations(in folders: [URL]) async {
        func log(_ s: String) { FileHandle.standardError.write("Develop match locations: \(s)\n".data(using: .utf8)!) }
        let exts: Set<String> = ["nef", "hif", "heic", "jpg", "jpeg", "dng"]
        let photos = folders.flatMap { f in
            ((try? FileManager.default.contentsOfDirectory(at: f, includingPropertiesForKeys: nil)) ?? [])
                .filter { exts.contains($0.pathExtension.lowercased()) }
        }
        let located = await Task.detached { Dictionary(uniqueKeysWithValues: photos.map { ($0, Library.locationOf($0)) }) }.value
        let unplaced = photos.filter { located[$0] ?? nil == nil }
        var dates: [URL: Date] = [:]
        for url in unplaced { if let d = LocationMatcher.captureDate(of: url, zone: .current, clockOffset: 0) { dates[url] = d } }
        guard let first = dates.values.min(), let last = dates.values.max() else { log("nothing to place among \(photos.count)"); return }
        do {
            let phone = try await LocationMatcher.photosLibraryTrack(from: first - 86_400, to: last + 86_400)
            let own = LocationMatcher.photosTrack(photos.compactMap { u in located[u].flatMap { $0 }.map { (u, $0) } }, zone: .current)
            let track = (phone + own).sorted { $0.date < $1.date }
            let matches = LocationMatcher.match(dates, track: track, maxGap: 30 * 60)
            log("\(photos.count) photos, \(unplaced.count) without a location, track of \(phone.count) iPhone and \(own.count) camera points, \(matches.count) matched")
            for (url, m) in matches.sorted(by: { $0.key.path < $1.key.path }) { await setLocation(m.coordinate, for: url) }
            let gaps = matches.values.map(\.gap).sorted()
            if !gaps.isEmpty { log("gaps: median \(Int(gaps[gaps.count / 2])) s, longest \(Int(gaps.last!)) s") }
            let byDay = Dictionary(grouping: unplaced) { $0.deletingLastPathComponent().lastPathComponent }
            for (day, list) in byDay.sorted(by: { $0.key < $1.key }) {
                log("\(day): \(list.filter { matches[$0] != nil }.count) of \(list.count) placed")
            }
        } catch {
            log("failed: \(error.localizedDescription)")
        }
    }

    /// Sets a photo's title, caption, keywords or rating in its sidecar, through darktable.
    func setInfo(_ photo: URL, title: String? = nil, caption: String? = nil, addKeyword: String? = nil,
                 removeKeyword: String? = nil, rating: Int? = nil) async {
        guard let engine else { return }
        do {
            try await engine.setInfo(path: photo.path, title: title, caption: caption, addKeyword: addKeyword,
                                     removeKeyword: removeKeyword, rating: rating)
            library.noteEdited(photo)
            infoRevision += 1
        } catch {
            errorMessage = "Couldn't save to \(photo.lastPathComponent)'s sidecar: \(error.localizedDescription)"
        }
    }

    func showSource(_ source: LibrarySource) {
        library.show(source)
        if !showingLibrary { Task { await showLibrary() } }
    }

    /// the next or previous photo in the folder
    func openNeighbour(_ offset: Int) async {
        guard let next = library.neighbour(of: libraryURL, offset: offset) else { return }
        await open(next)
    }

    func toggleLibrary() {
        // after a relaunch, the last folder is still there to go back to
        if library.source == nil, let folder = library.lastFolder { library.show(folder: folder) }
        guard library.source != nil else { return }
        if showingLibrary {
            if url != nil { showingLibrary = false }
        } else {
            Task { await showLibrary() }
        }
    }

    func showLibrary() async {
        // the grid shows this photo's latest look
        if let current = url, editedSinceOpen, let frame = thumbnailFrame {
            library.updateThumbnail(for: current, from: frame)
        }
        if isCropping { commitCrop() }
        showingLibrary = true
    }
}

// MARK: - Raw decoder choice

/// Which decoder reads a raw: darktable's (rawspeed, then LibRaw), or
/// Apple's raw engine at a given version (nil, the newest). Kept per photo.
enum RawDecoderChoice: Hashable {
    case darktable
    case apple(String?)

    private static let key = "RawDecoders"

    static func stored(for photo: URL) -> RawDecoderChoice {
        guard let value = (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[photo.path] else { return .darktable }
        if value == "darktable" { return .darktable }
        let version = value.dropFirst("apple:".count)
        return .apple(version.isEmpty ? nil : String(version))
    }

    func store(for photo: URL) {
        var all = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        switch self {
        case .darktable: all[photo.path] = nil
        case .apple(let v): all[photo.path] = "apple:" + (v ?? "")
        }
        UserDefaults.standard.set(all, forKey: Self.key)
    }
}

extension EditorModel {
    fileprivate func openWithApple(_ url: URL, version: String?, engine: Engine) async throws -> OpenReply {
        statusNote = "Decoding with macOS…"
        defer { statusNote = nil }
        let decoded = try await Task.detached(priority: .userInitiated) {
            try AppleRawFallback.decodedTIFF(for: url, version: version)
        }.value
        AppleRawFallback.sidecarToDecoded(original: url, decoded: decoded.url, raw: true)
        let reply = try await engine.open(decoded.url, hdrSource: true)
        decodedTIFF = decoded.url
        decoderInUse = AppleRawFallback.versionName(decoded.version)
        openedAsHDR = true
        return reply
    }

    var rawDecoderChoice: RawDecoderChoice {
        guard let url else { return .darktable }
        return RawDecoderChoice.stored(for: url)
    }

    /// Image › Raw Decoder: saves any edits, then reopens the photo with the decoder chosen.
    func setRawDecoder(_ choice: RawDecoderChoice) async {
        guard let photo = url, choice != rawDecoderChoice else { return }
        await settleEdits()
        if hasUnsavedChanges { await save() }
        choice.store(for: photo)
        await reopen()
    }
}

// MARK: - Curves

extension EditorModel {
    /// While the curve editor shows an rgb curve that's off, the preview runs
    /// it as it is (a flat curve changes nothing) so its input histogram is
    /// collected; that's not an edit.
    fileprivate var curveOverrides: [Engine.Override] {
        guard let key = curveEditorModule, let m = modules.first(where: { $0.key == key }), !m.enabled else { return [] }
        return [Engine.Override(module: key, field: "", value: 0, enable: true)]
    }

    /// The red, green and blue curves live in a second rgb curve instance
    /// named "channels", in independent-channel mode, right after the linked
    /// RGB curve: darktable's rgb curve holds either one linked curve or three
    /// separate ones, and Photomator-style editing wants both. It's shown as
    /// part of the RGB curve card, not as a module of its own.
    nonisolated static let channelCurveName = "channels"
    nonisolated static func isChannelCurve(_ m: EngineModule) -> Bool {
        m.op == "rgbcurve" && m.instanceName == channelCurveName
    }
    var channelCurveModule: EngineModule? { modules.first(where: Self.isChannelCurve) }

    /// A red, green or blue curve edit (channel 0, 1 or 2). The channel
    /// instance is made on the first edit; points arriving while it's being
    /// made are kept and the latest applied once it exists.
    func setChannelCurve(base key: String, channel: Int, nodes: [CGPoint]) {
        if let m = channelCurveModule {
            setCurve(module: m.key, channel: channel, nodes: nodes, linked: false)
            return
        }
        stashedChannelCurve = (channel, nodes)
        guard !creatingChannelCurve, let engine else { return }
        creatingChannelCurve = true
        Task {
            defer { creatingChannelCurve = false }
            await settleEdits()
            recordUndoStep(label: "RGB curve")
            do {
                let reply = try await engine.addInstance(of: key, name: Self.channelCurveName)
                modules = reply.modules
                curveEditorModule = reply.added
                if let (c, n) = stashedChannelCurve {
                    stashedChannelCurve = nil
                    setCurve(module: reply.added, channel: c, nodes: n, linked: false)
                }
            } catch {
                errorMessage = "Couldn't add the colour curves: \(error.localizedDescription)"
            }
        }
    }

    /// A curve edit from the editor: shown at once, sent with the next render,
    /// one undo step per drag.
    func setCurve(module key: String, channel: Int, nodes: [CGPoint], linked: Bool = true) {
        guard let m = modules.firstIndex(where: { $0.key == key }) else { return }
        recordUndoStep(label: Presentation.title(of: modules[m]), gesture: key)
        // only what changes is set, so a drag doesn't redraw the whole inspector each step
        if editsSinceStyle == 0 { editsSinceStyle = 1 }
        if !modules[m].enabled { modules[m].enabled = true }
        if !hasUnsavedChanges { hasUnsavedChanges = true }
        if curveInfoKey == key, var info = curveInfo {
            var nodesByChannel = info.nodes
            if nodesByChannel.indices.contains(channel) { nodesByChannel[channel] = nodes.map { [Double($0.x), Double($0.y)] } }
            info = Engine.CurveReply(enabled: true, compensated: true, linked: linked, nodes: nodesByChannel,
                                     histogram: info.histogram, channels: info.channels)
            curveInfo = info
        }
        pendingCurve = (key, channel, nodes, linked)
        requestRender()
    }
}

extension EditorModel {
    nonisolated static func readLens(_ url: URL) -> LensInfo {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return LensInfo() }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let model = (exif[kCGImagePropertyExifLensModel] as? String ?? aux[kCGImagePropertyExifAuxLensModel] as? String)?
            .trimmingCharacters(in: .whitespaces)
        // MaxApertureValue is APEX: ƒ = √2 ^ value
        let apex = exif[kCGImagePropertyExifMaxApertureValue] as? Double
        return LensInfo(model: model?.isEmpty == false ? model : nil,
                        focal: exif[kCGImagePropertyExifFocalLength] as? Double,
                        maxAperture: apex.map { pow(2.0.squareRoot(), $0) })
    }
}

// MARK: - Local adjustments

/// A local adjustment's shape in output pixels (the photo as processed, at
/// full size): see LocalAdjustments.swift for how it's drawn and edited.
struct LocalShape: Equatable {
    enum Kind { case gradient, ellipse, subject }
    let kind: Kind
    /// a subject's outlines, traced from Vision's mask (it has no handles)
    var outlines: [[CGPoint]] = []
    /// gradient: anchor, a point along the line, the side it fades in toward,
    /// and the two edges of its transition. Ellipse: 64 points of its outline,
    /// 64 of its outline with the border, then its centre and the ends of its
    /// two radii.
    var points: [CGPoint]
    var compression = 0.3
    var border = 0.5
}

/// A move of a shape, in output pixels, waiting to go to the engine.
enum ShapeEdit {
    case gradient(anchor: CGPoint, toward: CGPoint, compression: Double?)
    case ellipse(center: CGPoint, a: CGPoint, b: CGPoint, border: Double?)
}

extension EditorModel {
    /// Local adjustments are instances of exposure named "Local n", each
    /// masked by one drawn shape (the engine's add_local). They're edited in
    /// their own card, not as modules.
    nonisolated static func isLocal(_ m: EngineModule) -> Bool { m.instanceName.hasPrefix("Local ") }
    var localAdjustments: [EngineModule] { modules.filter(Self.isLocal).sorted { $0.instanceName < $1.instanceName } }

    func addLocal(_ kind: LocalShape.Kind) {
        guard let engine, url != nil,
              let base = modules.first(where: { $0.op == "exposure" && !Self.isLocal($0) }) else { return }
        let used = Set(localAdjustments.map(\.instanceName))
        let name = (1...).lazy.map { "Local \($0)" }.first { !used.contains($0) }!
        Task {
            await settleEdits()
            recordUndoStep(label: "Add \(kind == .gradient ? "Linear Gradient" : "Radial Gradient")")
            do {
                let reply = try await engine.addLocal(base: base.key, shape: kind == .gradient ? "gradient" : "ellipse", name: name)
                modules = reply.modules
                hasUnsavedChanges = true
                // start where it's easy to see and grab: a gradient across the
                // middle brightening the top half, a circle in the centre
                let w = imageSize.width, h = imageSize.height
                let c = CGPoint(x: w / 2, y: h / 2)
                switch kind {
                case .gradient:
                    try await engine.setGradient(module: reply.added, anchor: c, toward: CGPoint(x: c.x, y: c.y - h * 0.2), compression: 0.15)
                case .ellipse:
                    let r = min(w, h) * 0.25
                    try await engine.setEllipse(module: reply.added, center: c, a: CGPoint(x: c.x + r, y: c.y),
                                                b: CGPoint(x: c.x, y: c.y + r), border: 0.5)
                case .subject:
                    break   // addSubject
                }
                selectedLocal = reply.added
                requestRender()
            } catch {
                errorMessage = "Couldn't add the adjustment: \(error.localizedDescription)"
            }
        }
    }

    /// A local adjustment masked to the photo's subject, which Apple's Vision
    /// finds (the subject lifting Photos and Preview use): every foreground
    /// thing it picks out, people, animals or objects. It runs on a render of
    /// the photo as it looks now; the engine traces the mask into darktable
    /// paths, so the edit stays darktable's own and exports anywhere.
    func addSubject() {
        guard let engine, url != nil,
              let base = modules.first(where: { $0.op == "exposure" && !Self.isLocal($0) }) else { return }
        let used = Set(localAdjustments.map(\.instanceName))
        let name = (1...).lazy.map { "Local \($0)" }.first { !used.contains($0) }!
        Task {
            await settleEdits()
            isFindingSubject = true
            defer { isFindingSubject = false }
            do {
                let frame = try await engine.render(maxPixels: 2048, hdr: false, displayHeadroom: 1, wantOverlay: false)
                requestRender()
                guard let mask = try await Task.detached(priority: .userInitiated, operation: { try SubjectMask.find(in: frame.image) }).value else {
                    errorMessage = "No subject found in this photo. Vision looks for people, animals and objects that stand out from their background; try a radial gradient instead."
                    return
                }
                recordUndoStep(label: "Add Subject")
                let reply = try await engine.addSubject(base: base.key, name: name, mask: mask.file,
                                                        width: mask.width, height: mask.height)
                try? FileManager.default.removeItem(at: mask.file)
                modules = reply.modules
                hasUnsavedChanges = true
                selectedLocal = reply.added
                requestRender()
            } catch {
                errorMessage = "Couldn't select the subject: \(error.localizedDescription)"
            }
        }
    }

    /// darktable's instance removal is interface code, so a deleted local
    /// adjustment is switched off and renamed out of sight; undo brings it back
    nonisolated static let deletedLocalName = "Deleted local"

    func deleteLocal(_ key: String) {
        guard let engine else { return }
        if selectedLocal == key { selectedLocal = nil }
        Task {
            await settleEdits()
            recordUndoStep(label: "Delete Local Adjustment")
            do {
                try await engine.enable(module: key, on: false)
                modules = try await engine.renameInstance(key, to: Self.deletedLocalName)
                hasUnsavedChanges = true
                requestRender()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func fetchLocalShape() async {
        guard let engine, let key = selectedLocal, let r = try? await engine.shape(module: key) else { return }
        let pts = stride(from: 0, to: r.points.count - 1, by: 2).map { CGPoint(x: r.points[$0], y: r.points[$0 + 1]) }
        guard selectedLocal == key, pendingShape == nil, !sendingShape else { return }
        let kind: LocalShape.Kind = switch r.kind { case "ellipse": .ellipse; case "subject": .subject; default: .gradient }
        let outlines = (r.outlines ?? []).map { o in stride(from: 0, to: o.count - 1, by: 2).map { CGPoint(x: o[$0], y: o[$0 + 1]) } }
        localShape = LocalShape(kind: kind, outlines: outlines, points: pts,
                                compression: r.compression ?? 0.3, border: r.border ?? 0.5)
    }

    /// A drag on the shape: only the latest goes to the engine, then a render.
    func moveShape(_ edit: ShapeEdit) {
        guard let key = selectedLocal, let engine else { return }
        recordUndoStep(label: "Move Mask", gesture: "shape:\(key)")
        hasUnsavedChanges = true
        pendingShape = edit
        guard !sendingShape else { return }
        sendingShape = true
        Task {
            defer { sendingShape = false }
            await settleEdits()
            while let e = pendingShape {
                pendingShape = nil
                switch e {
                case let .gradient(anchor, toward, compression):
                    try? await engine.setGradient(module: key, anchor: anchor, toward: toward, compression: compression)
                case let .ellipse(center, a, b, border):
                    try? await engine.setEllipse(module: key, center: center, a: a, b: b, border: border)
                }
                requestRender()
            }
        }
    }
}

// MARK: - Presets and instances

extension EditorModel {
    func presets(for op: String) -> [Engine.PresetInfo] { presetList.filter { $0.op == op } }

    func loadPresets() async {
        guard let engine else { return }
        presetList = (try? await engine.presets()) ?? []
    }

    func applyPreset(_ preset: Engine.PresetInfo, module: String) {
        guard let engine else { return }
        Task {
            await settleEdits()
            recordUndoStep(label: "Apply \(preset.title)")
            do {
                modules = try await engine.applyPreset(preset.name, module: module)
                hasUnsavedChanges = true
                requestRender()
            } catch {
                errorMessage = "Couldn't apply \(preset.title): \(error.localizedDescription)"
            }
        }
    }

    func savePreset(named name: String, module: String) {
        guard let engine, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            await settleEdits()
            do {
                try await engine.savePreset(name.trimmingCharacters(in: .whitespaces), module: module)
                await loadPresets()
            } catch {
                errorMessage = "Couldn't save the preset: \(error.localizedDescription)"
            }
        }
    }

    func deletePreset(_ preset: Engine.PresetInfo) {
        guard let engine, !preset.builtin else { return }
        Task {
            try? await engine.deletePreset(preset.name, op: preset.op)
            await loadPresets()
        }
    }

    /// another instance of a module, after it and at its defaults, as
    /// darktable's "new instance"; it opens ready to edit
    func newInstance(of key: String) {
        guard let engine else { return }
        Task {
            await settleEdits()
            recordUndoStep(label: "New Instance")
            do {
                let reply = try await engine.addInstance(of: key, name: "")
                modules = reply.modules
                expanded.insert(reply.added)
                hasUnsavedChanges = true
                requestRender()
            } catch {
                errorMessage = "Couldn't add an instance: \(error.localizedDescription)"
            }
        }
    }

    /// as with local adjustments, deleting switches the instance off and
    /// renames it out of sight (darktable's removal is interface code)
    nonisolated static let deletedInstanceName = "Deleted instance"
    /// the engine's own exposure instance placing an HDR source's white for
    /// an HDR profile (helper.c _sync_hdr_white); never shown or copied
    nonisolated static let hdrWhiteName = "HDR white"

    func deleteInstance(_ key: String) {
        guard let engine else { return }
        Task {
            await settleEdits()
            recordUndoStep(label: "Delete Instance")
            do {
                try await engine.enable(module: key, on: false)
                modules = try await engine.renameInstance(key, to: Self.deletedInstanceName)
                hasUnsavedChanges = true
                requestRender()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Film looks

extension EditorModel {
    func loadLook() async {
        if filmLooks.isEmpty, let lutFolder { filmLooks = FilmLook.scan(lutFolder) }
        guard let engine, url != nil, let r = try? await engine.look(folder: lutFolder?.path, file: nil, strength: nil) else { return }
        currentLook = r.file.isEmpty ? nil : r.file
        lookStrength = r.strength
    }

    /// the photo as it is without its look, small, for the browser's previews
    func loadLookPreviewBase() async {
        guard let engine, url != nil else { return }
        await settleEdits()
        var overrides: [Engine.Override] = []
        if let lut = modules.first(where: { $0.op == "lut3d" && $0.key.hasSuffix(":0") }), lut.enabled {
            overrides.append(.init(module: lut.key, field: "", value: 0, disable: true))
        }
        if let frame = try? await engine.render(maxPixels: 280, hdr: false, displayHeadroom: 1, wantOverlay: false,
                                                overrides: overrides) {
            lookPreviewBase = frame.image
            lookPreviewBaseID += 1
        }
    }

    func toggleFavourite(_ film: Film) {
        if favouriteLooks.contains(film.id) { favouriteLooks.remove(film.id) } else { favouriteLooks.insert(film.id) }
    }

    /// applies a film look, or none, as one edit; a new look starts at full strength
    func applyLook(_ look: FilmLook?) {
        guard let engine else { return }
        Task {
            await settleEdits()
            recordUndoStep(label: look.map { "Film Look \($0.title)" } ?? "No Film Look")
            do {
                let r = try await engine.look(folder: lutFolder?.path, file: look?.path ?? "",
                                              strength: look == nil ? nil : (currentLook == nil ? 100 : lookStrength))
                modules = r.modules
                currentLook = r.file.isEmpty ? nil : r.file
                lookStrength = r.strength
                hasUnsavedChanges = true
                requestRender()
            } catch {
                errorMessage = "Couldn't apply the look: \(error.localizedDescription)"
            }
        }
    }

    /// the strength slider: only the latest value goes to the engine
    func setLookStrength(_ v: Double) {
        guard let engine, currentLook != nil else { return }
        lookStrength = v
        recordUndoStep(label: "Film Look Strength", gesture: "lookStrength")
        hasUnsavedChanges = true
        pendingLookStrength = v
        guard !sendingLook else { return }
        sendingLook = true
        Task {
            defer { sendingLook = false }
            await settleEdits()
            while let s = pendingLookStrength {
                pendingLookStrength = nil
                _ = try? await engine.look(folder: nil, file: nil, strength: s)
                requestRender()
            }
        }
    }
}

// MARK: - Renaming

extension EditorModel {
    /// Renames the open photo from the window title: saves its edit, moves the
    /// file with darktable's sidecar and any Apple-decode one, and reopens it.
    /// The extension stays if it's left off.
    func renamePhoto(to newName: String) {
        // a Photos original is a cache copy; Photos keeps its own name
        guard let current = url, photosAsset == nil else { return }
        var name = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: ":")
        guard !name.isEmpty, name != current.lastPathComponent else { return }
        if (name as NSString).pathExtension.lowercased() != current.pathExtension.lowercased() {
            name += "." + current.pathExtension
        }
        let target = current.deletingLastPathComponent().appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            errorMessage = "There's already a file called \(name) in this folder."
            return
        }
        Task {
            await leaveCurrentPhoto()
            do {
                try FileManager.default.moveItem(at: current, to: target)
                for suffix in [".xmp", ".apple.xmp"] {
                    let side = URL(fileURLWithPath: current.path + suffix)
                    if FileManager.default.fileExists(atPath: side.path) {
                        try? FileManager.default.moveItem(at: side, to: URL(fileURLWithPath: target.path + suffix))
                    }
                }
            } catch {
                errorMessage = "Couldn't rename \(current.lastPathComponent): \(error.localizedDescription)"
                return
            }
            reopening = true
            defer { reopening = false }
            await open(target)
        }
    }
}

// MARK: - Copy and paste adjustments

/// Adjustments copied from a photo: all of them, or chosen modules (keys).
struct CopiedAdjustments {
    let source: URL
    let modules: [String]?
    let summary: String
}

extension EditorModel {
    /// Modules darktable doesn't copy between photos unless asked, as they
    /// belong to the photo: white balance, lens, orientation, raw preparation.
    nonisolated static let photoSpecificOps: Set<String> = ["rawprepare", "temperature", "lens", "flip", "gamma",
                                                           "scalepixels", "rotatepixels", "mask_manager"]

    /// the photo adjustments are copied from: the open one, or the library's selection
    var copySource: URL? { showingLibrary ? library.selection : url }

    /// where Paste puts them: the open photo, or the library's selection
    var pasteTargets: [URL] {
        if showingLibrary { return library.selectedInOrder }
        return url.map { [$0] } ?? []
    }

    var canPaste: Bool {
        guard let copied = copiedAdjustments else { return false }
        return !pasteTargets.isEmpty && pasteTargets != [copied.source]
    }

    /// the edit's adjustments that could be copied, for Copy Some Adjustments
    var copyableModules: [EngineModule] {
        modules.filter { $0.enabled && $0.inHistory && $0.instanceName != Self.deletedLocalName
            && $0.instanceName != Self.deletedInstanceName && $0.instanceName != Self.hdrWhiteName }
    }

    func copyAdjustments() {
        if let source = copySource { copyAdjustments(from: source) }
    }

    func copyAdjustments(from source: URL) {
        Task {
            await settleEdits()
            copiedAdjustments = CopiedAdjustments(source: source, modules: nil,
                                                  summary: "the adjustments of \(source.lastPathComponent)")
        }
    }

    func copyAdjustments(_ keys: [String]) {
        guard let source = url, !keys.isEmpty else { return }
        Task {
            await settleEdits()
            copiedAdjustments = CopiedAdjustments(source: source, modules: keys,
                                                  summary: "\(keys.count) adjustment\(keys.count == 1 ? "" : "s") from \(source.lastPathComponent)")
        }
    }

    func pasteAdjustments() { pasteAdjustments(onto: pasteTargets) }

    func pasteAdjustments(onto chosen: [URL]) {
        guard let engine, let copied = copiedAdjustments else { return }
        let targets = chosen.filter { $0 != copied.source }
        guard !targets.isEmpty else { return }
        Task {
            await settleEdits()
            let intoOpen = url.map(targets.contains) ?? false
            if intoOpen {
                recordUndoStep(label: "Paste Adjustments")
                // the step takes its history position from the engine; let it,
                // before the paste moves that position on
                await settleEdits()
            }
            do {
                let reply = try await engine.paste(from: copied.source, modules: copied.modules, onto: targets)
                if let m = reply.modules {
                    modules = m
                    hasUnsavedChanges = true
                    editedSinceOpen = true
                    requestRender()
                }
                if reply.pasted == 0 { errorMessage = "Nothing was pasted: \(copied.summary) didn't include anything to paste." }
            } catch {
                errorMessage = "Couldn't paste: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Apple Photos

extension EditorModel {
    /// shows Apple Photos (All Photos, an album or Places), asking for access the first time
    func showPhotos(_ source: LibrarySource) {
        Task {
            guard await PhotosLibrary.authorise() else {
                errorMessage = "Develop needs access to Photos: allow it in System Settings › Privacy & Security › Photos."
                return
            }
            if photosAlbums.isEmpty { loadPhotosAlbums() }
            showSource(source)
        }
    }

    /// off the main thread: a library with hundreds of albums takes a moment
    func loadPhotosAlbums() {
        guard PhotosLibrary.authorised else { return }
        Task {
            photosAlbums = await Task.detached(priority: .userInitiated) { PhotosLibrary.albums() }.value
        }
    }

    /// Saves the edit to Photos as its edit of the original: a rendering in
    /// the type Photos asks for (a JPEG with an HDR gain map for an HDR edit),
    /// with the darktable edit inside, so it can be reopened here as it was.
    func saveToPhotos() {
        guard let engine, let id = photosAsset, url != nil else { return }
        Task {
            isSavingToPhotos = true
            defer { isSavingToPhotos = false }
            await settleEdits()
            await save()
            guard let file = url, let xmp = try? Data(contentsOf: URL(fileURLWithPath: file.path + ".xmp")) else {
                errorMessage = "Couldn't read the edit to save it to Photos."
                return
            }
            do {
                let target = try await PhotosLibrary.renderedType(for: id)
                let supported = target.output.supportedRenderedContentTypes
                var settings = ExportSettings()
                settings.longEdge = 0
                settings.profile = .fromEdit
                settings.quality = 92
                var destination = target.url
                if exportTarget.isHDR, supported.contains(.jpeg) {
                    // HDR: a JPEG with a gain map, which Photos shows in HDR
                    destination = try target.output.renderedContentURL(for: .jpeg)
                    settings.format = .jpegGainMap
                    settings.bitDepth = 8
                    try await exportGainMapJPEG(settings, to: destination, engine: engine)
                } else if target.type.conforms(to: .heic) {
                    settings.format = .heif
                    settings.bitDepth = 8
                    try await exportThroughCoreImage(settings, to: destination, engine: engine)
                } else if openedAsHDR {
                    settings.format = .jpeg
                    settings.bitDepth = 8
                    try await exportThroughCoreImage(settings, to: destination, engine: engine)
                } else {
                    let written = try await engine.export(
                        path: destination.deletingPathExtension().path, format: "jpeg",
                        quality: settings.quality, bitDepth: 8, maxEdge: 0, profile: nil)
                    if written != destination {
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: written, to: destination)
                    }
                }
                try await PhotosLibrary.commit(target.output, for: id, xmp: xmp)
                statusNote = "Saved to Photos"
                Task { try? await Task.sleep(for: .seconds(2)); if statusNote == "Saved to Photos" { statusNote = nil } }
                library.rescan()
            } catch {
                errorMessage = "Couldn't save to Photos: \(error.localizedDescription)"
            }
        }
    }
}
