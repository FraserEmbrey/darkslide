import CryptoKit
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
    /// raws: the camera's matrices, for white balance in temperature and tint
    private(set) var cameraWhite: CameraWhite?
    /// local sliders moved before their module's instance was added
    private var pendingLocalValues: [String: (LocalControl, Double)] = [:]
    private var addingLocalPart: Set<String> = []
    /// the white balance module being picked for (WhitePicker), and what went wrong
    var whitePickTarget: String?
    var whitePickNote: String?
    var whitePickTask: Task<Void, Never>?
    private(set) var image: CGImage?

    // Before and after: the photo as opened on the left of a movable divider
    // StartComparing: launch argument (-StartComparing YES) for testing
    var comparing = UserDefaults.standard.bool(forKey: "StartComparing") {
        didSet {
            guard comparing != oldValue, url != nil else { return }
            if comparing { requestRender(); return }
            // the before renders are freed in the engine until the next compare
            beforeImage = nil
            beforeKey = ""
            if let engine { Task { try? await engine.dropBefore() } }
        }
    }
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
    private(set) var modules: [EngineModule] = [] {
        // an adjustment that's gone (Reset All, undo, deleted) isn't selected any more
        didSet {
            if let key = selectedLocal, !modules.contains(where: { $0.key == key && Self.isLocal($0) }) { selectedLocal = nil }
        }
    }
    private(set) var hasUnsavedChanges = false

    private static var testLibraryRan = false
    private static var appleRawTested = false
    private static var autoExportTested = false
    private static var hdrMatchTested = false
    private static var decoderSwitchTested = false
    private static var versionsTested = false
    private static var smartAlbumsTested = false
    private static var exportPresetTested = false
    private static var shortcutsTested = false
    private static var spotsTested = false
    private static var stacksTested = false
    private static var removeObjectsTested = false
    private static var autoStackTested = false
    private static var brushTested = false
    private static var compareTested = false
    private static var penBrushTested = false
    private static var localNamesTested = false
    private static var brushPreviewTested = false
    private static var loupeTested = false

    /// for testing: how far apart two frames are, as the largest difference
    /// in any channel, 0...1 (nil if they can't be compared)
    private static func pixelDifference(_ a: CGImage?, _ b: CGImage?) -> Double? {
        guard let a, let b, a.width == b.width, a.height == b.height else { return nil }
        func floats(_ i: CGImage) -> [Float] {
            var px = [Float](repeating: 0, count: i.width * i.height * 4)
            let ctx = CGContext(data: &px, width: i.width, height: i.height, bitsPerComponent: 32, bytesPerRow: i.width * 16,
                                space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue)
            ctx?.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
            return px
        }
        return Double(zip(floats(a), floats(b)).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) })
    }
    private static var fullScreenTested = false

    /// when darktable couldn't decode the raw: the TIFF macOS decoded it to,
    /// which darktable is editing (see AppleRawFallback)
    private(set) var decodedTIFF: URL?
    /// the photo held HDR (a gain map, HLG or PQ) and was opened with it
    private(set) var openedAsHDR = false
    /// the photo opened with an edit in its sidecar, not yet reset
    private var openedWithEdit = false
    /// Reset is for photos with something to reset: an edit from the sidecar,
    /// or edits since opening (the new-photo defaults don't count)
    var canReset: Bool { url != nil && (openedWithEdit || !undoStack.isEmpty || !cleanUpMarks.isEmpty) }
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
    /// the Apple raw engine's controls for the open photo, when it decoded it (else empty)
    private(set) var appleRawControls: [AppleRawControl] = []
    /// the photo's changes to them, and the decoder's lens correction default (nil if none)
    private(set) var appleRawSettings = AppleRawSettings()
    private(set) var appleRawLensDefault: Bool?
    @ObservationIgnored private var appleRawDecode: Task<Void, Never>?
    /// Apple raw engine versions offered for the open raw, newest first
    private(set) var appleDecoderVersions: [String] = []
    private(set) var canDecodeWithApple = false
    /// a passing note for the window's subtitle
    var statusNote: String?
    /// Auto-Stack is finding bursts
    var isAutoStacking = false

    // Library (see the Library extension at the end)
    let library = Library(catalog: Catalog())
    /// culling the library's photos: measurements, bursts, big previews
    let culling = Culling()
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
    /// how the camera focused, from its maker note (Nikon)
    private(set) var cameraFocus: CameraFocus?
    /// View › Show Focus Point: the AF area drawn on the photo, as NX Studio does
    var showFocusPoint = UserDefaults.standard.bool(forKey: "ShowFocusPoint") {
        didSet {
            UserDefaults.standard.set(showFocusPoint, forKey: "ShowFocusPoint")
            if showFocusPoint { Task { await fetchFocusOutline() } } else { focusOutline = nil }
        }
    }
    /// the AF area's corners in output pixels, through the edit's crop and rotation
    private(set) var focusOutline: [CGPoint]?
    /// the photo has an AF area that can be drawn on it
    private(set) var canShowFocusPoint = false
    /// Vision is looking for the subject
    var isFindingSubject = false
    /// Full screen editing, as Aperture's (F): the photo on black, the
    /// adjustments in a HUD (H), the filmstrip from the bottom edge
    var isFullScreenEditor = false
    var showHUD = UserDefaults.standard.object(forKey: "ShowHUD") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showHUD, forKey: "ShowHUD") }
    }

    /// The loupe (`), as Aperture's: a lens following the pointer, at 100%
    /// (or `loupeZoom`) of the photo as edited. Its centre is in output pixels.
    // StartLoupe: launch argument (-StartLoupe YES) for testing: opens with the loupe on
    var showLoupe = UserDefaults.standard.bool(forKey: "StartLoupe") {
        didSet { if !showLoupe { loupeCenter = nil; loupeImage = nil; loupeCovers = nil } }
    }
    var loupeZoom = UserDefaults.standard.object(forKey: "LoupeZoom") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(loupeZoom, forKey: "LoupeZoom"); if loupeCenter != nil { loupeDirty = true; pump() } }
    }
    /// pixels rendered for it: the lens is 440 on a Retina display, and the rest
    /// keeps it covered as the pointer moves, until the next render arrives
    static let loupeSide = 960
    private(set) var loupeCenter: CGPoint?
    /// the grid thumbnail the loupe is over
    var loupeItem: URL?
    private(set) var loupeImage: CGImage?
    /// where the loupe's image starts on the output, so the lens lines up as the pointer moves
    private(set) var loupeOrigin: CGPoint = .zero
    private var loupeDirty = false
    /// what the loupe's image covers, in output pixels, and at which zoom
    private var loupeCovers: (rect: CGRect, zoom: Double)?

    /// a Quick Brush chosen, waiting for its first stroke to make its adjustment
    var pendingBrush: QuickBrush?
    /// the brush, as a fraction of the photo's shorter side, and how soft its edge is
    var brushSize = UserDefaults.standard.object(forKey: "BrushSize") as? Double ?? 0.04 {
        didSet { UserDefaults.standard.set(brushSize, forKey: "BrushSize") }
    }
    var brushSoftness = UserDefaults.standard.object(forKey: "BrushSoftness") as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(brushSoftness, forKey: "BrushSoftness") }
    }
    /// strokes take the adjustment away (Option does it for one stroke)
    var brushErases = false
    /// the frame as the stroke being painted will make it, and where it sits
    /// on the output (see BrushPreview)
    private(set) var brushPreview: (image: CGImage, origin: CGPoint, size: CGSize)?
    /// the brushed adjustment's strokes tinted red on the photo, as Aperture's
    /// overlay could; off, the photo shows only the adjustment
    var showBrushMask = UserDefaults.standard.bool(forKey: "ShowBrushMask") {
        didSet { UserDefaults.standard.set(showBrushMask, forKey: "ShowBrushMask") }
    }
    /// what a pen's pressure changes as it paints (a mouse or trackpad paints at full strength)
    var penPressure = BrushPressure(rawValue: UserDefaults.standard.string(forKey: "BrushPressure") ?? "") ?? .size {
        didSet { UserDefaults.standard.set(penPressure.rawValue, forKey: "BrushPressure") }
    }
    var pendingShape: ShapeEdit?
    var sendingShape = false
    /// Spot removal (darktable's retouch): on while its tool is, the spots on
    /// the photo in output pixels, the one selected, and the size for new ones
    /// as a fraction of the photo's shorter side
    var isRemovingSpots = false {
        didSet {
            if isRemovingSpots != oldValue { selectedSpot = nil; if isRemovingSpots { Task { await fetchSpots() } } }
            if isRemovingSpots { isRemovingObjects = false }
        }
    }
    private(set) var spots: [Engine.Spot] = []
    var selectedSpot: Int?
    var spotSize = UserDefaults.standard.object(forKey: "SpotSize") as? Double ?? 0.02 {
        didSet { UserDefaults.standard.set(spotSize, forKey: "SpotSize") }
    }
    var spotClones = false
    /// Remove Objects (CleanUp.swift): on while its tool is; the photo's marks
    /// (from the catalog), where they fall on the output, the one selected,
    /// and the brush as a fraction of the photo's shorter side
    var isRemovingObjects = false {
        didSet {
            if isRemovingObjects != oldValue {
                selectedMark = nil
                if isRemovingObjects {
                    Task { await placeObjectMarks() }
                    Task.detached(priority: .userInitiated) { await Inpainter.shared.prepare() }
                }
            }
            if isRemovingObjects { isRemovingSpots = false }
        }
    }
    private(set) var cleanUpMarks: [CleanUpMark] = []
    private(set) var placedMarks: [UUID: PlacedMark] = [:]
    var selectedMark: UUID?
    var objectBrush = UserDefaults.standard.object(forKey: "ObjectBrush") as? Double ?? 0.02 {
        didSet { UserDefaults.standard.set(objectBrush, forKey: "ObjectBrush") }
    }
    /// filling is under way, for the panel
    private(set) var isFillingObjects = false
    private var fillTask: Task<Void, Never>?
    /// the last filled frame and where it was on the output, laid over frames
    /// until they're filled themselves, so objects don't flash back while dragging
    private var lastFill: (image: CIImage, scale: Double, x: Double, y: Double, height: Double)?
    private var pendingSpot: Engine.Spot?
    private var sendingSpot = false
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
    /// why the film browser's previews couldn't be made, if they couldn't
    var lookPreviewError: String?
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
    /// Image › Denoise to New DNG… is asking for the amount
    var choosingDenoise = false
    /// named export options for File › Export with Preset (ExportPresets.swift)
    var exportPresets = ExportPreset.load() { didSet { ExportPreset.save(exportPresets) } }
    var managingExportPresets = false
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
    // Workspaces (Workspaces.swift): named inspector sets
    private static let initialWorkspaces = Workspaces.load()
    private static var initialWorkspace: Workspace {
        let id = Workspaces.currentID(in: initialWorkspaces)
        return initialWorkspaces.first { $0.id == id }!
    }
    var workspaces: [Workspace] = EditorModel.initialWorkspaces { didSet { Workspaces.store(workspaces) } }
    var workspaceID: UUID = Workspaces.currentID(in: EditorModel.initialWorkspaces) { didSet { Workspaces.storeCurrent(workspaceID) } }
    /// set while a workspace is brought in, so its parts aren't written back half-changed
    @ObservationIgnored var applyingWorkspace = false

    /// The Essentials tab: the user's own modules, in their order.
    var essentials = EditorModel.initialWorkspace.essentials { didSet { recordWorkspace() } }
    /// fixed inspector panels (`InspectorPanel` ids) the current workspace hides
    var hiddenPanels = Set(EditorModel.initialWorkspace.hiddenPanels) { didSet { recordWorkspace() } }

    /// Lists saved before Scene white existed get White balance swapped for it,
    /// and lists saved before the recommended order get put in that order
    /// (anything the user added stays, after the standard modules). Once each.
    static func loadEssentials() -> [String] {
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
    /// filmic's auto-tune (its white and black from the photo) on new photos; on unless switched off
    var autoTuneForNewPhotos = UserDefaults.standard.object(forKey: SettingsKey.autoTuneForNewPhotos) != nil
        ? UserDefaults.standard.bool(forKey: SettingsKey.autoTuneForNewPhotos) : true {
        didSet { UserDefaults.standard.set(autoTuneForNewPhotos, forKey: SettingsKey.autoTuneForNewPhotos) }
    }
    var newPhotoColour = NewPhotoColour(rawValue: UserDefaults.standard.string(forKey: SettingsKey.newPhotoColour) ?? "") ?? .naturalSkin {
        didSet { UserDefaults.standard.set(newPhotoColour.rawValue, forKey: SettingsKey.newPhotoColour) }
    }
    /// darktable's profiled denoise on new raws at this ISO and above; 0 is off
    var noiseReductionFromISO = UserDefaults.standard.object(forKey: SettingsKey.noiseReductionFromISO) != nil
        ? UserDefaults.standard.integer(forKey: SettingsKey.noiseReductionFromISO) : 800 {
        didSet { UserDefaults.standard.set(noiseReductionFromISO, forKey: SettingsKey.noiseReductionFromISO) }
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
            noteLimitedHDR()
            if viewHDR { useHDRProfileIfSDR() }
            if !switchingViewForPhoto { viewHDRFollowsPhoto = false }
            if url != nil { requestRender() }
        }
    }
    /// HDR viewing was switched on because the photo's edit is HDR (an HLG
    /// NEF, an HDR edit saved earlier), not by the user: it goes off again for
    /// the next photo that isn't, rather than making that one HDR too
    private var viewHDRFollowsPhoto = false
    private var switchingViewForPhoto = false

    private func setViewHDRForPhoto(_ on: Bool) {
        switchingViewForPhoto = true
        defer { switchingViewForPhoto = false }
        viewHDR = on
        viewHDRFollowsPhoto = on
    }
    var showHeadroomOverlay = false { didSet { if showHeadroomOverlay != oldValue, viewHDR, url != nil { requestRender() } } }
    /// a slider is being dragged: the whole drag is one undo step
    private var sliderDragging = false
    /// Option held while dragging a slider: the canvas shows what clips (in
    /// HDR, what's beyond the display, the headroom overlay)
    private(set) var showsClipping = false {
        didSet { if showsClipping != oldValue, viewHDR, !showHeadroomOverlay, url != nil { requestRender() } }
    }
    @ObservationIgnored private var clippingCache: (frame: Int, image: CGImage)?

    func sliderDrag(active: Bool, clipping: Bool) {
        if !active, sliderDragging { lastGesture = nil }   // the next change is a new step
        sliderDragging = active
        showsClipping = active && clipping
    }

    /// the clipping view of the frame on screen, made once per frame
    var clippingImage: CGImage? {
        guard showsClipping, !imageIsHDR, let image else { return nil }
        if let c = clippingCache, c.frame == frameID { return c.image }
        guard let made = Clipping.image(of: image) else { return nil }
        clippingCache = (frameID, made)
        return made
    }

    /// Caps how far above reference white the HDR rendition goes, in stops
    /// (0 = no limit). Applied to the HDR view and the gain map export alike;
    /// darktable writes HEIF and JPEG XL itself, so those aren't capped.
    var hdrLimitStops = UserDefaults.standard.double(forKey: SettingsKey.hdrLimitStops) {
        didSet {
            guard hdrLimitStops != oldValue else { return }
            UserDefaults.standard.set(hdrLimitStops, forKey: SettingsKey.hdrLimitStops)
            // with a tone mapper, the peak is where the engine's HDR curve rises to
            if url != nil, let engine {
                let stops = hdrLimitStops
                Task { if let list = try? await engine.setHDRLimit(stops: stops) { modules = list; requestRender() } }
            }
            refreshHDRDisplay()
        }
    }
    /// The app's own roll-off to the peak, for photos without a tone mapper
    /// (HDR sources); with one, the engine's HDR curve rises to the peak
    /// instead (the helper's _sync_hdr_white).
    var hdrLimit: Double? { hdrLimitStops > 0 && !toneMapperSetsPeak ? pow(2, hdrLimitStops) : nil }

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
                        FileHandle.standardError.write("Darkslide HDR refresh \(ContinuousClock.now - start), limit \(hdrLimitStops), preview \(stops.map { "\($0)" } ?? "off"), peak \(hdrAnalysis?.peak ?? 0)\n".data(using: .utf8)!)
                    }
                }
                let frame = try? await engine.reprocessLastHDR(
                    displayHeadroom: displayHeadroom, wantOverlay: (showHeadroomOverlay || showsClipping) && stops == nil,
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
    /// Whether this display can show HDR in its current mode. An SDR screen,
    /// or a reference preset without HDR (Photography P3-D65), reports a
    /// potential headroom of 1; XDR and Apple Display presets report more,
    /// as do the HDR reference presets. HDR viewing stays available, as in
    /// Photos, but the canvas says why the highlights are clipped.
    private(set) var displayCanShowHDR = EditorModel.screenCanShowHDR
    /// This display has shown HDR before, so it's an SDR preset (Photography,
    /// Internet & Web) stopping it, which Displays settings can change. macOS
    /// doesn't say what the hardware can do, only what the current preset
    /// allows, so the app remembers each display it has seen with headroom.
    /// A Pro Display XDR counts from the start.
    private(set) var displayHasShownHDR = false

    /// The most this display can show in its current preset, × SDR white,
    /// however bright the screen is: 16 for XDR, 10 for HDR Video, about 5
    /// for Apple Display (P3-600 nits), 1 without HDR.
    private(set) var displayPotentialHeadroom = EditorModel.screenPotentialHeadroom
    /// briefly shown on switching to HDR on a display with limited HDR
    private(set) var showLimitedHDRNote = false
    private var limitedHDRNoteTask: Task<Void, Never>?

    enum DisplayHDRSupport { case full, limited, none }

    /// As Pixelmator puts it: full from 3 stops (XDR, HDR Video), limited
    /// below that (Apple Display, whose headroom shrinks as it gets brighter)
    var displayHDRSupport: DisplayHDRSupport {
        displayPotentialHeadroom >= 8 ? .full : displayPotentialHeadroom > 1 ? .limited : .none
    }

    private static var screenPotentialHeadroom: Double {
        Double(NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1)
    }

    private static var screenCanShowHDR: Bool { screenPotentialHeadroom > 1 }

    private func noteLimitedHDR() {
        limitedHDRNoteTask?.cancel()
        guard viewHDR, displayHDRSupport == .limited else { showLimitedHDRNote = false; return }
        showLimitedHDRNote = true
        limitedHDRNoteTask = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { showLimitedHDRNote = false }
        }
    }

    private func updateDisplayHDR() {
        let canShow = Self.screenCanShowHDR
        if canShow != displayCanShowHDR { displayCanShowHDR = canShow }
        let potential = Self.screenPotentialHeadroom
        if potential != displayPotentialHeadroom {
            let wasLimited = displayHDRSupport == .limited
            displayPotentialHeadroom = potential
            if displayHDRSupport == .limited, !wasLimited { noteLimitedHDR() }
        }
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue(),
              let id = CFUUIDCreateString(nil, uuid) as String? else { return }
        var known = UserDefaults.standard.stringArray(forKey: "HDRDisplays") ?? []
        if canShow, !known.contains(id) {
            known.append(id)
            UserDefaults.standard.set(known, forKey: "HDRDisplays")
        }
        let shown = known.contains(id) || screen.localizedName.contains("XDR")
        if shown != displayHasShownHDR { displayHasShownHDR = shown }
    }

    private func watchHeadroom() {
        headroomWatch?.cancel()
        updateDisplayHDR()
        guard viewHDR else { return }
        headroomWatch = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                // a display preset changed in System Settings, or the window moved screens
                updateDisplayHDR()
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
        ?? Set(EditorModel.initialWorkspace.expanded) { didSet { recordWorkspace() } }

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
    /// the frame count when an opening preview was shown; a render moves it on
    private var openingPreviewFrame: Int?
    /// counts photos opened, so a slow preview never lands on the next photo
    private var openingPreviewToken = 0
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

    /// Shows something at once while darktable opens a photo: the stored
    /// render or the camera's preview at thumbnail size, then the camera's
    /// preview at screen size (see `Library.openingPreview`). Each stage only
    /// shows if darktable's first render hasn't arrived yet.
    private func showOpeningPreview(for url: URL) {
        image = nil
        imageIsHDR = false
        imageIsZoomed = false
        let frame = frameID
        openingPreviewFrame = nil
        openingPreviewToken += 1
        let token = openingPreviewToken
        let pixels = canvasPixels
        Task {
            for quick in [true, false] {
                guard let preview = await Task.detached(priority: .userInitiated, operation: {
                    Library.openingPreview(for: url, quick: quick, maxPixels: pixels)
                }).value else { continue }
                guard openingPreviewToken == token, frameID == frame else { return }
                image = preview
                openingPreviewFrame = frame
                if UserDefaults.standard.bool(forKey: "LogRenderTimes") {
                    FileHandle.standardError.write("Darkslide opening preview \(quick ? "quick" : "screen") \(preview.width)x\(preview.height)\n".data(using: .utf8)!)
                }
            }
        }
    }

    // MARK: Engine lifecycle

    // only the current engine's exit counts; starts never overlap
    private var engineGeneration = 0
    private var startingEngine = false
    /// the session goes back to where it was once, at launch, not after an engine restart
    private static var sessionRestored = false
    private var failedStarts = 0

    func startEngine() async {
        updateDisplayHDR()   // remembers this display if it can show HDR now
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
            // TestModelDownload: launch argument (-TestModelDownload RescueMotion) for testing,
            // downloads a model as on first use, without asking
            if let name = UserDefaults.standard.string(forKey: "TestModelDownload"), let m = ModelStore.Model(rawValue: name) {
                Task.detached {
                    let started = Date()
                    do {
                        let url = try await ModelStore.download(m) { _ in }
                        FileHandle.standardError.write("Darkslide model test: \(url.path) in \(Int(Date().timeIntervalSince(started))) s, installed \(ModelStore.installedURL(m) != nil)\n".data(using: .utf8)!)
                    } catch {
                        FileHandle.standardError.write("Darkslide model test: \(error.localizedDescription)\n".data(using: .utf8)!)
                    }
                }
            }
            if let url = openWhenReady {
                openWhenReady = nil
                await open(url)
            } else if !Self.sessionRestored {
                await restoreSession()
            }
            Self.sessionRestored = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopEngine() async {
        await engine?.stop()
    }

    /// Before quitting: what leaving the photo does (a crop finished, unsaved
    /// edits saved to the sidecar, the thumbnail updated), ratings written,
    /// and where things were kept for the next launch.
    func prepareToQuit() async {
        saveSession()
        if engine != nil, url != nil {
            statusNote = "Saving…"
            await leaveCurrentPhoto()
        }
        while writingRatings { try? await Task.sleep(for: .milliseconds(100)) }
    }

    func saveSession() {
        Session(photo: url?.path, source: library.source.map(Session.Source.init), showingLibrary: showingLibrary,
                selection: library.selection?.path).save()
    }

    /// Goes back to where things were when Darkslide last quit.
    private func restoreSession() async {
        guard let session = Session.load() else { return }
        let fm = FileManager.default
        if let path = session.photo {
            let photo = URL(fileURLWithPath: path)
            if fm.fileExists(atPath: photo.photoFile.path) { await open(photo) }
        }
        if let source = session.source?.librarySource {
            if case .folder(let folder) = source, !fm.fileExists(atPath: folder.path) {} else { library.show(source) }
        }
        if let path = session.selection { library.selection = URL(fileURLWithPath: path) }
        if session.showingLibrary || url == nil, library.source != nil { await showLibrary() }
        if UserDefaults.standard.bool(forKey: "TestSession") {
            FileHandle.standardError.write("Darkslide session: restored \(url?.lastPathComponent ?? "no photo"), library \(library.sourceTitle ?? "-"), grid \(showingLibrary), selection \(library.selection?.lastPathComponent ?? "-")\n".data(using: .utf8)!)
        }
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
            errorMessage = "The darktable engine keeps stopping (status \(status)). Another copy of Darkslide may still be running; quit it and reopen Darkslide."
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
        showOpeningPreview(for: url)
        // stay in the folder or collection being worked through if it has this photo
        // (a Photos original's cache folder is never shown)
        // a version in a closed stack: open the stack, so it's in the filmstrip
        library.reveal(url)
        if openingPhotosAsset == nil, !library.contains(url) { library.show(folder: url.deletingLastPathComponent()) }
        showingLibrary = false
        do {
            decodedTIFF = nil
            openedAsHDR = false
            decoderInUse = nil
            appleRawControls = []
            appleRawLensDefault = nil
            let reply: OpenReply
            let isRaw = Library.isRaw(url)
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
            // a decode by macOS has its orientation applied, so the camera's frame no longer lines up
            cameraFocus = await Task.detached { CameraFocus.read(url) }.value
            focusOutline = nil
            canShowFocusPoint = cameraFocus?.box != nil && decodedTIFF == nil
            zoomCenter = CGPoint(x: 0.5, y: 0.5)
            // StartZoom: launch argument (-StartZoom 1) for testing
            let startZoom = UserDefaults.standard.double(forKey: "StartZoom")
            zoom = startZoom > 0 ? .scale(startZoom) : .fit
            // TestExport: launch arguments (-TestExport /path/file.jpg -TestExportFormat jpegGainMap
            // -TestExportProfile 1) for testing
            if let path = UserDefaults.standard.string(forKey: "TestExport") {
                FileHandle.standardError.write("Darkslide test export to \(path)\n".data(using: .utf8)!)
                var t = ExportSettings()
                t.format = ExportFormat(rawValue: UserDefaults.standard.string(forKey: "TestExportFormat") ?? "") ?? .jpeg
                // -TestExportEdge 0 for the original size
                t.longEdge = UserDefaults.standard.object(forKey: "TestExportEdge") != nil ? UserDefaults.standard.integer(forKey: "TestExportEdge") : 3000
                if let depth = Int(UserDefaults.standard.string(forKey: "TestExportDepth") ?? "") { t.bitDepth = depth }
                // -TestExportEnlarge 2: enlarged on export
                if let f = Int(UserDefaults.standard.string(forKey: "TestExportEnlarge") ?? "") { t.enlarge = f }
                if let p = ExportProfile(rawValue: UserDefaults.standard.integer(forKey: "TestExportProfile")) { t.profile = p }
                // -TestExportLift 2: exposure raised first, for highlights above white
                let lift = UserDefaults.standard.double(forKey: "TestExportLift")
                // -TestExportDelay 8: after the new-photo defaults (noise reduction and the rest) are in
                let delay = UserDefaults.standard.double(forKey: "TestExportDelay")
                Task {
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    if lift != 0, let ev = modules.first(where: { $0.key == "exposure:0" })?.fields.first(where: { $0.name == "exposure" })?.value.number {
                        setValue(.number(ev + lift), module: "exposure:0", field: "exposure")
                        await settleEdits()
                    }
                    await export(t, to: URL(fileURLWithPath: path), remember: false)
                }
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
            // TestWorkspaces: launch argument (-TestWorkspaces YES) for testing: saves a
            // second workspace, changes it, switches back and forth, logging each
            if UserDefaults.standard.bool(forKey: "TestWorkspaces") {
                Task { @MainActor in
                    @MainActor func log(_ s: String) {
                        FileHandle.standardError.write("Darkslide workspace test: \(s): \(currentWorkspace?.name ?? "-"), essentials \(essentials.count), open \(expanded.count), hidden \(hiddenPanels.sorted()), all \(workspaces.map(\.name))\n".data(using: .utf8)!)
                    }
                    try? await Task.sleep(for: .seconds(2)); log("start")
                    let first = workspaceID
                    saveWorkspace(as: "Colour"); log("saved")
                    setPanel("look", shown: false); setPanel("histogram", shown: false)
                    essentials.removeLast(2); expanded.removeAll(); log("changed")
                    switchWorkspace(to: first); log("back")
                    if let c = workspaces.last { switchWorkspace(to: c.id) }; log("again")
                }
            }
            // TestDrag: launch argument (-TestDrag exposure) for testing: drags that module's
            // main slider at 30 values a second for 3 s, as a slider sends them, and logs how
            // late the main thread handled the events and how many frames were shown
            if let op = UserDefaults.standard.string(forKey: "TestDrag") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    guard let m = modules.first(where: { $0.op == op }),
                          let f = m.fields.first(where: { $0.kind == .float }) else { return }
                    let frames0 = frameID
                    var late: [Double] = []
                    sliderDrag(active: true, clipping: false)
                    let start = ContinuousClock.now
                    for i in 0..<90 {
                        let due = start + .milliseconds(i * 33)
                        try? await Task.sleep(until: due, clock: .continuous)
                        let lag = ContinuousClock.now - due
                        late.append(Double(lag.components.attoseconds) / 1e15 + Double(lag.components.seconds) * 1000)
                        setValue(.number(f.value.number + sin(Double(i) / 10) * 0.5), module: m.key, field: f.name)
                    }
                    sliderDrag(active: false, clipping: false)
                    let sorted = late.sorted()
                    FileHandle.standardError.write("Darkslide drag test \(op).\(f.name): 90 values, main thread late by median \(String(format: "%.1f", sorted[45])) ms, p95 \(String(format: "%.1f", sorted[85])) ms, max \(String(format: "%.1f", sorted.last!)) ms; frames shown \(frameID - frames0) in 2.9 s\n".data(using: .utf8)!)
                }
            }
            // TestAutoExport: launch argument (-TestAutoExport /path/file.jpg) for testing:
            // exports as opened, runs Auto, logs the tone modules it leaves on and
            // exports again beside the first (file-auto.jpg)
            if let path = UserDefaults.standard.string(forKey: "TestAutoExport"), !Self.autoExportTested {
                Self.autoExportTested = true
                Task { @MainActor in
                    @MainActor func log(_ s: String) {
                        let on = modules.filter { $0.enabled && ["basecurve", "filmicrgb", "sigmoid", "agx", "exposure", "toneequal", "colorbalancergb", "rgbcurve", "tonecurve", "denoiseprofile", "highlights"].contains($0.op) }
                            .map { m in "\(m.op)\(m.op == "exposure" ? "=" + String(format: "%.2f", m.fields.first { $0.name == "exposure" }?.value.number ?? 0) : "")" }
                        let filmic = modules.first { $0.op == "filmicrgb" }.map { m in ["white_point_source", "black_point_source", "contrast", "latitude"].compactMap { n in m.fields.first { $0.name == n }.map { "\(n)=\(String(format: "%.2f", $0.value.number))" } } } ?? []
                        FileHandle.standardError.write("Darkslide auto test: \(s): on \(on), styles \(appliedStyles), filmic \(filmic)\n".data(using: .utf8)!)
                    }
                    try? await Task.sleep(for: .seconds(3))
                    log("opened")
                    var t = ExportSettings(); t.format = .jpeg; t.longEdge = 2000
                    await export(t, to: URL(fileURLWithPath: path), remember: false)
                    await autoAll()
                    try? await Task.sleep(for: .seconds(3))
                    log("after Auto")
                    await export(t, to: URL(fileURLWithPath: path.replacingOccurrences(of: ".jpg", with: "-auto.jpg")), remember: false)
                    log("exported")
                }
            }
            // TestHDRMatch: launch argument (-TestHDRMatch YES) for testing: renders the
            // photo in SDR and in HDR and logs the median and 99.9th percentile
            // brightness of each on the EDR scale (1 = SDR white): midtones should match
            if UserDefaults.standard.bool(forKey: "TestHDRMatch"), !Self.hdrMatchTested {
                Self.hdrMatchTested = true
                Task { @MainActor in
                    func stats(_ img: CGImage?) -> String {
                        guard let img, let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else { return "-" }
                        let n = img.width * img.height
                        var buf = [Float](repeating: 0, count: n * 4)
                        CIContext().render(CIImage(cgImage: img), toBitmap: &buf, rowBytes: img.width * 16,
                                           bounds: CGRect(x: 0, y: 0, width: img.width, height: img.height),
                                           format: .RGBAf, colorSpace: space)
                        let px = buf
                        var lum = [Float](); lum.reserveCapacity(n / 7)
                        for i in stride(from: 0, to: n, by: 7) {
                            lum.append(0.2126 * px[4 * i] + 0.7152 * px[4 * i + 1] + 0.0722 * px[4 * i + 2])
                        }
                        lum.sort()
                        return String(format: "median %.3f, p99.9 %.3f, max %.3f", lum[lum.count / 2], lum[lum.count * 999 / 1000], lum.last!)
                    }
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write("Darkslide HDR match: SDR \(stats(image)), tone mapper white \(modules.first { $0.op == "filmicrgb" || $0.op == "sigmoid" }.flatMap { m in m.fields.first { $0.name == "white_point_target" || $0.name == "display_white_target" }?.value.number } ?? -1)\n".data(using: .utf8)!)
                    viewHDR = true
                    try? await Task.sleep(for: .seconds(4))
                    FileHandle.standardError.write("Darkslide HDR match: HDR \(stats(image)), profile \(exportTarget.name), tone mapper white \(modules.first { $0.op == "filmicrgb" || $0.op == "sigmoid" }.flatMap { m in m.fields.first { $0.name == "white_point_target" || $0.name == "display_white_target" }?.value.number } ?? -1)\n".data(using: .utf8)!)
                    viewHDR = false
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write("Darkslide HDR match: SDR again \(stats(image))\n".data(using: .utf8)!)
                    // an sRGB JPEG of the HDR edit is its SDR rendition, and leaves the edit as it was
                    if let path = UserDefaults.standard.string(forKey: "TestHDRMatchExport") {
                        let before = await engine.historyEnd
                        var t = ExportSettings(); t.format = .jpeg; t.longEdge = 1600; t.profile = .sRGB
                        await export(t, to: URL(fileURLWithPath: path), remember: false)
                        let after = await engine.historyEnd
                        let file = lastExport.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                        FileHandle.standardError.write("Darkslide HDR match: sRGB export \(stats(file)), history \(before) -> \(after), profile now \(exportTarget.name)\n".data(using: .utf8)!)
                        requestRender()
                        try? await Task.sleep(for: .seconds(3))
                        FileHandle.standardError.write("Darkslide HDR match: SDR after export \(stats(image))\n".data(using: .utf8)!)
                    }
                }
            }
            // TestClipping: launch argument (-TestClipping YES) for testing: holds the
            // clipping view on, as an Option-drag of a slider does, and lifts exposure
            if UserDefaults.standard.bool(forKey: "TestClipping") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    sliderDrag(active: true, clipping: true)
                    if let m = modules.first(where: { $0.op == "exposure" }) { setValue(.number(2), module: m.key, field: "exposure") }
                }
            }
            // TestUndo: launch argument (-TestUndo YES) for testing: a drag with a pause
            // in it, a second drag straight after (two steps), a toggle and another
            // module's edit, then undo three times and redo once, logging each
            if UserDefaults.standard.bool(forKey: "TestUndo") {
                Task { @MainActor in
                    @MainActor func log(_ s: String) {
                        FileHandle.standardError.write("Darkslide undo test: \(s), steps \(undoStack.map(\.label)), redo \(redoStack.map(\.label))\n".data(using: .utf8)!)
                    }
                    try? await Task.sleep(for: .seconds(4))
                    log("start")
                    guard let exposure = modules.first(where: { $0.op == "exposure" }) else { return }
                    let ev = exposure.fields.first { $0.name == "exposure" }?.value.number ?? 0
                    sliderDrag(active: true, clipping: false)
                    for i in 1...10 {   // a drag, paused halfway for longer than the undo window
                        setValue(.number(ev + Double(i) / 10), module: exposure.key, field: "exposure")
                        try? await Task.sleep(for: .milliseconds(i == 5 ? 1500 : 50))
                    }
                    sliderDrag(active: false, clipping: false)
                    sliderDrag(active: true, clipping: false)
                    setValue(.number(ev + 1.5), module: exposure.key, field: "exposure")
                    sliderDrag(active: false, clipping: false)
                    try? await Task.sleep(for: .seconds(2)); log("after drags")
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
                        FileHandle.standardError.write("Darkslide library test: \(s): at \(self.url?.lastPathComponent ?? "-"), sidecars \(xmps), thumbnails \(library.thumbnails.count)\n".data(using: .utf8)!)
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
            // TestAppleRaw: launch argument (-TestAppleRaw YES) for testing, once: decodes
            // with Apple's engine, raises its exposure and noise reduction, logs the
            // decode each time, then puts the photo back on darktable's decoder
            if UserDefaults.standard.bool(forKey: "TestAppleRaw") {
                @MainActor func log(_ s: String) {
                    FileHandle.standardError.write("Darkslide apple raw test: \(s): decoder \(decoderInUse ?? "-"), tiff \(decodedTIFF?.lastPathComponent ?? "-"), controls \(appleRawControls.map { "\($0.id)=\(String(format: "%.2f", $0.defaultValue))" }), settings \(appleRawSettings.values), lens \(appleRawLensDefault.map { "\($0)" } ?? "-")\n".data(using: .utf8)!)
                }
                log("opened")
                if !Self.appleRawTested {
                    Self.appleRawTested = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(3))
                        await setRawDecoder(.apple(nil))
                        try? await Task.sleep(for: .seconds(8))
                        setAppleRaw("exposure", to: 1)
                        setAppleRaw("luminanceNR", to: 0.8)
                        try? await Task.sleep(for: .seconds(10))
                        log("after change")
                        resetAppleRaw()
                        try? await Task.sleep(for: .seconds(8))
                        await setRawDecoder(.darktable)
                    }
                }
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
                    // -TestOpenFromLibrary /photo: opens it from the grid, logging any error
                    if let path = UserDefaults.standard.string(forKey: "TestOpenFromLibrary"), !Self.openFromLibraryTestRan {
                        Self.openFromLibraryTestRan = true
                        try? await Task.sleep(for: .seconds(2))
                        await open(URL(fileURLWithPath: path))
                        try? await Task.sleep(for: .seconds(3))
                        FileHandle.standardError.write("Darkslide open from library test: at \(self.url?.lastPathComponent ?? "-"), library \(showingLibrary), error \(errorMessage ?? "none")\n".data(using: .utf8)!)
                        // then G on another photo selected in the grid opens that one
                        await showLibrary()
                        library.selection = library.items.first { $0.url != self.url }?.url
                        toggleLibrary()
                        try? await Task.sleep(for: .seconds(4))
                        FileHandle.standardError.write("Darkslide open from library test: G opened \(self.url?.lastPathComponent ?? "-"), library \(showingLibrary)\n".data(using: .utf8)!)
                    }
                    // -TestBatchExport /folder: the photos showing, as HDR HEIC with Auto, into the folder
                    // (and with -TestBatchToPhotos YES, into Photos too)
                    if let out = UserDefaults.standard.string(forKey: "TestBatchExport"), !Self.batchTestRan {
                        Self.batchTestRan = true
                        try? await Task.sleep(for: .seconds(2))
                        var s = ExportSettings.load()
                        s.format = .heifGainMap
                        s.longEdge = 0
                        s.enlarge = nil
                        let started = Date()
                        await exportPhotos(library.items.map(\.url), settings: s, to: URL(fileURLWithPath: out), autoAdjust: true,
                                           toPhotos: UserDefaults.standard.bool(forKey: "TestBatchToPhotos"))
                        FileHandle.standardError.write("Darkslide batch test: \(Int(Date().timeIntervalSince(started))) s, error \(errorMessage ?? "none")\n".data(using: .utf8)!)
                    }
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
                        FileHandle.standardError.write("Darkslide straighten preview now\n".data(using: .utf8)!)
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
                    FileHandle.standardError.write("Darkslide channel test: instances \(modules.filter { $0.op == "rgbcurve" }.map { "\($0.key) '\($0.instanceName)' \($0.enabled)" }), shown \(curveInfoKey ?? "-")\n".data(using: .utf8)!)
                }
            }
            // TestComposite: launch argument (-TestComposite /folder -TestCompositeLayer /photo) for
            // testing: a silhouette on white with the open photo as the base, previewed into the
            // folder, then made into a new photo
            if let folder = UserDefaults.standard.string(forKey: "TestComposite"), !folder.isEmpty,
               let other = UserDefaults.standard.string(forKey: "TestCompositeLayer"), let base = self.url,
               !Self.compositeTestRan {
                Self.compositeTestRan = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    // TestCompositeSheet: just show the sheet, set for a silhouette
                    if UserDefaults.standard.bool(forKey: "TestCompositeSheet") {
                        newComposite([base, URL(fileURLWithPath: other)])
                        compositeDraft?.region = .subject
                        compositeDraft?.backdrop = .colour
                        return
                    }
                    // the base on its own first, previewed and made, to compare
                    let plain = CompositeSettings(base: base.path)
                    if let p = try? await compositePreview(plain),
                       let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: folder + "/base-preview.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, p, nil)
                        CGImageDestinationFinalize(dest)
                    }
                    if let p = try? await compositePreview(CompositeSettings(base: other)),
                       let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: folder + "/layer-preview.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, p, nil)
                        CGImageDestinationFinalize(dest)
                    }
                    await createComposite(plain)
                    await createComposite(CompositeSettings(base: other))
                    await open(base)
                    newComposite([base, URL(fileURLWithPath: other)])
                    guard var draft = compositeDraft else { return }
                    draft.region = .subject
                    draft.backdrop = .colour
                    draft.colour = [1, 1, 1]
                    compositeDraft = draft
                    try? await Task.sleep(for: .seconds(1))
                    let started = Date()
                    if let p = try? await compositePreview(draft),
                       let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: folder + "/preview.png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, p, nil)
                        CGImageDestinationFinalize(dest)
                    }
                    let previewMs = Int(Date().timeIntervalSince(started) * 1000)
                    await createComposite(draft)
                    FileHandle.standardError.write("Darkslide composite test: preview \(previewMs) ms, made \(Int(Date().timeIntervalSince(started) * 1000) - previewMs) ms, open \(self.url?.lastPathComponent ?? "-"), recipe \(compositeRecipe != nil), size \(imageSize), error \(errorMessage ?? "none")\n".data(using: .utf8)!)
                }
            }
            // TestRescueFocus: launch argument (-TestRescueFocus /folder) for testing: the
            // sheet's preview at the centre, before and after, then the whole photo rescued
            if let folder = UserDefaults.standard.string(forKey: "TestRescueFocus"), !folder.isEmpty,
               let photo = self.url, !Self.rescueTestRan {
                Self.rescueTestRan = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    // TestRescueSheet: just show the sheet
                    if UserDefaults.standard.bool(forKey: "TestRescueSheet") { rescueFocusPhoto = photo; return }
                    var started = Date()
                    // TestRescueWhole: the whole photo rather than the subject
                    let centre = CGPoint(x: 0.5, y: 0.5)
                    let mask = UserDefaults.standard.bool(forKey: "TestRescueWhole") ? nil : try? await rescueFocusMatte(photo, centre: centre)
                    FileHandle.standardError.write("Darkslide rescue test: subject \(mask == nil ? "none" : "found") in \(Int(Date().timeIntervalSince(started) * 1000)) ms\n".data(using: .utf8)!)
                    // TestRescueShake: the camera shake model
                    let kind: RescueFocus.Kind = UserDefaults.standard.bool(forKey: "TestRescueShake") ? .shake : .focus
                    if let pair = try? await rescueFocusPreview(photo, kind: kind, centre: centre, amount: 1, mask: mask) {
                        for (name, image) in [("before", pair.before), ("after", pair.after)] {
                            if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: folder + "/\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                                CGImageDestinationAddImage(dest, image, nil)
                                CGImageDestinationFinalize(dest)
                            }
                        }
                    }
                    let previewMs = Int(Date().timeIntervalSince(started) * 1000)
                    started = Date()
                    await createRescueFocus(photo, kind: kind, amount: 1, mask: mask)
                    FileHandle.standardError.write("Darkslide rescue test: preview \(previewMs) ms, whole \(Int(Date().timeIntervalSince(started) * 1000)) ms, open \(self.url?.lastPathComponent ?? "-"), error \(errorMessage ?? "none")\n".data(using: .utf8)!)
                }
            }
            // TestToneCurve: launch argument (-TestToneCurve YES) for testing: shows the tone
            // curve card and lifts middle grey, logging the curve the engine reads back
            if UserDefaults.standard.bool(forKey: "TestToneCurve") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    search = "tone curve"
                    guard let m = modules.first(where: { $0.op == "tonecurve" }) else { return }
                    expanded.insert(m.key)
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write("Darkslide tone curve test: before \(curveInfo?.nodes ?? []), histogram \(curveInfo?.histogram.reduce(0, +) ?? 0)\n".data(using: .utf8)!)
                    setCurve(module: m.key, channel: 0, nodes: [.zero, CGPoint(x: 0.5, y: 0.65), CGPoint(x: 1, y: 1)])
                    try? await Task.sleep(for: .seconds(3))
                    requestRender()
                    try? await Task.sleep(for: .seconds(2))
                    let info = try? await engine.curve(module: m.key)
                    FileHandle.standardError.write("Darkslide tone curve test: after \(info?.nodes ?? []), enabled \(modules.first { $0.key == m.key }?.enabled ?? false), histogram \(info?.histogram.reduce(0, +) ?? 0)\n".data(using: .utf8)!)
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
                    FileHandle.standardError.write("Darkslide pan test: panned\n".data(using: .utf8)!)
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
                        FileHandle.standardError.write("Darkslide upright test: \(s): \(perspective), corners \(corners())\n".data(using: .utf8)!)
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
                        FileHandle.standardError.write("Darkslide local test: \(s): selected \(selectedLocal ?? "-"), locals \(localAdjustments.map { "\($0.key) \($0.instanceName) \($0.enabled)" }), shape \(localShape.map { "\($0.kind) \($0.points.prefix(3).map { "(\(Int($0.x)),\(Int($0.y)))" })" } ?? "-")\n".data(using: .utf8)!)
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
                        FileHandle.standardError.write("Darkslide presets test: \(s): presets \(presetList.count), diffuse \(presets(for: "diffuse").prefix(3).map(\.title)), shown \(shown)\n".data(using: .utf8)!)
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
            // TestGrain: launch argument (-TestGrain YES) for testing: turns grain on, chooses
            // films, and logs the film speed the grain is set to
            if UserDefaults.standard.bool(forKey: "TestGrain") {
                Task { @MainActor in
                    @MainActor func log(_ s: String) {
                        let iso = (grainModule?.fields.first { $0.name == "scale" }?.value.number ?? 0) * FilmSpeed.grainFactor
                        FileHandle.standardError.write("Darkslide grain test: \(s): grain \(grainModule?.enabled == true ? "on" : "off") at ISO \(Int(iso.rounded())), film \(currentFilmSpeed.map { "\(Int($0))" } ?? "-")\n".data(using: .utf8)!)
                    }
                    try? await Task.sleep(for: .seconds(4))
                    applyLook(filmLooks.first { $0.film.contains("Delta 100") })
                    try? await Task.sleep(for: .seconds(3)); log("Delta 100, grain off")
                    if let g = grainModule { setEnabled(true, module: g.key); matchGrainToFilm() }
                    try? await Task.sleep(for: .seconds(3)); log("grain on")
                    applyLook(filmLooks.first { $0.film == "Kodak TRI-X 400" && $0.variant == "+" })
                    try? await Task.sleep(for: .seconds(3)); log("Tri-X pushed")
                    for name in ["Polaroid 667", "Ilford HP5", "Kodak Portra 160 NC", "Fuji 400H", "Rollei Retro 80s", "Kodak TMAX 3200 3 Alt", "TealOrange1", "Kodak E-100 GX Ektachrome 100"] {
                        FileHandle.standardError.write("Darkslide grain test: \(name) is \(FilmSpeed.of(film: name).map { "\(Int($0))" } ?? "-")\n".data(using: .utf8)!)
                    }
                }
            }
            // TestAutoLift: launch argument (-TestAutoLift YES) for testing: runs Auto and
            // logs the exposure; then starts two stops darker and lifts again
            if UserDefaults.standard.bool(forKey: "TestAutoLift") {
                Task { @MainActor in
                    @MainActor func ev() -> Double { modules.first { $0.op == "exposure" }?.fields.first { $0.name == "exposure" }?.value.number ?? -99 }
                    try? await Task.sleep(for: .seconds(4))
                    FileHandle.standardError.write("Darkslide auto lift test: rule \(autoExposure ?? -99)\n".data(using: .utf8)!)
                    await autoAll()
                    FileHandle.standardError.write("Darkslide auto lift test: after Auto \(ev())\n".data(using: .utf8)!)
                    if let key = modules.first(where: { $0.op == "exposure" })?.key { setValue(.number(ev() - 2), module: key, field: "exposure") }
                    await liftDarkExposure()
                    FileHandle.standardError.write("Darkslide auto lift test: two stops under, lifted to \(ev())\n".data(using: .utf8)!)
                }
            }
            if UserDefaults.standard.bool(forKey: "TestLook") {
                Task { @MainActor in
                    @MainActor func log(_ s: String) {
                        let films = Set(filmLooks.map(\.film)).count
                        FileHandle.standardError.write("Darkslide look test: \(s): looks \(filmLooks.count) in \(films) films, current \(currentLook ?? "none") at \(lookStrength)\n".data(using: .utf8)!)
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
                    FileHandle.standardError.write("Darkslide rename test: now \(self.url?.lastPathComponent ?? "-"), files \((try? FileManager.default.contentsOfDirectory(atPath: self.url?.deletingLastPathComponent().path ?? "")) ?? [])\n".data(using: .utf8)!)
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
                    FileHandle.standardError.write("Darkslide paste test: opened \(self.url?.lastPathComponent ?? "-") exposure \(ev()), can paste \(canPaste)\n".data(using: .utf8)!)
                    pasteAdjustments()
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write("Darkslide paste test: pasted, exposure \(ev()), undo \(undoTitle ?? "-")\n".data(using: .utf8)!)
                    await undo()
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write("Darkslide paste test: undone, exposure \(ev())\n".data(using: .utf8)!)
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
                    FileHandle.standardError.write("Darkslide multi test: selected \(library.selectedInOrder.map(\.lastPathComponent)), targets \(pasteTargets.count)\n".data(using: .utf8)!)
                    pasteAdjustments()
                    try? await Task.sleep(for: .seconds(4))
                    let dir = self.url?.deletingLastPathComponent().path ?? ""
                    FileHandle.standardError.write("Darkslide multi test: sidecars \(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".xmp") }.sorted())\n".data(using: .utf8)!)
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
                    FileHandle.standardError.write("Darkslide subject test: \(String(format: "%.2f", found))s, selected \(selectedLocal ?? "-"), kind \(String(describing: localShape?.kind)), outlines \(localShape?.outlines.map(\.count) ?? []), error \(errorMessage ?? "-")\n".data(using: .utf8)!)
                }
            }
            // TestPhotos: launch argument (-TestPhotos YES) for testing: reads Photos (access,
            // albums, the newest photos) and opens the newest, logging only counts and names
            if UserDefaults.standard.bool(forKey: "TestPhotos"), openingPhotosAsset == nil {
                UserDefaults.standard.set(false, forKey: "TestPhotos")
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write("Darkslide photos test: authorised \(PhotosLibrary.authorised)\n".data(using: .utf8)!)
                    let shown = Date()
                    showPhotos(UserDefaults.standard.bool(forKey: "TestPhotosPlaces") ? .photosPlaces : .photos(album: nil, title: "All Photos"))
                    while library.items.isEmpty || library.isScanning || library.isLoadingLocations { try? await Task.sleep(for: .milliseconds(50)) }
                    FileHandle.standardError.write("Darkslide photos test: shown in \(String(format: "%.2f", Date().timeIntervalSince(shown)))s\n".data(using: .utf8)!)
                    try? await Task.sleep(for: .seconds(6))
                    let t0 = Date()
                    library.loadLocations()
                    FileHandle.standardError.write("Darkslide photos test: albums \(photosAlbums.count), items \(library.items.count), thumbnails \(library.thumbnails.count), located \(library.items.filter { library.locations[$0.url] != nil }.count) in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s\n".data(using: .utf8)!)
                    if let first = library.items.first {
                        await open(first.url)
                        try? await Task.sleep(for: .seconds(4))
                        FileHandle.standardError.write("Darkslide photos test: opened \(self.url?.lastPathComponent ?? "-"), asset \(photosAsset != nil), library url matches \(libraryURL == first.url), modules \(modules.count), source \(library.source?.title ?? "-")\n".data(using: .utf8)!)
                    }
                }
            }
            // TestDenoise: launch argument (-TestDenoise YES) for testing: denoises the photo to a
            // new DNG next to it, which then opens
            if UserDefaults.standard.bool(forKey: "TestDenoise"), url.pathExtension.lowercased() != "dng" {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    await denoiseToDNG(amount: Self.denoiseAmount)
                    FileHandle.standardError.write("Darkslide denoise test: open \(self.url?.lastPathComponent ?? "-"), noise reduction \(modules.first { $0.op == "denoiseprofile" }?.enabled == true ? "on" : "off"), error \(errorMessage ?? "none")\n".data(using: .utf8)!)
                }
            }
            // TestAIDenoise: launch argument (-TestAIDenoise /folder) for testing: AI denoise
            // at 100 then 50 then off, exporting a 2000 px JPEG at each into the folder
            if let folder = UserDefaults.standard.string(forKey: "TestAIDenoise"), !folder.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    var t = ExportSettings(); t.format = .jpeg; t.longEdge = 2000
                    for amount in [100.0, 50, 0] {
                        let started = Date()
                        await setAIDenoise(amount)
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        await export(t, to: URL(fileURLWithPath: folder + "/ai\(Int(amount)).jpg"), remember: false)
                        FileHandle.standardError.write("Darkslide AI denoise test: \(Int(amount)) in \(ms) ms, on \(aiDenoise.map { "\($0)" } ?? "off"), profiled \(modules.first { $0.op == "denoiseprofile" }?.enabled == true ? "on" : "off"), error \(errorMessage ?? "none")\n".data(using: .utf8)!)
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
                    FileHandle.standardError.write("Darkslide heif test: done, error \(errorMessage ?? "none")\n".data(using: .utf8)!)
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
                    FileHandle.standardError.write("Darkslide extras test: done, error \(errorMessage ?? "none")\n".data(using: .utf8)!)
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
                        FileHandle.standardError.write("Darkslide level test: from \(deg) -> \(straighten)\n".data(using: .utf8)!)
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
                        FileHandle.standardError.write("Darkslide crop test: \(s): size \(imageSize), frame \(image.map { "\($0.width)x\($0.height)" } ?? "-"), straighten \(straighten), corners \(corners())\n".data(using: .utf8)!)
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
            // TestRemoveObjects: launch argument (-TestRemoveObjects x,y,x,y,…,radius) for testing:
            // paints a stroke in output pixels, waits for the fill, then exports to -TestRemoveObjectsExport
            if let spec = UserDefaults.standard.string(forKey: "TestRemoveObjects"), !Self.removeObjectsTested {
                Self.removeObjectsTested = true
                Task { @MainActor in
                    func log(_ s: String) { FileHandle.standardError.write("Darkslide remove objects: \(s)\n".data(using: .utf8)!) }
                    let v = spec.split(separator: ",").compactMap { Double($0) }
                    guard v.count >= 3 else { return log("bad spec") }
                    let pts = stride(from: 0, to: v.count - 1, by: 2).map { CGPoint(x: v[$0], y: v[$0 + 1]) }
                    try? await Task.sleep(for: .seconds(4))
                    let before = image
                    let start = ContinuousClock.now
                    isRemovingObjects = true
                    addObjectMark(pts, radius: v[v.count - 1])
                    try? await Task.sleep(for: .seconds(1))
                    while isFillingObjects || image === before { try? await Task.sleep(for: .milliseconds(100)) }
                    log("filled in \(ContinuousClock.now - start), marks \(cleanUpMarks.count), placed \(placedMarks.values.map { "\($0.points.count) pts r \(Int($0.radius))" })")
                    if let key = modules.first(where: { $0.op == "exposure" })?.key {
                        let ev = modules.first { $0.key == key }?.fields.first { $0.name == "exposure" }?.value.number ?? 0
                        setValue(.number(ev + 0.5), module: key, field: "exposure")
                        try? await Task.sleep(for: .seconds(3))
                        log("after an edit: filling \(isFillingObjects)")
                    }
                    if let out = UserDefaults.standard.string(forKey: "TestRemoveObjectsExport") {
                        await export(ExportSettings(format: .jpeg, profile: .sRGB, quality: 90), to: URL(fileURLWithPath: out), remember: false)
                        log("exported \(out), error \(errorMessage ?? "none")")
                        removeAllObjectMarks()
                        await settleEdits()
                        await export(ExportSettings(format: .jpeg, profile: .sRGB, quality: 90),
                                     to: URL(fileURLWithPath: out.replacingOccurrences(of: ".jpg", with: "-plain.jpg")), remember: false)
                        log("exported without")
                    }
                    removeAllObjectMarks()
                    try? await Task.sleep(for: .seconds(1))
                    log("removed all: \(cleanUpMarks.count), undo \(undoTitle ?? "-")")
                    await undo()
                    log("undone: \(cleanUpMarks.count) marks, catalog \(catalog.cleanUp(of: url).count), next undo \(undoTitle ?? "-")")
                    await redo()
                    log("redone: \(cleanUpMarks.count) marks, catalog \(catalog.cleanUp(of: url).count)")
                    await undo()
                    await undo()
                    log("undone twice: \(cleanUpMarks.count) marks, next undo \(undoTitle ?? "-"), redo \(redoTitle ?? "-")")
                }
            }
            // TestFullScreen: launch argument (-TestFullScreen YES) for testing: into full
            // screen editing and out, logging the window and the canvas
            if UserDefaults.standard.bool(forKey: "TestFullScreen"), !Self.fullScreenTested {
                Self.fullScreenTested = true
                Task { @MainActor in
                    @MainActor func log(_ s: String) {
                        let w = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
                        let all = NSApp.windows.map { "\($0.className) visible \($0.isVisible) main \($0.canBecomeMain) primary \($0.collectionBehavior.contains(.fullScreenPrimary))" }
                        FileHandle.standardError.write("Darkslide full screen: \(s): active \(NSApp.isActive), windows \(all)\n".data(using: .utf8)!)
                        FileHandle.standardError.write("Darkslide full screen: \(s): window full screen \(w?.styleMask.contains(.fullScreen) ?? false), toolbar \(w?.toolbar?.isVisible ?? false), canvas \(canvasPixelSize), frame \(image?.width ?? 0)x\(image?.height ?? 0)\n".data(using: .utf8)!)
                    }
                    try? await Task.sleep(for: .seconds(4))
                    log("before")
                    isFullScreenEditor = true
                    try? await Task.sleep(for: .seconds(6))
                    log("in")
                    try? await Task.sleep(for: .seconds(8))
                    showHUD = false
                    try? await Task.sleep(for: .seconds(1))
                    log("HUD hidden")
                    showHUD = true
                    isFullScreenEditor = false
                    try? await Task.sleep(for: .seconds(4))
                    log("out")
                    try? await Task.sleep(for: .seconds(4))
                    log("out, later")
                }
            }
            // TestCompare: launch argument (-TestCompare YES) for testing: Compare on,
            // off (the engine frees its before renders) and on again
            if UserDefaults.standard.bool(forKey: "TestCompare"), !Self.compareTested {
                Self.compareTested = true
                Task { @MainActor in
                    func log(_ s: String) { FileHandle.standardError.write("Darkslide compare: \(s)\n".data(using: .utf8)!) }
                    try? await Task.sleep(for: .seconds(4))
                    comparing = true
                    try? await Task.sleep(for: .seconds(3))
                    let first = beforeImage
                    log("on: \(first.map { "\($0.width)x\($0.height)" } ?? "-")")
                    comparing = false
                    try? await Task.sleep(for: .seconds(2))
                    log("off: \(beforeImage == nil ? "freed" : "kept")")
                    comparing = true
                    try? await Task.sleep(for: .seconds(3))
                    log("on again: \(beforeImage.map { "\($0.width)x\($0.height)" } ?? "-"), largest difference \(Self.pixelDifference(first, beforeImage).map { String(format: "%.4f", $0) } ?? "-")")
                }
            }
            // TestLoupe: launch argument (-TestLoupe YES) for testing: the loupe at the
            // middle, at 100% and 200%, and after an edit
            if UserDefaults.standard.bool(forKey: "TestLoupe"), !Self.loupeTested {
                Self.loupeTested = true
                Task { @MainActor in
                    func log(_ s: String) { FileHandle.standardError.write("Darkslide loupe: \(s)\n".data(using: .utf8)!) }
                    try? await Task.sleep(for: .seconds(4))
                    showLoupe = true
                    pointLoupe(at: CGPoint(x: imageSize.width / 2, y: imageSize.height / 2))
                    try? await Task.sleep(for: .seconds(2))
                    log("100%: \(loupeImage.map { "\($0.width)x\($0.height)" } ?? "-") from \(loupeOrigin), canvas frame \(image?.width ?? 0)")
                    let first = loupeImage
                    loupeZoom = 2
                    try? await Task.sleep(for: .seconds(2))
                    log("200%: \(loupeImage.map { "\($0.width)x\($0.height)" } ?? "-") from \(loupeOrigin), new \(loupeImage !== first)")
                    let second = loupeImage
                    if let key = modules.first(where: { $0.op == "exposure" })?.key {
                        let ev = modules.first { $0.key == key }?.fields.first { $0.name == "exposure" }?.value.number ?? 0
                        setValue(.number(ev + 1), module: key, field: "exposure")
                    }
                    try? await Task.sleep(for: .seconds(3))
                    log("after an edit: new \(loupeImage !== second)")
                    loupeZoom = 1
                    showLoupe = false
                }
            }
            // TestBrush: launch argument (-TestBrush YES) for testing: a Dodge brush,
            // a second stroke, an erasing one, then undo, logging the strokes
            if UserDefaults.standard.bool(forKey: "TestBrush"), !Self.brushTested {
                Self.brushTested = true
                Task { @MainActor in
                    @MainActor func log(_ s: String) {
                        let anchor = localAdjustments.first
                        let ev = anchor.map { localValue(.exposure, of: $0) } ?? -99
                        FileHandle.standardError.write("Darkslide brush: \(s): locals \(localAdjustments.map(\.key)), exposure \(ev), strokes \(localShape?.strokes.map { "\($0.points.count)\($0.erase ? " erase" : "")" } ?? []), undo \(undoTitle ?? "-")\n".data(using: .utf8)!)
                    }
                    try? await Task.sleep(for: .seconds(4))
                    let w = imageSize.width, h = imageSize.height
                    let line = { (y: Double) in stride(from: 0.3, through: 0.6, by: 0.01).map { CGPoint(x: w * $0, y: h * y) } }
                    startBrush(.dodge)
                    paintStroke(line(0.5), erase: false)
                    try? await Task.sleep(for: .seconds(3))
                    log("dodged")
                    paintStroke(line(0.3), erase: false)
                    try? await Task.sleep(for: .seconds(3))
                    log("second stroke")
                    paintStroke([CGPoint(x: w * 0.45, y: h * 0.5)], erase: true)
                    try? await Task.sleep(for: .seconds(3))
                    log("erased")
                    await undo()
                    try? await Task.sleep(for: .seconds(2))
                    await fetchLocalShape()
                    log("undone")
                }
            }
            // TestPenBrush: launch argument (-TestPenBrush YES) for testing: a Dodge stroke
            // whose pen pressure ramps from light to full, by size, then another by
            // opacity, logging the stored points and the brightening along each
            if UserDefaults.standard.bool(forKey: "TestPenBrush"), !Self.penBrushTested {
                Self.penBrushTested = true
                Task { @MainActor in
                    func log(_ s: String) { FileHandle.standardError.write("Darkslide pen brush: \(s)\n".data(using: .utf8)!) }
                    /// the canvas frame's brightness (0...255) at a point in output pixels
                    @MainActor func brightness(_ p: CGPoint) -> Double {
                        guard let frame = image else { return -1 }
                        let k = Double(frame.width) / imageSize.width
                        var px = [UInt8](repeating: 0, count: 4)
                        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                        ctx.draw(frame, in: CGRect(x: -p.x * k, y: -(imageSize.height - p.y) * k + 1, width: Double(frame.width), height: Double(frame.height)))
                        return (Double(px[0]) + Double(px[1]) + Double(px[2])) / 3
                    }
                    let saved = penPressure
                    defer { penPressure = saved }
                    try? await Task.sleep(for: .seconds(4))
                    let w = imageSize.width, h = imageSize.height
                    let r = brushSize * min(w, h)
                    let xs = Array(stride(from: 0.3, through: 0.6, by: 0.01))
                    let ramp = xs.indices.map { 0.1 + 0.9 * Double($0) / Double(xs.count - 1) }
                    func probes(_ y: Double, off: Double) -> [CGPoint] {
                        [CGPoint(x: w * 0.32, y: h * y + off), CGPoint(x: w * 0.58, y: h * y + off)]
                    }
                    // by size: just off the line, the light end shouldn't reach, the full end should
                    let sizeProbes = probes(0.5, off: 0.6 * r)
                    let before = sizeProbes.map(brightness)
                    penPressure = .size
                    startBrush(.dodge)
                    paintStroke(xs.map { CGPoint(x: w * $0, y: h * 0.5) }, erase: false, pressure: ramp)
                    try? await Task.sleep(for: .seconds(4))
                    let s1 = localShape?.strokes.first
                    log("size: sizes \(s1?.sizes.map { "\(String(format: "%.2f", $0.first!))...\(String(format: "%.2f", $0.last!))" } ?? "none"), brightening off the line at the light end \(Int(brightness(sizeProbes[0]) - before[0])), full end \(Int(brightness(sizeProbes[1]) - before[1]))")
                    // by opacity: on the line, the light end brightens less
                    let opacityProbes = probes(0.3, off: 0)
                    let before2 = opacityProbes.map(brightness)
                    penPressure = .opacity
                    paintStroke(xs.map { CGPoint(x: w * $0, y: h * 0.3) }, erase: false, pressure: ramp)
                    try? await Task.sleep(for: .seconds(4))
                    let s2 = localShape?.strokes.last
                    log("opacity: opacities \(s2?.opacities.map { "\(String(format: "%.2f", $0.first!))...\(String(format: "%.2f", $0.last!))" } ?? "none"), brightening on the line at the light end \(Int(brightness(opacityProbes[0]) - before2[0])), full end \(Int(brightness(opacityProbes[1]) - before2[1]))")
                }
            }
            // TestLocalNames: launch argument (-TestLocalNames YES) for testing: a Dodge
            // brush (named for it), renamed, renamed back, then Reset All
            if UserDefaults.standard.bool(forKey: "TestLocalNames"), !Self.localNamesTested {
                Self.localNamesTested = true
                Task { @MainActor in
                    @MainActor func log(_ s: String) {
                        FileHandle.standardError.write("Darkslide local names: \(s): \(localAdjustments.map { "\($0.instanceName) [\(localTitle($0))] parts \(localParts($0).count)" }), selected \(selectedLocal ?? "-"), shape \(localShape == nil ? "none" : "shown")\n".data(using: .utf8)!)
                    }
                    try? await Task.sleep(for: .seconds(4))
                    let w = imageSize.width, h = imageSize.height
                    startBrush(.dodge)
                    paintStroke(stride(from: 0.3, through: 0.6, by: 0.02).map { CGPoint(x: w * $0, y: h * 0.5) }, erase: false)
                    try? await Task.sleep(for: .seconds(3))
                    if let a = localAdjustments.first { setLocal(.contrast, to: 20, of: a) }
                    try? await Task.sleep(for: .seconds(2))
                    log("painted")
                    if let key = selectedLocal { renameLocal(key, to: "Sky") }
                    try? await Task.sleep(for: .seconds(2))
                    log("renamed")
                    if let key = selectedLocal { renameLocal(key, to: "") }
                    try? await Task.sleep(for: .seconds(2))
                    log("renamed back")
                    await resetAll()
                    try? await Task.sleep(for: .seconds(2))
                    log("reset")
                }
            }
            // TestBrushPreview: launch argument (-TestBrushPreview /folder) for testing:
            // the live look of a Dodge stroke and a Cool one, written as PNGs with the frame
            if let folder = UserDefaults.standard.string(forKey: "TestBrushPreview"), !folder.isEmpty, !Self.brushPreviewTested {
                Self.brushPreviewTested = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    func write(_ img: CGImage?, _ name: String) {
                        guard let img, let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: folder + "/" + name) as CFURL, "public.png" as CFString, 1, nil) else { return }
                        CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
                    }
                    write(image, "frame.png")
                    for brush in [QuickBrush.dodge, .cool] {
                        startBrush(brush)
                        startBrushPreview(erase: false)
                        write(brushPreview?.image, "\(brush.rawValue).png")
                        FileHandle.standardError.write("Darkslide brush preview: \(brush.title) \(brushPreview.map { "\($0.image.width)x\($0.image.height) at \($0.origin) size \($0.size)" } ?? "none")\n".data(using: .utf8)!)
                        endBrushPreview()
                    }
                    pendingBrush = nil
                }
            }
            // TestAutoStack: launch argument (-TestAutoStack YES) for testing: stacks the
            // folder's bursts, logs the library, then unstacks them
            if UserDefaults.standard.bool(forKey: "TestAutoStack"), !Self.autoStackTested {
                Self.autoStackTested = true
                Task { @MainActor in
                    @MainActor func log(_ s: String) {
                        let shown = library.items.map { "\($0.name)\($0.stackSize > 1 ? " [\($0.stackSize)\($0.isStackPick ? " pick" : "")]" : "")" }
                        FileHandle.standardError.write("Darkslide auto-stack: \(s): \(shown)\n".data(using: .utf8)!)
                    }
                    try? await Task.sleep(for: .seconds(3))
                    await showLibrary()
                    log("before")
                    autoStackBursts()
                    try? await Task.sleep(for: .seconds(1))
                    while isAutoStacking { try? await Task.sleep(for: .milliseconds(200)) }
                    log("stacked, \(statusNote ?? "-")")
                    library.unstack(library.allPhotos)
                    log("unstacked")
                }
            }
            // TestStacks: launch argument (-TestStacks YES) for testing: two versions of the
            // photo, then its stack closed, open, picked and revealed, logging the library
            if UserDefaults.standard.bool(forKey: "TestStacks"), !Self.stacksTested {
                Self.stacksTested = true
                Task { @MainActor in
                    @MainActor func log(_ s: String) {
                        let shown = library.items.map { "\($0.name)\($0.stackSize > 1 ? " [\($0.stackSize)\($0.stackOpen ? " open" : "")\($0.isStackPick ? " pick" : "")]" : "")" }
                        FileHandle.standardError.write("Darkslide stacks: \(s): \(shown), selected \(library.selection?.lastPathComponent ?? "-")\n".data(using: .utf8)!)
                    }
                    try? await Task.sleep(for: .seconds(3))
                    for n in 1...2 {
                        try? PhotoVersion.blankSidecar.write(toFile: PhotoVersion.url(of: url, number: n).path + ".xmp", atomically: true, encoding: .utf8)
                    }
                    library.rescan()
                    try? await Task.sleep(for: .seconds(2))
                    log("closed")
                    library.toggleStack(url)
                    log("opened")
                    library.pickForStack(PhotoVersion.url(of: url, number: 2))
                    library.selection = PhotoVersion.url(of: url, number: 1)
                    library.toggleStack(url)
                    log("picked version 3, closed with version 2 selected")
                    await open(PhotoVersion.url(of: url, number: 1))
                    try? await Task.sleep(for: .seconds(3))
                    log("opened version 2 in the editor")
                    library.setAllStacks(open: false)
                    log("all closed")
                    library.pickForStack(url)
                    for n in 1...2 { try? FileManager.default.removeItem(atPath: PhotoVersion.url(of: url, number: n).path + ".xmp") }
                }
            }
            // TestSpots: launch argument (-TestSpots YES) for testing: heals a spot in the
            // middle, moves it, then removes it, logging the spots and the middle's brightness
            if UserDefaults.standard.bool(forKey: "TestSpots"), !Self.spotsTested {
                Self.spotsTested = true
                Task { @MainActor in
                    func log(_ s: String) { FileHandle.standardError.write("Darkslide spots: \(s)\n".data(using: .utf8)!) }
                    try? await Task.sleep(for: .seconds(4))
                    isRemovingSpots = true
                    let c = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
                    addSpot(at: c)
                    try? await Task.sleep(for: .seconds(3))
                    log("added \(spots.map { "\($0.id) at \(Int($0.x)),\(Int($0.y)) r \(Int($0.r)) from \(Int($0.sx)),\(Int($0.sy))" }), retouch on \(modules.first { $0.op == "retouch" }?.enabled ?? false), error \(errorMessage ?? "none")")
                    if var s = spots.first {
                        s.x += 100; s.sx += 100
                        moveSpot(s)
                        try? await Task.sleep(for: .seconds(3))
                        await fetchSpots()
                        log("moved \(spots.map { "\(Int($0.x)),\(Int($0.y))" })")
                        removeSpot(s.id)
                        try? await Task.sleep(for: .seconds(3))
                        log("removed, \(spots.count) left")
                        addSpot(at: c)
                        try? await Task.sleep(for: .seconds(3))
                        log("added again: \(spots.count)")
                        // at 100% on the spot, with and without retouch, to look at
                        zoomCenter = CGPoint(x: 0.5, y: 0.5)
                        zoom = .scale(1)
                        try? await Task.sleep(for: .seconds(3))
                        @MainActor func patch() -> [UInt8] {
                            guard let img = image, let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 200,
                                                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return [] }
                            ctx.draw(img, in: CGRect(x: -(img.width / 2 - 100), y: -(img.height / 2 - 100), width: img.width, height: img.height))
                            return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: 200 * 200))
                        }
                        let healed = patch()
                        log("zoomed: healed, frame \(image?.width ?? 0)x\(image?.height ?? 0), frames \(frameID)")
                        if let r = modules.first(where: { $0.op == "retouch" }) {
                            setEnabled(false, module: r.key)
                            try? await Task.sleep(for: .seconds(3))
                            let plain = patch()
                            let changed = zip(healed, plain).filter { abs(Int($0) - Int($1)) > 8 }.count
                            log("zoomed: unhealed, frames \(frameID), \(changed) of 40000 middle pixels differ")
                        }
                    }
                }
            }
            // TestShortcuts: launch argument (-TestShortcuts YES) for testing: runs the
            // Export with Preset action on the folder's photos, as Shortcuts would
            if UserDefaults.standard.bool(forKey: "TestShortcuts"), !Self.shortcutsTested {
                Self.shortcutsTested = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    let files = await DarkslideShortcutsTest.export(library.items.map(\.url), preset: exportPresets[0], model: self)
                    FileHandle.standardError.write("Darkslide shortcuts: returned \(files)\n".data(using: .utf8)!)
                }
            }
            // TestQuickLook: launch argument (-TestQuickLook YES) for testing: brightens the
            // photo a stop and writes its Quick Look render, as leaving it would
            if UserDefaults.standard.bool(forKey: "TestQuickLook") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    if let key = modules.first(where: { $0.op == "exposure" })?.key {
                        let ev = modules.first { $0.key == key }?.fields.first { $0.name == "exposure" }?.value.number ?? 0
                        setValue(.number(ev + 1), module: key, field: "exposure")
                    }
                    try? await Task.sleep(for: .seconds(3))
                    if let img = image { QuickLookCache.store(img, for: url) }
                    FileHandle.standardError.write("Darkslide quick look: wrote \(QuickLookCache.file(for: url).path)\n".data(using: .utf8)!)
                }
            }
            // TestExportPreset: launch argument (-TestExportPreset YES) for testing: exports
            // the folder's photos with the second preset, logs the files, then shows the presets sheet
            if UserDefaults.standard.bool(forKey: "TestExportPreset"), !Self.exportPresetTested {
                Self.exportPresetTested = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    let photos = library.items.map(\.url)
                    let preset = exportPresets[1]
                    export(photos, with: preset)
                    try? await Task.sleep(for: .seconds(1))
                    while batchExport != nil { try? await Task.sleep(for: .milliseconds(200)) }
                    try? await Task.sleep(for: .seconds(1))
                    let dir = url.deletingLastPathComponent().appendingPathComponent("Exports")
                    let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
                    let sizes = files.map { f -> String in
                        let p = CGImageSourceCreateWithURL(f as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
                        return "\(f.lastPathComponent) \(p?[kCGImagePropertyPixelWidth] ?? 0)x\(p?[kCGImagePropertyPixelHeight] ?? 0)"
                    }
                    FileHandle.standardError.write("Darkslide export preset \(preset.name), \(photos.count) photos: \(sizes), error \(errorMessage ?? "none")\n".data(using: .utf8)!)
                    managingExportPresets = true
                }
            }
            // TestSmartAlbums: launch argument (-TestSmartAlbums YES) for testing: shows
            // each smart album in the catalog and logs what it gathers
            if UserDefaults.standard.bool(forKey: "TestSmartAlbums"), !Self.smartAlbumsTested {
                Self.smartAlbumsTested = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    for album in catalog.smartAlbums {
                        let start = ContinuousClock.now
                        showSource(.smart(album.id))
                        try? await Task.sleep(for: .milliseconds(200))
                        while library.isScanning { try? await Task.sleep(for: .milliseconds(50)) }
                        FileHandle.standardError.write("Darkslide smart album \(album.name): \(library.items.map(\.name)) in \(ContinuousClock.now - start)\n".data(using: .utf8)!)
                    }
                    // the editing sheet, in a window of its own to look at
                    if let album = catalog.smartAlbums.last { SmartAlbumSheet.showForTesting(album) }
                }
            }
            // TestVersions: launch argument (-TestVersions YES) for testing: duplicates the
            // photo, edits the version, goes back to the original, then deletes the version
            if UserDefaults.standard.bool(forKey: "TestVersions"), !url.isVersion, !Self.versionsTested {
                Self.versionsTested = true
                Task { @MainActor in
                    func log(_ s: String) { FileHandle.standardError.write("Darkslide versions: \(s)\n".data(using: .utf8)!) }
                    @MainActor func ev() -> Double { modules.first { $0.op == "exposure" }?.fields.first { $0.name == "exposure" }?.value.number ?? -99 }
                    @MainActor func sidecars() -> [String] {
                        ((try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []).filter { $0.hasSuffix(".xmp") }.sorted()
                    }
                    try? await Task.sleep(for: .seconds(4))
                    log("original ev \(ev())")
                    duplicateVersion()
                    try? await Task.sleep(for: .seconds(6))
                    log("now \(self.url?.lastPathComponent ?? "-") version \(self.url?.versionNumber ?? -1) ev \(ev()), items \(library.items.map(\.name)), sidecars \(sidecars())")
                    if let key = modules.first(where: { $0.op == "exposure" })?.key { setValue(.number(ev() + 1.5), module: key, field: "exposure") }
                    try? await Task.sleep(for: .seconds(2))
                    await save()
                    let versionEV = ev()
                    await open(url)
                    try? await Task.sleep(for: .seconds(4))
                    log("back to \(self.url?.lastPathComponent ?? "-") ev \(ev()), version had \(versionEV)")
                    let v = PhotoVersion.url(of: url, number: 1)
                    await open(v)
                    try? await Task.sleep(for: .seconds(4))
                    log("reopened version ev \(ev())")
                    deleteVersion(v)
                    try? await Task.sleep(for: .seconds(6))
                    log("after delete: \(self.url?.lastPathComponent ?? "-"), items \(library.items.map(\.name)), sidecars \(sidecars())")
                }
            }
            // TestLocalControls: launch argument (-TestLocalControls YES) for testing: a
            // radial gradient, warmed then cooled, logging the centre's colour and the instances
            if UserDefaults.standard.bool(forKey: "TestLocalControls") {
                Task { @MainActor in
                    func log(_ s: String) { FileHandle.standardError.write("Darkslide local controls: \(s)\n".data(using: .utf8)!) }
                    @MainActor func rgb() -> String {
                        guard let img = image else { return "-" }
                        let ci = CIImage(cgImage: img), box = CGRect(x: img.width / 2 - 20, y: img.height / 2 - 20, width: 40, height: 40)
                        var px = [Float](repeating: 0, count: 4)
                        CIContext().render(ci.cropped(to: box).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: box)]),
                                           toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                                           colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
                        return String(format: "r %.3f g %.3f b %.3f", px[0], px[1], px[2])
                    }
                    try? await Task.sleep(for: .seconds(4))
                    log("start \(rgb())")
                    addLocal(.ellipse)
                    try? await Task.sleep(for: .seconds(3))
                    guard let a = localAdjustments.first else { return log("no adjustment") }
                    for (c, v) in [(LocalControl.warmth, 100.0), (.warmth, -100), (.saturation, -100), (.clarity, 50)] {
                        setLocal(c, to: v, of: a)
                        try? await Task.sleep(for: .seconds(3))
                        log("\(c.label) \(v): \(rgb()), read back \(localValue(c, of: a)), parts \(localParts(a).map(\.key))")
                    }
                    setEnabled(false, module: a.key)
                    try? await Task.sleep(for: .seconds(3))
                    log("off: \(rgb()), parts on \(localParts(a).map(\.enabled))")
                }
            }
            // TestWhitePick: launch argument (-TestWhitePick 0.5,0.5) for testing, logs the
            // raw white balance as temperature and tint, then picks white at that point
            if let spec = UserDefaults.standard.string(forKey: "TestWhitePick") {
                Task { @MainActor in
                    func log(_ s: String) { FileHandle.standardError.write("Darkslide white: \(s)\n".data(using: .utf8)!) }
                    try? await Task.sleep(for: .seconds(4))
                    if let t = modules.first(where: { $0.op == "temperature" }), let cam = cameraWhite {
                        let mul = ["red", "green", "blue"].map { n in t.fields.first { $0.name == n }?.value.number ?? 0 }
                        let kt = cam.kelvinAndTint(multipliers: mul)
                        let back = cam.multipliers(kelvin: kt.kelvin, tint: kt.tint)
                        log("D65 multipliers \(cam.multipliers(white: [0.95047, 1, 1.08883])), xyzToCam \(cam.xyzToCam)")
                        log("raw multipliers \(mul) = \(Int(kt.kelvin)) K tint \(kt.tint), back \(back.prefix(3))")
                    }
                    let p = spec.split(separator: ",").compactMap { Double($0) }
                    guard p.count == 2, let cc = modules.first(where: { $0.op == "channelmixerrgb" && $0.enabled }) else { return log("no colour calibration") }
                    @MainActor func state() -> String {
                        let m = modules.first { $0.key == cc.key }!
                        return m.fields.filter { ["illuminant", "x", "y", "temperature"].contains($0.name) }
                            .map { "\($0.name) \($0.value.number ?? 0)" }.joined(separator: ", ")
                    }
                    log("before: \(state())")
                    pickWhite(for: cc.key)
                    pickWhite(at: CGPoint(x: p[0], y: p[1]))
                    await whitePickTask?.value
                    log("after: \(state()) note \(whitePickNote ?? "none")")
                }
            }
            // StartExport: launch argument (-StartExport YES) for testing, opens as ⌘E would
            if UserDefaults.standard.bool(forKey: "StartExport") {
                Task { @MainActor in ExportPanel.present(model: self) }
            }
            sensor = reply.sensor ?? "bayer"
            cameraWhite = CameraWhite(xyzToCam: reply.xyzToCam, camToXyz: reply.camToXyz)
            whitePickTarget = nil
            whitePickNote = nil
            isRemovingSpots = false
            spots = []
            isRemovingObjects = false
            cleanUpMarks = catalog.cleanUp(of: url)
            placedMarks = [:]
            lastFill = nil
            fillTask?.cancel()
            photosAsset = openingPhotosAsset
            modules = reply.modules
            panBackdrop = nil
            selectedLocal = nil
            hasUnsavedChanges = false
            // the opening preview stays until the first render replaces it
            if openingPreviewFrame != frameID { image = nil }
            beforeImage = nil
            beforeKey = ""
            loupeImage = nil
            loupeCovers = nil
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
            if viewHDRFollowsPhoto { setViewHDRForPhoto(false) }
            if viewHDR { useHDRProfileIfSDR() }
            openedWithEdit = reply.hadSidecar
            lensInfo = await Task.detached { Self.readLens(url) }.value
            await measureAutoExposure()
            // an HDR edit from before the engine's HDR curve: tone mapper back to 100% white
            if exportTarget.isHDR { syncToneWhite(quietly: true) }
            await loadPresets()
            await loadLook()
            if !reply.hadSidecar { await applyNewPhotoDefaults() }
            aiDenoise = nil
            denoiseSent = false
            if let amount = catalog.aiDenoise(of: url) { await setAIDenoise(amount, restoring: true) }
            // an HDR edit is shown in HDR, on a display that can
            if exportTarget.isHDR, !viewHDR,
               Self.screenCanShowHDR {
                setViewHDRForPhoto(true)
            }
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

    func resetEssentials() { essentials = Presentation.defaultEssentials }

    /// Puts Essentials back in the recommended order, keeping the modules the
    /// user added (after the standard ones, in their current order).
    func restoreEssentialsOrder() {
        let rank = Dictionary(uniqueKeysWithValues: Presentation.defaultEssentials.enumerated().map { ($1, $0) })
        essentials = essentials.enumerated().sorted { a, b in
            (rank[a.element] ?? 1000 + a.offset, a.offset) < (rank[b.element] ?? 1000 + b.offset, b.offset)
        }.map(\.element)
    }

    var essentialsInDefaultOrder: Bool {
        let rank = Dictionary(uniqueKeysWithValues: Presentation.defaultEssentials.enumerated().map { ($1, $0) })
        let ranked = essentials.compactMap { rank[$0] }
        return ranked == ranked.sorted() && essentials.drop { rank[$0] != nil }.allSatisfy { rank[$0] == nil }
    }

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

    /// Settings Darkslide applies to a photo without an edit: lens correction,
    /// optionally automatic exposure, the camera style per the settings, a
    /// basic colour preset, noise reduction at high ISO and filmic's auto-tune.
    /// a DNG's BaselineExposure (EV), if it has one
    nonisolated static func dngBaselineExposure(_ url: URL) -> Double? {
        guard url.pathExtension.lowercased() == "dng",
              let src = CGImageSourceCreateWithURL(url.photoFile as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let dng = props[kCGImagePropertyDNGDictionary] as? [CFString: Any] else { return nil }
        return (dng[kCGImagePropertyDNGBaselineExposure] as? NSNumber)?.doubleValue
    }

    private func applyNewPhotoDefaults() async {
        if lensCorrectionForNewPhotos, let lens = modules.firstIndex(where: { $0.op == "lens" }), !modules[lens].enabled {
            // darktable picks the camera's embedded correction data if the raw
            // has it (Sony, Fujifilm, Olympus...), otherwise the Lensfun database.
            // Awaited, unlike setEnabled: a later step (auto-tune, a preset)
            // takes the engine's module list, which must have it.
            try? await engine?.enable(module: modules[lens].key, on: true)
            modules[lens].enabled = true
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
        // colour, unless a camera style brought its own
        if appliedStyles.isEmpty, let title = newPhotoColour.presetTitle,
           let balance = modules.first(where: { $0.op == "colorbalancergb" }),
           let preset = presets(for: "colorbalancergb").first(where: { $0.title == title }), let engine {
            await settleEdits()
            if let updated = try? await engine.applyPreset(preset.name, module: balance.key) { modules = updated }
        }
        // the D80's CCD and other older sensors band and speckle when pushed;
        // Lightroom hides it with noise reduction that's always on
        if noiseReductionFromISO > 0, sensor != "linear", decodedTIFF == nil, let url,
           let iso = await Task.detached(operation: { Self.isoSpeed(url) }).value, iso >= noiseReductionFromISO,
           let denoise = modules.firstIndex(where: { $0.op == "denoiseprofile" }), !modules[denoise].enabled, let engine {
            // awaited, not setEnabled's background task: the auto-tune below
            // takes the engine's module list, which must have it
            await settleEdits()
            try? await engine.enable(module: modules[denoise].key, on: true)
            modules[denoise].enabled = true
        }
        // a NEF shot in the camera's HLG tone mode was meant as HDR, as NX Studio
        // treats it: the edit gets an HLG export target, as choosing HDR would
        if let url, !exportTarget.isHDR, await Task.detached(operation: { NikonHDRPreview.isHLG(url) }).value {
            setOutputProfile(25)   // HLG P3
        }
        // last, once exposure and the style are in: filmic's white and black from the photo
        if autoTuneForNewPhotos, modules.contains(where: { $0.op == "filmicrgb" && $0.enabled }) {
            await settleEdits()
            await autoTuneFilmic()
        }
    }

    /// the photo's ISO from its EXIF, if it has one
    nonisolated static func isoSpeed(_ url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url.photoFile as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first else { return nil }
        return iso
    }

    /// Back to the photo as darktable would first show it, plus Darkslide's
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
            // objects removed are part of the edit too
            if !cleanUpMarks.isEmpty { restoreObjectMarks([]) }
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
    /// ratings waiting to be written to sidecars, in order
    @ObservationIgnored var ratingQueue: [(URL, Int)] = []
    @ObservationIgnored var writingRatings = false

    func autoAll() async {
        recordUndoStep(label: "Auto")
        // one undo step for everything Auto does
        undoGroupDepth += 1
        defer { undoGroupDepth -= 1 }
        await matchCamera()
        await liftDarkExposure()
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
        // observed state is only written when it changes: a slider sends many
        // values a second, and each write redraws whatever reads it
        modules[m].fields[f].value = value
        if !modules[m].enabled { modules[m].enabled = true }
        if !hasUnsavedChanges { hasUnsavedChanges = true }
        // by module, so controls that set several fields (tone equalizer zones,
        // white balance) make one step
        recordUndoStep(label: Presentation.title(of: modules[m]), gesture: module)
        if editsSinceStyle == 0 { editsSinceStyle = 1 }
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
        // and a local adjustment its other modules
        var partners = modules[m].op == "rgbcurve" ? channelCurveModule.map { [$0.key] } ?? [] : []
        if Self.isLocal(modules[m]) { partners += localParts(modules[m]).map(\.key).filter { $0 != module } }
        for p in partners { if let c = modules.firstIndex(where: { $0.key == p }) { modules[c].enabled = on } }
        // queued behind pending sets so the undo step resolves before it
        Task {
            await settleEdits()
            try? await engine?.enable(module: module, on: on)
            for p in partners { try? await engine?.enable(module: p, on: on) }
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
            while !pendingSets.isEmpty || !pendingCheckpoints.isEmpty || pendingCurve != nil || renderRequested || loupeDirty {
                // only the loupe wants a frame: a small one, at its zoom
                if pendingSets.isEmpty, pendingCheckpoints.isEmpty, pendingCurve == nil, !renderRequested {
                    loupeDirty = false
                    await renderLoupe(engine)
                    continue
                }
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
                        try await engine.newStep()
                    }
                    try await engine.setMany(Array(sets[sent...]))
                    let setDone = ContinuousClock.now
                    if let c = curve {
                        try await engine.setCurve(module: c.module, channel: c.channel, nodes: c.nodes, linked: c.linked)
                    }
                    let simulate = viewHDR ? previewHeadroomStops : nil
                    let frame = try await engine.render(maxPixels: pixels, hdr: viewHDR,
                                                        displayHeadroom: displayHeadroom,
                                                        wantOverlay: (showHeadroomOverlay || showsClipping) && simulate == nil, crop: crop,
                                                        overrides: (showsSDRVersion ? sdrOverrides : []) + cropOverrides + curveOverrides,
                                                        hdrLimit: viewHDR ? hdrLimit : nil,
                                                        keepForRefresh: crop == nil)
                    let renderDone = ContinuousClock.now
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
                    if isRemovingSpots, pendingSpot == nil, !sendingSpot, crop == nil { await fetchSpots() }
                    // the crop or rotation may have changed
                    if showFocusPoint, crop == nil { await fetchFocusOutline() }
                    frameStraighten = renderStraighten
                    if crop == nil, !isCropping, !isSimulatingHeadroom {
                        thumbnailFrame = frame.image
                        panBackdrop = (frame.image, frame.isHDR)
                    }
                    if let r = frame.rotateInSize { rotateInSize = r }
                    if let simulate, frame.isHDR {
                        image = try await gainMapPreview(frame, stops: simulate, maxPixels: pixels, crop: crop, engine: engine)
                    } else {
                        image = laidOverLastFill(frame.image, crop: crop)
                        if !cleanUpMarks.isEmpty, !draft { fillObjects(in: frame.image, crop: crop) }
                    }
                    isSimulatingHeadroom = simulate != nil && frame.isHDR
                    if isSimulatingHeadroom, let img = image {
                        FileHandle.standardError.write("Darkslide preview at +\(simulate!) stops: headroom \(img.contentHeadroom), frame peak \(frame.analysis?.peak ?? 0)\n".data(using: .utf8)!)
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
                    // DumpFrame: launch argument (-DumpFrame /path/frame.png) for testing, writes each full frame as shown
                    if let path = UserDefaults.standard.string(forKey: "DumpFrame"), crop == nil, !draft,
                       let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, image ?? frame.image, nil)
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
                                FileHandle.standardError.write("Darkslide HDR frame RGB means \(rgb.map { String(format: "%.3f", $0) })\n".data(using: .utf8)!)
                                return rgb[0]
                            }
                            let b = raw.bindMemory(to: UInt8.self)
                            return stride(from: 0, to: b.count, by: 4 * 97).reduce(0) { $0 + Double(b[$1]) } / Double(b.count / (4 * 97))
                        }
                        func ms(_ d: Duration) -> Int { Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }
                        FileHandle.standardError.write("Darkslide frame split: set \(ms(setDone - start)) ms, render call \(ms(renderDone - setDone)) ms, after \(ms(ContinuousClock.now - renderDone)) ms\n".data(using: .utf8)!)
                        FileHandle.standardError.write("Darkslide frame \(lastRenderMs ?? 0) ms (engine \(frame.ms) ms) at \(pixels) px\(draft ? " draft" : ""), mean \(String(format: "%.3f", mean))\n".data(using: .utf8)!)
                    }
                    framesSinceOpen += 1
                    // the loupe shows the edit as it is now
                    if showLoupe, loupeCenter != nil, !draft { loupeDirty = true }
                    // the first frame after opening fills the cache and is always slow
                    if !draft, crop == nil, framesSinceOpen > 1 {
                        // smoothed, so one slow frame doesn't flip the mode
                        let ms = Double(lastRenderMs ?? 0)
                        fullRenderMs = fullRenderMs == 0 ? ms : fullRenderMs * 0.6 + ms * 0.4
                    }
                } catch {
                    // mid-open the engine has no photo for a moment (the last
                    // closed, a raw darktable can't read being decoded by macOS);
                    // the open renders when it's done
                    if !isOpening { errorMessage = error.localizedDescription }
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
            if !isOpening { errorMessage = error.localizedDescription }
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
    /// exporting several photos: how many are done of how many
    var batchExport: (done: Int, total: Int)?
    @ObservationIgnored var stopBatchExport = false
    private(set) var lastExport: URL? {
        didSet { if lastExport != nil { showExportDone = true } }
    }
    var showExportDone = false

    /// the edit's export profile, as the HDR card describes it
    var exportTarget: HDRTarget { HDRTarget(darktableProfile: outputProfileType ?? 1) }

    /// pixel size of an export at the given long edge (0 = original), or enlarged
    func exportSize(longEdge: Int, enlarge: Int? = nil) -> CGSize {
        let long = max(imageSize.width, imageSize.height)
        let scale = enlarge.map(Double.init) ?? (longEdge > 0 ? min(1, Double(longEdge) / long) : 1)
        return CGSize(width: (imageSize.width * scale).rounded(), height: (imageSize.height * scale).rounded())
    }

    func export(_ settings: ExportSettings, to url: URL, remember: Bool = true) async {
        guard let engine else { return }
        isExporting = true
        // in the subtitle while it runs, unless a batch is showing its own
        let note = batchExport == nil
        if note { statusNote = "Exporting \(url.lastPathComponent)…" }
        defer {
            isExporting = false
            if note { statusNote = nil }
        }
        if remember { settings.save() }
        // a gain map is made from the edit's own HDR and SDR renderings
        var settings = settings
        if settings.format.isGainMap, settings.profile.isHDR == false { settings.profile = .fromEdit }
        do {
            // an HDR file from an SDR edit: the edit takes the HDR profile (and
            // its reference white and tone mapper white), as for a gain map
            if settings.profile != .fromEdit, HDRTarget(darktableProfile: settings.profile.rawValue).isHDR,
               !exportTarget.isHDR, !settings.format.isGainMap {
                setOutputProfile(settings.profile.rawValue)
                await settleEdits()
            }
            if settings.format.isGainMap {
                try await exportGainMap(settings, to: url, engine: engine)
                lastExport = url
                FileHandle.standardError.write("Darkslide exported \(url.path)\n".data(using: .utf8)!)
            } else if settings.format == .heif || ExportExtras.load().any || toneMapsExport(settings)
                        || settings.enlargement != nil || !cleanUpMarks.isEmpty {
                // HEIF, anything with a frame or watermark, an HDR source made SDR, enlargements,
                // and objects to remove, through Core Image
                try await exportThroughCoreImage(settings, to: url, engine: engine)
                lastExport = url
            } else {
                // darktable adds the extension itself
                lastExport = try await engine.export(
                    path: url.deletingPathExtension().path, format: settings.format.darktableName ?? "jpeg",
                    quality: settings.quality, bitDepth: settings.bitDepth, maxEdge: settings.longEdge,
                    profile: settings.profile == .fromEdit ? nil : settings.profile.rawValue,
                    sdrFromHDR: exportsSDRRendition(settings))
            }
            if let photo = self.url, let file = lastExport {
                catalog.recordExport(photo, file: file, format: settings.format.title)
            }
        } catch {
            FileHandle.standardError.write("Darkslide export failed: \(error)\n".data(using: .utf8)!)
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
    /// an SDR file from an edit with an HDR profile (not an HDR source, whose
    /// SDR export is tone mapped instead): darktable exports its SDR rendition
    private func exportsSDRRendition(_ settings: ExportSettings) -> Bool {
        guard !openedAsHDR, exportTarget.isHDR, settings.profile != .fromEdit else { return false }
        return !HDRTarget(darktableProfile: settings.profile.rawValue).isHDR
    }

    private func toneMapsExport(_ settings: ExportSettings) -> Bool {
        guard openedAsHDR, !settings.format.isGainMap else { return false }
        let profile = settings.profile == .fromEdit ? (outputProfileType ?? 1) : settings.profile.rawValue
        return !HDRTarget(darktableProfile: profile).isHDR
    }

    private func exportThroughCoreImage(_ settings: ExportSettings, to url: URL, engine: Engine) async throws {
        let profile = settings.profile == .fromEdit ? (outputProfileType ?? 1) : settings.profile.rawValue
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("darkslide-export-\(UUID().uuidString)")
        let toneMap = toneMapsExport(settings)
        let float = toneMap || (settings.format == .tiff && settings.bitDepth == 32)
        let extras = ExportExtras.load()
        // smaller by the frame's share, so the framed picture is the size chosen;
        // an HDR source to be tone mapped comes out linear and unclipped
        let enlarge = settings.enlargement
        let maxEdge = enlarge != nil ? 0 : extras.any ? extras.photoLongEdge(for: settings.longEdge, photo: imageSize) : settings.longEdge
        let tiff = try await engine.export(path: temp.path, format: "tiff", quality: 100, bitDepth: float ? 32 : 16,
                                           maxEdge: maxEdge,
                                           profile: toneMap ? 4 : profile,
                                           sdrFromHDR: !toneMap && exportsSDRRendition(settings))
        defer { try? FileManager.default.removeItem(at: tiff) }
        // objects to remove, on the output, scaled to the export below
        await placeObjectMarks()
        let marks = cleanUpMarks.compactMap { placedMarks[$0.id] }
        let outputWidth = imageSize.width
        if !marks.isEmpty { statusNote = "Removing objects…" }
        let quality = Double(settings.quality) / 100
        let progress = enlargeProgress()
        defer { statusNote = nil }
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
            if !marks.isEmpty {
                let k = image.extent.width / max(outputWidth, 1)
                // read as darktable encoded it (tagged), or colour managed
                image = try await Inpainter.shared.fill(image, marks: marks.map { $0.scaled(k) }, encoded: tagged != nil)
            }
            if let enlarge {
                // in the export's encoding, or gamma-encoded Rec.2020 for the tone mapped one
                let encoding = toneMap ? CGColorSpace(name: CGColorSpace.itur_2020) : tagged != nil ? nil : space
                image = try await Upscaler.enlarge(image, by: enlarge, space: encoding, progress: progress)
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
            case .jpegGainMap, .heifGainMap:
                throw EngineError(message: "A gain map is made from renders, not an export.")
            }
        }.value
        FileHandle.standardError.write("Darkslide exported \(url.path)\n".data(using: .utf8)!)
    }

    /// the status line's progress while an export is enlarged
    private func enlargeProgress() -> @Sendable (Double) -> Void {
        { p in
            Task { @MainActor [weak self] in
                if self?.isExporting == true { self?.statusNote = "Enlarging… \(Int(p * 100))%" }
            }
        }
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

    /// A JPEG or HEIC with an ISO 21496-1 HDR gain map, written by Core Image.
    /// The HDR image is exactly what the HDR preview shows: darktable's output
    /// in the edit's HDR profile, on the EDR scale. The SDR base is, by default,
    /// darktable's own SDR rendering of the edit (the tone mapper's target white
    /// back at 100%); Core Image computes the gain map between the two. Viewers
    /// without HDR, or with little headroom, mostly see that SDR base.
    private func exportGainMap(_ settings: ExportSettings, to url: URL, engine: Engine) async throws {
        var target = exportTarget
        if settings.profile != .fromEdit { target = HDRTarget(darktableProfile: settings.profile.rawValue) }
        guard target.isHDR else {
            throw EngineError(message: "A gain map needs an HDR edit: choose an HLG or PQ export format in the HDR card, or an HDR colour profile here.")
        }
        if settings.profile != .fromEdit { setOutputProfile(settings.profile.rawValue) }
        // smaller by the frame's share, if there is one, so the framed picture is the size chosen
        let extrasForSize = ExportExtras.load()
        let enlarge = settings.enlargement
        let size = exportSize(longEdge: enlarge != nil ? 0 : extrasForSize.any ? extrasForSize.photoLongEdge(for: settings.longEdge, photo: imageSize) : settings.longEdge)
        let maxPixels = Int(max(size.width, size.height))
        let progress = enlargeProgress()
        defer { statusNote = nil }

        let hdrFrame = try await engine.render(maxPixels: maxPixels, hdr: true, displayHeadroom: 16, wantOverlay: false,
                                               hdrLimit: hdrLimit)
        var hdr = CIImage(cgImage: hdrFrame.image)
        if UserDefaults.standard.string(forKey: "TestExport") != nil {
            FileHandle.standardError.write("Darkslide gain map test: target \(target.name), HDR frame peak \(hdrFrame.analysis?.peak ?? -1), isHDR \(hdrFrame.isHDR)\n".data(using: .utf8)!)
        }

        var sdr: CIImage
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
        // objects to remove, from each rendering: the gain map between them stays the photo's
        if !cleanUpMarks.isEmpty {
            statusNote = "Removing objects…"
            await placeObjectMarks()
            let marks = cleanUpMarks.compactMap { placedMarks[$0.id] }
            let k = hdr.extent.width / max(imageSize.width, 1)
            hdr = try await Inpainter.shared.fill(hdr, marks: marks.map { $0.scaled(k) },
                                                  headroom: max(hdrFrame.analysis?.peak ?? 1, 1))
            sdr = try await Inpainter.shared.fill(sdr, marks: marks.map { $0.scaled(sdr.extent.width / max(imageSize.width, 1)) })
        }
        if let enlarge {
            // the SDR picture through the scaler, and the HDR one made from it
            // with the brightening between them enlarged smoothly: the scaler's
            // sharpening, in an HDR encoding, came out about 3% brighter
            let big = try await Upscaler.enlarge(sdr, by: enlarge, space: CGColorSpace(name: CGColorSpace.displayP3), progress: progress)
            hdr = Upscaler.carryHDR(from: hdr, sdr: sdr, onto: big)
            sdr = big
        }

        // the frame and watermark on both, so the gain map between them is the photo's
        let extras = ExportExtras.load()
        let framedHDR = extras.any ? extras.composite(hdr) : hdr
        var framedSDR = extras.any ? extras.composite(sdr) : sdr
        // renders carry no metadata: the photo's own, as darktable's exports have
        if let photo = self.url { framedSDR = framedSDR.settingProperties(Self.exportMetadata(of: photo)) }
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): Double(settings.quality) / 100,
            .hdrImage: framedHDR,
        ]
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        if settings.format == .heifGainMap && settings.bitDepth >= 10 {
            try CIContext().writeHEIF10Representation(of: framedSDR, to: url, colorSpace: p3, options: options)
        } else if settings.format == .heifGainMap {
            try CIContext().writeHEIFRepresentation(of: framedSDR, to: url, format: .RGBA8, colorSpace: p3, options: options)
        } else {
            try CIContext().writeJPEGRepresentation(of: framedSDR, to: url, colorSpace: p3, options: options)
        }
        // render the preview again at its own size (the frame file was reused)
        requestRender()
    }

    /// A photo's camera metadata (time, camera and lens, exposure, location)
    /// and rating, for a file written from renders, which are already upright.
    nonisolated static func exportMetadata(of photo: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(photo.photoFile as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let all = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [:] }
        var props: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyTIFFDictionary,
                    kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let d = all[key as String] { props[key as String] = d }
        }
        if var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            props[kCGImagePropertyExifDictionary as String] = exif
        }
        var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        props[kCGImagePropertyTIFFDictionary as String] = tiff
        props[kCGImagePropertyOrientation as String] = 1
        let rating = Sidecar.rating(of: photo)
        if rating > 0 {
            var iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any] ?? [:]
            iptc[kCGImagePropertyIPTCStarRating as String] = rating
            props[kCGImagePropertyIPTCDictionary as String] = iptc
        }
        return props
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

    /// The export profile, with an old HDR edit's tone mapper white back to
    /// 100%. One undo step.
    func setOutputProfile(_ type: Int) {
        recordUndoStep(label: "Export Format")
        undoGroupDepth += 1
        defer { undoGroupDepth -= 1 }
        setValue(.number(Double(type)), module: "colorout:0", field: "type")
        syncToneWhite()
    }

    // MARK: HDR white

    // With an HDR profile, SDR white sits at reference white (203 nits): the
    // engine adds hidden "HDR white" instances before the output profile (see
    // the helper's _sync_hdr_white). The tone mapper stays at 100% target
    // white, as in SDR, and a curve takes only the light tones above SDR
    // white, up to the peak (the HDR limit, or the format's), so midtones and
    // skin look as they do in SDR.

    private static let toneWhiteFields = ["sigmoid": "display_white_target", "filmicrgb": "white_point_target"]

    /// whether an enabled tone mapper has a target white (sigmoid, filmic)
    var toneMapperSetsPeak: Bool { modules.contains { $0.enabled && Self.toneWhiteFields[$0.op] != nil } }

    /// The target whites earlier versions set for HDR: 100% × 2^peak, the
    /// peak being the HDR limit or the format's, within darktable's 1600%.
    /// Raising it stretched the tone mapper's whole curve above middle grey.
    private var legacyHDRToneWhites: [Double] {
        var stops = [2.0, log2(HDRTarget.hlgPeakNits / HDRTarget.referenceWhiteNits),
                     log2(HDRTarget.pqPeakNits / HDRTarget.referenceWhiteNits)]
        if hdrLimitStops > 0 { stops.append(hdrLimitStops) }
        return stops.map { min(1600, (100 * pow(2, $0)).rounded()) }
    }

    /// Sets an enabled tone mapper's target white back to 100% where an
    /// earlier version raised it for HDR, leaving any other value the user set.
    /// `quietly` is for opening: not an edit of the user's.
    fileprivate func syncToneWhite(quietly: Bool = false) {
        let legacy = legacyHDRToneWhites
        for (i, m) in modules.enumerated() where m.enabled {
            guard let field = Self.toneWhiteFields[m.op],
                  let f = m.fields.firstIndex(where: { $0.name == field }) else { continue }
            let current = m.fields[f].value.number
            guard legacy.contains(where: { abs(current - $0) < 0.5 }) else { continue }
            if quietly {
                modules[i].fields[f].value = .number(100)
                pendingSets.append((m.key, field, .number(100)))
            } else {
                setValue(.number(100), module: m.key, field: field)
            }
        }
    }

    // MARK: Match Camera

    // MARK: Denoise

    private(set) var isDenoising = false

    /// a Bayer raw that darktable decodes, with the model installed
    var canDenoise: Bool {
        url != nil && !showingLibrary && !isDenoising && sensor == "bayer" && decodedTIFF == nil
            && photosAsset == nil && RawDenoise.isAvailable && url.map(Library.isRaw) == true
    }

    /// New Composite's sheet: the photos and settings being put together,
    /// made into a new photo by createComposite (Composite.swift)
    var compositeDraft: CompositeSettings?
    /// Rescue Focus's sheet, for this photo
    var rescueFocusPhoto: URL?
    /// the photo the sheet is for, rendered at full size, and its metadata
    @ObservationIgnored var rescueFocusSource: (url: URL, image: CIImage)?
    /// the subjects Vision found in it, nil inside when none
    @ObservationIgnored var rescueFocusSubjects: (url: URL, subjects: RescueFocus.Subjects?)?
    static var compositeTestRan = false
    static var rescueTestRan = false
    static var batchTestRan = false
    static var openFromLibraryTestRan = false
    /// the photos' renders for the sheet's preview, by path, with their sidecars' dates
    @ObservationIgnored var compositeRenders: [String: (date: Date?, image: CIImage)] = [:]
    /// the base photo's subject for the preview, by path
    @ObservationIgnored var compositeMattes: [String: CIImage?] = [:]
    @ObservationIgnored let compositeContext = CIContext()

    /// AI denoise's amount (1 to 100) on the open photo, or nil when it's off.
    /// It works on the raw in place (Engine.setDenoise), so the edit carries
    /// on as before and the amount can change at any time. The catalog keeps
    /// it per photo.
    private(set) var aiDenoise: Double?
    /// whether the engine has the open raw's denoised data
    private var denoiseSent = false
    /// photos whose profiled denoise AI denoise turned off, to turn it back on with it
    private var profiledTurnedOff: Set<String> = []

    /// a Bayer raw that darktable decodes, with the model installed
    var canAIDenoise: Bool {
        url != nil && sensor == "bayer" && decodedTIFF == nil && photosAsset == nil
            && RawDenoise.isAvailable && url.map(Library.isRaw) == true
    }

    /// Turns AI denoise on at `amount` (1 to 100), changes its amount, or
    /// turns it off (nil or 0). The model runs once per raw; its result is
    /// cached, so after that only the blend and the render are redone. On, it
    /// turns profiled denoise off, as there's no noise left for it.
    func setAIDenoise(_ amount: Double?, restoring: Bool = false) async {
        guard canAIDenoise, !isDenoising, let engine, let url else { return }
        let on = (amount ?? 0) > 0
        if on, !denoiseSent, !restoring, await !ensureModel(.rawDenoise) { return }
        do {
            if on && !denoiseSent {
                isDenoising = true
                defer { isDenoising = false; statusNote = nil }
                statusNote = "Denoising…"
                let file = try await denoisedMosaic(for: url, engine: engine)
                guard self.url == url else { return }
                try await engine.setDenoise(mosaic: file, amount: amount! / 100)
                denoiseSent = true
            } else if on || denoiseSent {
                try await engine.setDenoise(mosaic: nil, amount: on ? amount! / 100 : 0)
            }
        } catch {
            errorMessage = "Couldn't denoise: \(error.localizedDescription)"
            return
        }
        aiDenoise = on ? amount : nil
        catalog.setAIDenoise(aiDenoise, for: url)
        if !restoring {
            let profiled = modules.first { $0.op == "denoiseprofile" }
            if on, let profiled, profiled.enabled {
                setEnabled(false, module: profiled.key)
                profiledTurnedOff.insert(url.path)
            } else if !on, let profiled, !profiled.enabled, profiledTurnedOff.remove(url.path) != nil {
                setEnabled(true, module: profiled.key)
            }
        }
        beforeKey = ""
        requestRender()
    }

    /// The raw denoised at full strength, as uint16 sensor values: from the
    /// cache, keyed to the file's path, size and date, or from the model.
    private func denoisedMosaic(for url: URL, engine: Engine) async throws -> URL {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.photoFile.path)
        let stamp = "\(url.photoFile.path)|\((attributes?[.size] as? Int) ?? 0)|\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let digest = SHA256.hash(data: Data(stamp.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Darkslide/denoised", isDirectory: true)
        let file = folder.appendingPathComponent("\(digest).u16")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mosaicIn = FileManager.default.temporaryDirectory.appendingPathComponent("darkslide-mosaic-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: mosaicIn) }
        let started = Date()
        let layout = try await engine.rawMosaic(to: mosaicIn)
        let progress: @Sendable (Double) -> Void = { p in
            Task { @MainActor [weak self] in
                if self?.isDenoising == true { self?.statusNote = "Denoising… \(Int(p * 100))%" }
            }
        }
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: mosaicIn)
            let mosaic = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let out = try RawDenoise.run(mosaic, layout: layout, progress: progress)
            try out.withUnsafeBytes { try Data($0).write(to: file, options: .atomic) }
        }.value
        FileHandle.standardError.write("Darkslide AI denoise of \(url.lastPathComponent) in \(Int(Date().timeIntervalSince(started) * 1000)) ms\n".data(using: .utf8)!)
        return file
    }

    /// the last amount chosen, 0 to 100, remembered between photos
    static var denoiseAmount: Double {
        get { UserDefaults.standard.object(forKey: "DenoiseAmount") == nil ? 100 : UserDefaults.standard.double(forKey: "DenoiseAmount") }
        set { UserDefaults.standard.set(newValue, forKey: "DenoiseAmount") }
    }

    /// Image › Denoise to New DNG: as Lightroom's Denoise, a new raw next to
    /// the original with the noise taken out before demosaicing (RawDenoise),
    /// carrying the edit as it is now, then opened. `amount` (0 to 100) blends
    /// the denoised sensor values with the original ones. darktable's own
    /// noise reduction is turned off in it, as the noise is gone.
    func denoiseToDNG(amount: Double) async {
        guard canDenoise, let engine, let url else { return }
        isDenoising = true
        defer { isDenoising = false; statusNote = nil }
        statusNote = "Denoising…"
        await settleEdits()
        let temp = FileManager.default.temporaryDirectory
        let mosaicIn = temp.appendingPathComponent("darkslide-mosaic-\(UUID().uuidString)")
        let mosaicOut = temp.appendingPathComponent("darkslide-denoised-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: mosaicIn)
            try? FileManager.default.removeItem(at: mosaicOut)
        }
        let dest = Self.denoisedName(for: url)
        do {
            let started = Date()
            let layout = try await engine.rawMosaic(to: mosaicIn)
            let progress: @Sendable (Double) -> Void = { p in
                Task { @MainActor [weak self] in
                    if self?.isDenoising == true { self?.statusNote = "Denoising… \(Int(p * 100))%" }
                }
            }
            try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: mosaicIn)
                let mosaic = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let out = try RawDenoise.run(mosaic, layout: layout, strength: Float(amount / 100), progress: progress)
                try out.withUnsafeBytes { try Data($0).write(to: mosaicOut) }
            }.value
            statusNote = "Writing the DNG…"
            try await engine.writeDNG(mosaic: mosaicOut, to: dest)
            FileHandle.standardError.write("Darkslide denoised to \(dest.path) in \(Int(Date().timeIntervalSince(started) * 1000)) ms\n".data(using: .utf8)!)
        } catch {
            errorMessage = "Couldn't denoise: \(error.localizedDescription)"
            return
        }
        isDenoising = false
        await open(dest)
        guard self.url == dest else { return }
        if let nr = modules.first(where: { $0.op == "denoiseprofile" && $0.enabled }) {
            setEnabled(false, module: nr.key)
            await settleEdits()
            await save()
        }
    }

    /// "DSC_0001-Denoised.dng" next to the original, numbered if it's taken
    nonisolated static func denoisedName(for url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + "-Denoised"
        var candidate = folder.appendingPathComponent(base + ".dng")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n).dng")
            n += 1
        }
        return candidate
    }

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

    /// darktable's metering puts the raw median four stops under white. With a
    /// bright sky or backlight in the frame that leaves the photo dark (a dusk
    /// portrait came out a stop and a half under). So Auto then looks at the
    /// photo as it renders, and if its middle tone is more than a third of a
    /// stop under a typical photo's, lifts the exposure, at most 2 EV: a few
    /// passes, as the tone mapper doesn't pass exposure through one to one.
    /// It only lifts, as a dark scene left dark is a choice the metering can't
    /// see, and a bright one is held by the tone mapper.
    func liftDarkExposure() async {
        guard !openedAsHDR, let key = modules.first(where: { $0.op == "exposure" })?.key else { return }
        // display-linear: a typical photo's median, about 40% in sRGB
        let target = 0.13
        var lifted = 0.0
        for _ in 0..<3 {
            await settleEdits()
            guard let median = await renderedMedian(), median > 0.0005,
                  let ev = modules.first(where: { $0.key == key })?.fields.first(where: { $0.name == "exposure" })?.value.number
            else { return }
            let under = log2(target / median)
            if UserDefaults.standard.bool(forKey: "LogRenderTimes") {
                FileHandle.standardError.write(String(format: "Darkslide auto lift: median %.3f, %.2f EV under, exposure %.2f\n", median, under, ev).data(using: .utf8)!)
            }
            guard under > 1.0 / 3 else { break }
            // the tone mapper's mid-tones turn a stop of exposure into about 1.4 on screen
            let step = min(under / 1.4, 2 - lifted)
            guard step > 0.05 else { break }
            lifted += step
            let next = ((ev + step) * 100).rounded() / 100
            setValue(.number(next), module: key, field: "exposure")
            // this is Auto's exposure now: the pill shows on
            autoExposure = next
        }
    }

    /// the median display-linear luminance of a small SDR render as edited
    private func renderedMedian() async -> Double? {
        guard let engine,
              let frame = try? await engine.render(maxPixels: 400, hdr: false, displayHeadroom: 1, wantOverlay: false)
        else { return nil }
        let image = frame.image
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func linear(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let table = (0...255).map { linear(UInt8($0)) }
        var lum = [Double]()
        lum.reserveCapacity(w * h)
        for i in stride(from: 0, to: px.count, by: 4) {
            lum.append(0.2126 * table[Int(px[i])] + 0.7152 * table[Int(px[i + 1])] + 0.0722 * table[Int(px[i + 2])])
        }
        lum.sort()
        return lum.isEmpty ? nil : lum[lum.count / 2]
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
    let cleanUp: [CleanUpMark]
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
        if let gesture, let last = lastGesture, last.key == gesture, sliderDragging || now - last.time < .seconds(1) {
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
                 styleEnds: styleHistoryEnds, editsSinceStyle: editsSinceStyle, cleanUp: cleanUpMarks)
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
        if target.cleanUp != cleanUpMarks { restoreObjectMarks(target.cleanUp) }
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
        isRemovingSpots = false
        isRemovingObjects = false
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
        if mode != .map, library.source == .map, let folder = library.lastFolder { library.show(folder: folder) }
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
        func log(_ s: String) { FileHandle.standardError.write("Darkslide match locations: \(s)\n".data(using: .utf8)!) }
        let exts: Set<String> = ["nef", "nefx", "hif", "heic", "jpg", "jpeg", "dng"]
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
            // metadata, not an edit: the photo doesn't join Edited for it
            if let rating { library.noteRating(rating, for: [photo]) }
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
            // the photo selected in the grid, as Return opens it
            if let selected = library.selection, selected != libraryURL {
                Task { await open(selected) }
            } else if url != nil {
                showingLibrary = false
            }
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
        let settings = AppleRawSettings.stored(for: url)
        let decoded = try await Task.detached(priority: .userInitiated) {
            try AppleRawFallback.decodedTIFF(for: url, version: version, settings: settings)
        }.value
        appleRawSettings = settings
        appleRawControls = decoded.controls
        appleRawLensDefault = decoded.lensCorrection
        AppleRawFallback.sidecarToDecoded(original: url, decoded: decoded.url, raw: true)
        let reply = try await engine.open(decoded.url, hdrSource: true)
        decodedTIFF = decoded.url
        decoderInUse = AppleRawFallback.versionName(decoded.version)
        openedAsHDR = true
        return reply
    }

    /// Apple raw engine settings (the Apple RAW card): a change is kept for
    /// the photo and, once the slider rests, the raw is decoded again with it;
    /// darktable's edits carry over through the sidecar.
    func setAppleRaw(_ key: String, to value: Double?) {
        if let value { appleRawSettings.values[key] = value } else { appleRawSettings.values[key] = nil }
        appleRawChanged()
    }

    func setAppleRawLensCorrection(_ on: Bool?) {
        appleRawSettings.lensCorrection = on
        appleRawChanged()
    }

    func resetAppleRaw() {
        appleRawSettings = AppleRawSettings()
        appleRawChanged()
    }

    private func appleRawChanged() {
        guard let photo = url else { return }
        appleRawSettings.store(for: photo)
        appleRawDecode?.cancel()
        appleRawDecode = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, url == photo else { return }
            await settleEdits()
            if hasUnsavedChanges { await save() }
            await reopen()
        }
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
        guard let src = CGImageSourceCreateWithURL(url.photoFile as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
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
    enum Kind { case gradient, ellipse, subject, brush }
    let kind: Kind
    /// a brush's strokes, painting or erasing
    var strokes: [BrushStroke] = []
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

/// A brush stroke in output pixels.
struct BrushStroke: Equatable {
    var points: [CGPoint]
    var radius: Double
    var erase = false
    /// a pen's stroke: each point's size, as a fraction of `radius`, and its opacity
    var sizes: [Double]? = nil
    var opacities: [Double]? = nil
}

/// What a pen's pressure changes, as darktable's brush offers.
enum BrushPressure: String, CaseIterable, Identifiable {
    case size, opacity, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .size: "Size"
        case .opacity: "Opacity"
        case .off: "Off"
        }
    }
}

/// A pen stroke's pressure, one reading a point, and what it changes.
struct PenPressure {
    var values: [Double]
    var mode: BrushPressure

    func add(to body: inout [String: Any]) {
        guard mode != .off else { return }
        body["pressure"] = values
        body["pressureMode"] = mode.rawValue
    }
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
    /// An adjustment's exposure instance holds its shape; the other modules it
    /// uses (colour balance rgb, local contrast) are instances of the same name
    /// sharing that shape, added the first time one of their sliders moves.
    nonisolated static func isLocal(_ m: EngineModule) -> Bool { m.instanceName.hasPrefix("Local ") }

    /// An adjustment's darktable name is "Local n", which is how the app finds
    /// it, then its title if it has one: "Local 2: Sky". Its number, and the
    /// title shown for it.
    nonisolated static func localNumber(_ m: EngineModule) -> Int? {
        Int(m.instanceName.dropFirst("Local ".count).prefix { $0.isNumber })
    }
    func localTitle(_ m: EngineModule) -> String {
        let name = m.instanceName
        if let colon = name.range(of: ": "), !name[colon.upperBound...].isEmpty { return String(name[colon.upperBound...]) }
        return name
    }

    /// the next free "Local n", with a title if given
    func nextLocalName(titled title: String? = nil) -> String {
        let used = Set(localAdjustments.compactMap(Self.localNumber))
        let n = (1...).first { !used.contains($0) }!
        return title.map { "Local \(n): \($0)" } ?? "Local \(n)"
    }

    /// Renames an adjustment (all its instances, which share the name);
    /// an empty title goes back to "Local n".
    func renameLocal(_ key: String, to title: String) {
        guard let engine, let anchor = modules.first(where: { $0.key == key }), let n = Self.localNumber(anchor) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ": ", with: " ")
        // darktable keeps 128 bytes of a module's name
        let name = String((clean.isEmpty || clean == "Local \(n)" ? "Local \(n)" : "Local \(n): \(clean)").utf8.prefix(120)) ?? "Local \(n)"
        guard name != anchor.instanceName else { return }
        let parts = localParts(anchor).map(\.key)
        Task {
            await settleEdits()
            recordUndoStep(label: "Rename Local Adjustment")
            await settleEdits()
            do {
                for k in parts { modules = try await engine.renameInstance(k, to: name) }
                hasUnsavedChanges = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    var localAdjustments: [EngineModule] {
        modules.filter { Self.isLocal($0) && $0.op == "exposure" }.sorted { $0.instanceName < $1.instanceName }
    }
    /// the instances making up the adjustment that `anchor` holds the shape of
    func localParts(_ anchor: EngineModule) -> [EngineModule] {
        modules.filter { Self.isLocal($0) && $0.instanceName == anchor.instanceName }
    }

    /// A local slider's value, from whichever instance holds it (or neutral).
    func localValue(_ control: LocalControl, of anchor: EngineModule) -> Double {
        guard let m = localParts(anchor).first(where: { $0.op == control.op }) else { return 0 }
        return control.value(from: m)
    }

    func setLocal(_ control: LocalControl, to value: Double, of anchor: EngineModule) {
        if let m = localParts(anchor).first(where: { $0.op == control.op }) {
            for (field, v) in control.fields(for: value) { setValue(.number(v), module: m.key, field: field) }
            return
        }
        // the module's first slider moved: add its instance, sharing the shape,
        // and hold the latest value until it's there
        pendingLocalValues[anchor.instanceName + "|" + control.op] = (control, value)
        guard let engine, !addingLocalPart.contains(anchor.instanceName + "|" + control.op),
              let base = modules.first(where: { $0.op == control.op && !Self.isLocal($0) }) else { return }
        let id = anchor.instanceName + "|" + control.op
        addingLocalPart.insert(id)
        Task {
            defer { addingLocalPart.remove(id) }
            await settleEdits()
            do {
                let reply = try await engine.addLocal(base: base.key, shareWith: anchor.key, name: anchor.instanceName)
                modules = reply.modules
                // instances start at the module's defaults, which aren't all neutral
                for (field, v) in control.neutral { setValue(.number(v), module: reply.added, field: field) }
                if let (c, v) = pendingLocalValues.removeValue(forKey: id) {
                    for (field, x) in c.fields(for: v) { setValue(.number(x), module: reply.added, field: field) }
                }
            } catch {
                errorMessage = "Couldn't add to the adjustment: \(error.localizedDescription)"
            }
        }
    }

    func addLocal(_ kind: LocalShape.Kind) {
        guard let engine, url != nil,
              let base = modules.first(where: { $0.op == "exposure" && !Self.isLocal($0) }) else { return }
        let name = nextLocalName()
        Task {
            await settleEdits()
            recordUndoStep(label: "Add \(kind == .gradient ? "Linear Gradient" : "Radial Gradient")")
            // its history position, before the engine moves on from it
            await settleEdits()
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
                case .subject, .brush:
                    break   // addSubject, paintStroke
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
        let name = nextLocalName()
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
                // its history position, before the engine moves on from it
                await settleEdits()
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
            // its history position, before the engine moves on from it
            await settleEdits()
            do {
                let parts = modules.first { $0.key == key }.map(localParts)?.map(\.key) ?? [key]
                for k in parts {
                    try await engine.enable(module: k, on: false)
                    modules = try await engine.renameInstance(k, to: Self.deletedLocalName)
                }
                hasUnsavedChanges = true
                requestRender()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func fetchFocusOutline() async {
        guard showFocusPoint, canShowFocusPoint, let engine, let box = cameraFocus?.box, let shown = url else { focusOutline = nil; return }
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        let mapped = try? await engine.toOutput(corners)
        guard url == shown else { return }
        focusOutline = mapped
        // TestFocus: launch argument (-TestFocus YES) for testing
        if UserDefaults.standard.bool(forKey: "TestFocus") {
            FileHandle.standardError.write("Darkslide focus test: \(cameraFocus.map { "\($0.mode ?? "-") \($0.area ?? "-") \($0.inFocus.map(String.init) ?? "-") box \($0.box.map { "\($0)" } ?? "-")" } ?? "-") image \(Int(imageSize.width))x\(Int(imageSize.height)) outline \(mapped.map { $0.map { "(\(Int($0.x)),\(Int($0.y)))" }.joined(separator: " ") } ?? "-")\n".data(using: .utf8)!)
        }
    }

    func fetchLocalShape() async {
        guard let engine, let key = selectedLocal, let r = try? await engine.shape(module: key) else { return }
        let pts = stride(from: 0, to: r.points.count - 1, by: 2).map { CGPoint(x: r.points[$0], y: r.points[$0 + 1]) }
        guard selectedLocal == key, pendingShape == nil, !sendingShape else { return }
        let kind: LocalShape.Kind = switch r.kind {
        case "ellipse": .ellipse
        case "subject": .subject
        case "brush": .brush
        default: .gradient
        }
        if kind == .brush {
            // each stroke: x, y, … then its radius and 1 if it erases
            var strokes = (r.outlines ?? []).compactMap { o -> BrushStroke? in
                guard o.count >= 4 else { return nil }
                let xy = o.dropLast(2)
                let points = stride(from: xy.startIndex, to: xy.endIndex - 1, by: 2).map { CGPoint(x: o[$0], y: o[$0 + 1]) }
                return BrushStroke(points: points, radius: o[o.count - 2], erase: o[o.count - 1] > 0.5)
            }
            // a pen's: each point's size and density (strokes without pressure are all 1)
            for (i, sd) in (r.pointSizes ?? []).enumerated() where i < strokes.count && sd.count == 2 * strokes[i].points.count {
                let sizes = stride(from: 0, to: sd.count, by: 2).map { sd[$0] }
                let opacities = stride(from: 1, to: sd.count, by: 2).map { sd[$0] }
                if sizes.contains(where: { abs($0 - 1) > 0.01 }) { strokes[i].sizes = sizes }
                if opacities.contains(where: { $0 < 0.99 }) { strokes[i].opacities = opacities }
            }
            localShape = LocalShape(kind: .brush, strokes: strokes, points: [])
            return
        }
        let outlines = (r.outlines ?? []).map { o in stride(from: 0, to: o.count - 1, by: 2).map { CGPoint(x: o[$0], y: o[$0 + 1]) } }
        localShape = LocalShape(kind: kind, outlines: outlines, points: pts,
                                compression: r.compression ?? 0.3, border: r.border ?? 0.5)
    }

    /// Makes the live look of a stroke about to be painted, from the frame on
    /// screen and the adjustment's settings (a Quick Brush's, before its first stroke).
    func startBrushPreview(erase: Bool) {
        brushPreview = nil
        guard let frame = image else { return }
        let values: [(LocalControl, Double)]
        if let brush = pendingBrush {
            values = brush.values
        } else if let key = selectedLocal, let anchor = modules.first(where: { $0.key == key }) {
            values = LocalControl.allCases.map { ($0, localValue($0, of: anchor)) }
        } else { return }
        guard let made = BrushPreview.image(of: frame, values: values, erase: erase) else { return }
        let m = frameMapping(frame, crop: currentCrop)
        brushPreview = (made, CGPoint(x: m.x / m.scale, y: m.y / m.scale),
                        CGSize(width: Double(frame.width) / m.scale, height: Double(frame.height) / m.scale))
    }

    func endBrushPreview() { brushPreview = nil }

    /// whether the photo is being painted: a Quick Brush waiting, or a brushed adjustment selected
    var isBrushing: Bool { pendingBrush != nil || localShape?.kind == .brush }

    /// Chooses a Quick Brush: its adjustment is made by the first stroke.
    func startBrush(_ brush: QuickBrush) {
        selectedLocal = nil
        brushErases = false
        pendingBrush = brush
    }

    /// A stroke, in output pixels: the first of a Quick Brush makes its
    /// adjustment (an exposure instance masked by darktable's brush, its
    /// values set as the brush has them); the rest paint more of the
    /// selected one in, or erase it.
    func paintStroke(_ points: [CGPoint], erase: Bool, pressure: [Double]? = nil) {
        guard let engine, url != nil, !points.isEmpty else { return }
        let radius = brushSize * min(imageSize.width, imageSize.height)
        let hardness = 1 - brushSoftness
        let pen = pressure.flatMap { $0.count == points.count ? PenPressure(values: $0, mode: penPressure) : nil }
        if let brush = pendingBrush {
            guard !erase, let base = modules.first(where: { $0.op == "exposure" && !Self.isLocal($0) }) else { return }
            pendingBrush = nil
            let name = nextLocalName(titled: brush == .plain ? nil : brush.title)
            Task {
                await settleEdits()
                recordUndoStep(label: brush.title)
                // its history position, before the engine moves on from it
                await settleEdits()
                do {
                    let reply = try await engine.addBrush(base: base.key, name: name, points: points, radius: radius,
                                                          hardness: hardness, pressure: pen)
                    modules = reply.modules
                    hasUnsavedChanges = true
                    selectedLocal = reply.added
                    if let anchor = modules.first(where: { $0.key == reply.added }) {
                        for (control, value) in brush.values { setLocal(control, to: value, of: anchor) }
                    }
                    requestRender()
                } catch {
                    errorMessage = "Couldn't make the brush: \(error.localizedDescription)"
                }
            }
            return
        }
        guard let key = selectedLocal, let anchor = modules.first(where: { $0.key == key }) else { return }
        let others = localParts(anchor).map(\.key).filter { $0 != key }
        Task {
            await settleEdits()
            recordUndoStep(label: erase ? "Erase Brush" : "Brush")
            // its history position, before the engine moves on from it
            await settleEdits()
            do {
                try await engine.addStroke(module: key, also: others, points: points, radius: radius,
                                           hardness: hardness, erase: erase, pressure: pen)
                hasUnsavedChanges = true
                await fetchLocalShape()
                requestRender()
            } catch {
                errorMessage = "Couldn't paint: \(error.localizedDescription)"
            }
        }
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

// MARK: - Loupe

extension EditorModel {
    /// The loupe over a point of the photo (output pixels), or off it.
    func pointLoupe(at p: CGPoint?) {
        guard showLoupe else { return }
        loupeCenter = p
        guard let p else { return }
        // still well inside the image there is: the lens moves over it, no render needed
        if let c = loupeCovers, c.zoom == loupeZoom,
           c.rect.insetBy(dx: 300 / loupeZoom, dy: 300 / loupeZoom).contains(p) { return }
        loupeDirty = true
        pump()
    }

    /// renders the square around the loupe's centre at its zoom, as the canvas renders a zoomed view
    fileprivate func renderLoupe(_ engine: Engine) async {
        guard showLoupe, let c = loupeCenter, url != nil else { return }
        let s = loupeZoom, side = Self.loupeSide
        let iw = Int(imageSize.width * s), ih = Int(imageSize.height * s)
        let w = min(side, iw), h = min(side, ih)
        let crop = Engine.Crop(scale: s, x: max(0, min(Int(c.x * s) - w / 2, iw - w)),
                               y: max(0, min(Int(c.y * s) - h / 2, ih - h)), w: w, h: h)
        guard let frame = try? await engine.render(maxPixels: side, hdr: viewHDR, displayHeadroom: displayHeadroom,
                                                   wantOverlay: false, crop: crop,
                                                   overrides: (showsSDRVersion ? sdrOverrides : []) + cropOverrides + curveOverrides,
                                                   hdrLimit: viewHDR ? hdrLimit : nil),
              showLoupe else { return }
        loupeImage = frame.image
        loupeOrigin = CGPoint(x: Double(crop.x) / s, y: Double(crop.y) / s)
        // a side at the photo's edge counts as covered beyond it, as there's nothing more to render
        let far = 1e9
        let minX = crop.x == 0 ? -far : Double(crop.x) / s, maxX = crop.x + w >= iw ? far : Double(crop.x + w) / s
        let minY = crop.y == 0 ? -far : Double(crop.y) / s, maxY = crop.y + h >= ih ? far : Double(crop.y + h) / s
        loupeCovers = (CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), s)
    }
}

// MARK: - Remove Objects

extension EditorModel {
    var canRemoveObjects: Bool { Inpainter.isAvailable || ModelStore.isOffered(.removeObjects) }

    /// where a frame sits on the output: output pixels times `scale`, less (x, y)
    func frameMapping(_ frame: CGImage, crop: Engine.Crop?) -> (scale: Double, x: Double, y: Double) {
        if let crop { return (crop.scale, Double(crop.x), Double(crop.y)) }
        return (Double(frame.width) / max(imageSize.width, 1), 0, 0)
    }

    /// Paints out a stroke, in output pixels, with the brush's radius.
    func addObjectMark(_ points: [CGPoint], radius: Double) {
        guard let engine, let photo = url, !points.isEmpty else { return }
        Task {
            if !Inpainter.isAvailable { guard await ensureModel(.removeObjects) else { return } }
            guard let input = try? await engine.toInput(points), photo == url else { return }
            // the step holds the marks as they were, so undo takes this one away
            recordUndoStep(label: "Remove Object")
            let shorter = min(imageSize.width, imageSize.height)
            let mark = CleanUpMark(points: input, radius: radius / max(shorter, 1))
            cleanUpMarks.append(mark)
            placedMarks[mark.id] = PlacedMark(points: points, radius: radius)
            selectedMark = mark.id
            catalog.setCleanUp(cleanUpMarks, for: photo)
            editedSinceOpen = true
            requestRender()
        }
    }

    func removeObjectMark(_ id: UUID) {
        guard let photo = url, cleanUpMarks.contains(where: { $0.id == id }) else { return }
        recordUndoStep(label: "Restore Object")
        cleanUpMarks.removeAll { $0.id == id }
        placedMarks[id] = nil
        if selectedMark == id { selectedMark = nil }
        catalog.setCleanUp(cleanUpMarks, for: photo)
        if cleanUpMarks.isEmpty { lastFill = nil }
        editedSinceOpen = true
        requestRender()
    }

    func removeAllObjectMarks() {
        guard let photo = url, !cleanUpMarks.isEmpty else { return }
        recordUndoStep(label: "Restore All Objects")
        cleanUpMarks = []
        placedMarks = [:]
        selectedMark = nil
        lastFill = nil
        catalog.setCleanUp([], for: photo)
        editedSinceOpen = true
        requestRender()
    }

    /// The marks an undo or redo goes back to.
    fileprivate func restoreObjectMarks(_ marks: [CleanUpMark]) {
        guard let photo = url else { return }
        cleanUpMarks = marks
        placedMarks = placedMarks.filter { id, _ in marks.contains { $0.id == id } }
        if let sel = selectedMark, !marks.contains(where: { $0.id == sel }) { selectedMark = nil }
        if marks.isEmpty { lastFill = nil }
        catalog.setCleanUp(marks, for: photo)
        // where the marks brought back fall comes with the next render's fill
        Task { await placeObjectMarks() }
    }

    /// the marks on the output now, from darktable's input through the edit's crop and distortions
    func placeObjectMarks() async {
        guard let engine, !cleanUpMarks.isEmpty else { placedMarks = [:]; return }
        let shorter = min(imageSize.width, imageSize.height)
        var placed: [UUID: PlacedMark] = [:]
        for m in cleanUpMarks {
            guard let pts = try? await engine.toOutput(m.points) else { continue }
            placed[m.id] = PlacedMark(points: pts, radius: m.radius * shorter)
        }
        placedMarks = placed
    }

    /// The marks on a frame, in its pixels.
    private func marks(on frame: CGImage, crop: Engine.Crop?) -> [PlacedMark] {
        let m = frameMapping(frame, crop: crop)
        return cleanUpMarks.compactMap { placedMarks[$0.id]?.scaled(m.scale, dx: m.x, dy: m.y) }
            .filter { $0.bounds.intersects(CGRect(x: 0, y: 0, width: frame.width, height: frame.height)) }
    }

    /// The frame with the last fill laid over the marks, at once, until it's filled itself.
    private func laidOverLastFill(_ frame: CGImage, crop: Engine.Crop?) -> CGImage {
        guard let last = lastFill, !cleanUpMarks.isEmpty, !placedMarks.isEmpty else { return frame }
        let m = frameMapping(frame, crop: crop)
        let h = Double(frame.height)
        // the last fill's CI coordinates to output pixels (top left), then to this frame's CI coordinates
        let t = CGAffineTransform(translationX: last.x, y: -last.height - last.y)
            .concatenating(CGAffineTransform(scaleX: 1 / last.scale, y: -1 / last.scale))
            .concatenating(CGAffineTransform(scaleX: m.scale, y: -m.scale))
            .concatenating(CGAffineTransform(translationX: -m.x, y: h + m.y))
        let marks = marks(on: frame, crop: crop)
        guard !marks.isEmpty else { return frame }
        var mask = [UInt8](repeating: 0, count: frame.width * frame.height)
        for mk in marks {
            let r = Inpainter.raster(mk, width: frame.width, height: frame.height, grow: 1.1)
            for i in r.indices where r[i] > mask[i] { mask[i] = r[i] }
        }
        let maskImage = CIImage(bitmapData: Data(mask.flatMap { [$0, $0, $0, 255] }), bytesPerRow: frame.width * 4,
                                size: CGSize(width: frame.width, height: frame.height), format: .RGBA8, colorSpace: nil)
        let out = last.image.transformed(by: t).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(cgImage: frame), kCIInputMaskImageKey: maskImage,
        ])
        return Inpainter.image(out, like: frame) ?? frame
    }

    /// Fills the marks on a full frame in the background, and shows it if
    /// nothing newer has arrived.
    private func fillObjects(in frame: CGImage, crop: Engine.Crop?) {
        fillTask?.cancel()
        let shownFrame = frameID
        fillTask = Task {
            isFillingObjects = true
            defer { isFillingObjects = false }
            await placeObjectMarks()
            let marks = marks(on: frame, crop: crop)
            guard !Task.isCancelled, !marks.isEmpty, Inpainter.isAvailable else { return }
            let headroom = max(Double(frame.contentHeadroom), 1)
            let filled: CIImage
            do {
                filled = try await Inpainter.shared.fill(CIImage(cgImage: frame), marks: marks, headroom: headroom)
            } catch {
                errorMessage = "Couldn't remove the objects: \(error.localizedDescription)"
                return
            }
            guard !Task.isCancelled, frameID == shownFrame,
                  let shown = await Task.detached(operation: { Inpainter.image(filled, like: frame) }).value else { return }
            let m = frameMapping(frame, crop: crop)
            lastFill = (filled, m.scale, m.x, m.y, Double(frame.height))
            image = shown
            if crop == nil, !isCropping { thumbnailFrame = shown }
        }
    }
}

// MARK: - Spot removal

extension EditorModel {
    func fetchSpots() async {
        guard let engine, let found = try? await engine.spots() else { return }
        if pendingSpot == nil, !sendingSpot { spots = found }
    }

    /// A spot where the photo was clicked (output pixels), healed from the
    /// nearby patch whose surroundings match best (SpotSource).
    func addSpot(at c: CGPoint) {
        guard let engine, url != nil else { return }
        let r = spotSize * min(imageSize.width, imageSize.height)
        let source = SpotSource.find(for: c, radius: r, in: image, shown: imageIsZoomed ? shownCrop : nil, size: imageSize)
        Task {
            await settleEdits()
            recordUndoStep(label: spotClones ? "Clone Spot" : "Heal Spot")
            // its history position, before the engine moves on from it
            await settleEdits()
            do {
                let reply = try await engine.addSpot(at: c, radius: r, source: source, clone: spotClones)
                if let m = reply.modules { modules = m }
                spots = reply.spots
                selectedSpot = reply.added
                hasUnsavedChanges = true
                requestRender()
            } catch {
                errorMessage = "Couldn't remove the spot: \(error.localizedDescription)"
            }
        }
    }

    /// A drag on a spot or its source: only the latest goes to the engine.
    func moveSpot(_ s: Engine.Spot) {
        guard let engine, let i = spots.firstIndex(where: { $0.id == s.id }) else { return }
        spots[i] = s
        recordUndoStep(label: "Move Spot", gesture: "spot:\(s.id)")
        hasUnsavedChanges = true
        pendingSpot = s
        guard !sendingSpot else { return }
        sendingSpot = true
        Task {
            defer { sendingSpot = false }
            await settleEdits()
            while let e = pendingSpot {
                pendingSpot = nil
                try? await engine.moveSpot(e)
                requestRender()
            }
        }
    }

    func removeSpot(_ id: Int) {
        guard let engine else { return }
        if selectedSpot == id { selectedSpot = nil }
        Task {
            await settleEdits()
            recordUndoStep(label: "Remove Spot")
            // its history position, before the engine moves on from it
            await settleEdits()
            if let left = try? await engine.removeSpot(id) { spots = left }
            hasUnsavedChanges = true
            requestRender()
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
        let started = Date()
        await settleEdits()
        let settled = Date()
        var overrides: [Engine.Override] = []
        if let lut = modules.first(where: { $0.op == "lut3d" && $0.key.hasSuffix(":0") }), lut.enabled {
            overrides.append(.init(module: lut.key, field: "", value: 0, disable: true))
        }
        // a few tries: the engine can be busy opening or rendering the photo
        for attempt in 1...3 {
            do {
                let frame = try await engine.render(maxPixels: 280, hdr: false, displayHeadroom: 1, wantOverlay: false,
                                                    overrides: overrides)
                lookPreviewBase = frame.image
                lookPreviewBaseID += 1
                lookPreviewError = nil
                if UserDefaults.standard.bool(forKey: "LogRenderTimes") {
                    FileHandle.standardError.write(String(format: "Darkslide look previews: settled %.2fs, rendered %.2fs\n",
                                                          settled.timeIntervalSince(started), Date().timeIntervalSince(settled)).data(using: .utf8)!)
                }
                return
            } catch {
                FileHandle.standardError.write("Darkslide look previews: attempt \(attempt) failed: \(error.localizedDescription)\n".data(using: .utf8)!)
                lookPreviewError = error.localizedDescription
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// the film look's speed, pushed or pulled, for the grain to match; nil without a film
    var currentFilmSpeed: Double? {
        filmLooks.first { $0.path == currentLook }.flatMap(FilmSpeed.of)
    }

    var grainModule: EngineModule? { modules.filter { $0.op == "grain" }.min { $0.key < $1.key } }

    /// Sets the grain's film speed to the film look's, if grain is on, as part
    /// of the undo step just recorded (choosing the film, or turning grain on).
    func matchGrainToFilm() {
        guard let iso = currentFilmSpeed, let grain = grainModule, grain.enabled else { return }
        undoGroupDepth += 1
        defer { undoGroupDepth -= 1 }
        setValue(.number(iso / FilmSpeed.grainFactor), module: grain.key, field: "scale")
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
                matchGrainToFilm()
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
        // a version's name is its original's, so it's renamed with that
        guard let current = url, photosAsset == nil, !current.isVersion else { return }
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
            // numbered now: once the original has moved, their names no longer parse
            let versions = PhotoVersion.all(of: current).dropFirst().map { ($0, $0.versionNumber) }
            do {
                try FileManager.default.moveItem(at: current, to: target)
                // darktable finds versions by their sidecars' names
                for (v, n) in versions where n > 0 {
                    try? FileManager.default.moveItem(atPath: v.path + ".xmp",
                                                      toPath: PhotoVersion.url(of: target, number: n).path + ".xmp")
                }
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
                errorMessage = "Darkslide needs access to Photos: allow it in System Settings › Privacy & Security › Photos."
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
                    try await exportGainMap(settings, to: destination, engine: engine)
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

// MARK: - Composite

extension EditorModel {
    /// New Composite… from the library's selection or the open photo: the
    /// first photo is the base, the rest blend into it.
    func newComposite(_ urls: [URL]) {
        guard let first = urls.first else { return }
        // the photos may have been edited since the last preview
        compositeRenders = [:]
        compositeMattes = [:]
        var draft = CompositeSettings(base: first.path)
        draft.layers = urls.dropFirst().filter { $0 != first }.map { CompositeSettings.Layer(path: $0.path) }
        compositeDraft = draft
    }

    /// the recipe of the open photo, when it's a composite made here
    var compositeRecipe: CompositeSettings? { url.flatMap { catalog.composite(of: $0) } }

    /// Edit Composite…: the open composite's recipe, to make a new version from
    func editComposite() {
        compositeRenders = [:]
        compositeMattes = [:]
        compositeDraft = compositeRecipe
    }

    /// a photo's render with its own saved edit, through darktable's export:
    /// a 16-bit Display P3 TIFF
    private func compositeRender(_ photo: URL, maxEdge: Int, engine: Engine) async throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("darkslide-layer-\(UUID().uuidString)")
        return try await engine.export(path: temp.path, format: "tiff", quality: 100, bitDepth: 16,
                                       maxEdge: maxEdge, profile: 26, source: photo)
    }

    private static func sidecarDate(_ photo: URL) -> Date? {
        let xmp = URL(fileURLWithPath: photo.path + ".xmp")
        return (try? xmp.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// a photo at preview size, rendered once (again when its edit changes)
    private func compositePreviewRender(_ photo: URL, engine: Engine) async throws -> CIImage {
        let date = Self.sidecarDate(photo)
        if let cached = compositeRenders[photo.path], cached.date == date { return cached.image }
        let file = try await compositeRender(photo, maxEdge: 1400, engine: engine)
        defer { try? FileManager.default.removeItem(at: file) }
        // into memory, as the file goes
        guard let read = CIImage(contentsOf: file), let cg = compositeContext.createCGImage(read, from: read.extent) else {
            throw EngineError(message: "Couldn't read the render of \(photo.lastPathComponent).")
        }
        let image = CIImage(cgImage: cg)
        compositeRenders[photo.path] = (date, image)
        return image
    }

    /// The sheet's preview of a composite.
    func compositePreview(_ draft: CompositeSettings) async throws -> CGImage? {
        guard let engine else { return nil }
        let base = try await compositePreviewRender(draft.baseURL, engine: engine)
        var layers: [(CIImage, CompositeSettings.Layer)] = []
        for layer in draft.layers {
            layers.append((try await compositePreviewRender(layer.url, engine: engine), layer))
        }
        var matte: CIImage?
        if draft.needsSubject {
            if let found = compositeMattes[draft.base] {
                matte = found
            } else if let cg = compositeContext.createCGImage(base, from: base.extent) {
                matte = try await Task.detached { try Compositor.subjectMatte(in: cg) }.value
                compositeMattes[draft.base] = matte
            }
        }
        let size = base.extent.size
        let out = Compositor.apply(draft, base: base, canvas: size, region: CGRect(origin: .zero, size: size),
                                   layers: layers, subject: matte, encoded: false)
        return compositeContext.createCGImage(out, from: base.extent, format: .RGBA8,
                                              colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
    }

    /// Makes the composite at full size as a new 16-bit TIFF next to the base,
    /// keeps its recipe and opens it. The photos it's made from are untouched.
    func createComposite(_ draft: CompositeSettings) async {
        guard let engine else { return }
        compositeDraft = nil
        let dest = Self.compositeName(for: draft.baseURL)
        var files: [URL] = []
        defer { for f in files { try? FileManager.default.removeItem(at: f) } }
        do {
            statusNote = "Rendering \(draft.baseURL.lastPathComponent)…"
            let baseFile = try await compositeRender(draft.baseURL, maxEdge: 0, engine: engine)
            files.append(baseFile)
            guard let base = CIImage(contentsOf: baseFile) else { throw EngineError(message: "Couldn't read the base photo's render.") }
            let long = Int(max(base.extent.width, base.extent.height))
            var layers: [(URL, CompositeSettings.Layer)] = []
            for layer in draft.layers {
                statusNote = "Rendering \(layer.url.lastPathComponent)…"
                let f = try await compositeRender(layer.url, maxEdge: long, engine: engine)
                files.append(f)
                layers.append((f, layer))
            }
            statusNote = "Making the composite…"
            try await Task.detached(priority: .userInitiated) {
                let read = layers.compactMap { f, l in CIImage(contentsOf: f).map { ($0, l) } }
                var matte: CIImage?
                if draft.needsSubject {
                    // found on the base at up to 2048 px
                    let e = base.extent
                    let s = min(1, 2048 / max(e.width, e.height))
                    let small = base.transformed(by: CGAffineTransform(scaleX: s, y: s))
                    if let cg = CIContext().createCGImage(small, from: small.extent.integral) {
                        matte = try Compositor.subjectMatte(in: cg)
                    }
                }
                let size = base.extent.size
                let out = Compositor.apply(draft, base: base, canvas: size, region: CGRect(origin: .zero, size: size),
                                           layers: read, subject: matte, encoded: false)
                try Self.writeTIFF16(out, properties: base.properties, to: dest)
            }.value
        } catch {
            statusNote = nil
            errorMessage = "Couldn't make the composite: \(error.localizedDescription)"
            return
        }
        statusNote = nil
        catalog.setComposite(draft, for: dest)
        await open(dest)
    }

    /// A new photo made here: a 16-bit Display P3 TIFF, LZW compressed, with
    /// the metadata of the photo it came from.
    nonisolated static func writeTIFF16(_ image: CIImage, properties: [String: Any], to dest: URL) throws {
        guard let cg = CIContext().createCGImage(image, from: image.extent, format: .RGBA16,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!),
              let file = CGImageDestinationCreateWithURL(dest as CFURL, UTType.tiff.identifier as CFString, 1, nil)
        else { throw EngineError(message: "Couldn't write \(dest.lastPathComponent).") }
        // the pixels are upright already
        var properties = properties
        properties.removeValue(forKey: kCGImagePropertyOrientation as String)
        var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFCompression as String] = 5
        tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation as String)
        properties[kCGImagePropertyTIFFDictionary as String] = tiff
        CGImageDestinationAddImage(file, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(file) else { throw EngineError(message: "Couldn't write \(dest.lastPathComponent).") }
    }

    /// "DSC_0001 Composite.tif" next to the base, numbered if it's taken
    nonisolated static func compositeName(for base: URL) -> URL {
        newPhotoName(for: base, suffix: "Composite")
    }

    /// "DSC_0001 <suffix>.tif" next to a photo, numbered if it's taken
    nonisolated static func newPhotoName(for base: URL, suffix: String) -> URL {
        let folder = base.deletingLastPathComponent()
        let name = base.deletingPathExtension().lastPathComponent + " " + suffix
        var candidate = folder.appendingPathComponent(name + ".tif")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(n).tif")
            n += 1
        }
        return candidate
    }
}

// MARK: - Models

extension EditorModel {
    /// Makes sure a model is here before it's used: if it isn't, asks to
    /// download it (ModelStore) and does, with its progress in the status
    /// line. False if it isn't here at the end: declined, or it failed.
    func ensureModel(_ model: ModelStore.Model) async -> Bool {
        if ModelStore.installedURL(model) != nil { return true }
        guard ModelStore.isOffered(model) else { return false }
        let alert = NSAlert()
        alert.messageText = "Download the \(model.title) model?"
        let size = ModelStore.downloadSize(model).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        alert.informativeText = "\(model.title) uses a machine learning model\(size.map { " of \($0)" } ?? "") that isn't built into Darkslide. "
            + "It's downloaded once from Darkslide's GitHub releases and kept for next time."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let title = model.title
        statusNote = "Downloading the \(title) model…"
        defer { statusNote = nil }
        do {
            _ = try await ModelStore.download(model) { p in
                Task { @MainActor [weak self] in
                    self?.statusNote = "Downloading the \(title) model… \(Int(p * 100))%"
                }
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - Rescue Focus

extension EditorModel {
    var canRescueFocus: Bool { url != nil && RescueFocus.isAvailable }

    /// the photo for Rescue Focus at full size with its saved edit, rendered once per sheet
    func rescueFocusImage(_ photo: URL) async throws -> CIImage {
        if let s = rescueFocusSource, s.url == photo { return s.image }
        guard let engine else { throw EngineError(message: "The engine isn't running.") }
        let file = try await compositeRender(photo, maxEdge: 0, engine: engine)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let read = CIImage(contentsOf: file),
              let cg = compositeContext.createCGImage(read, from: read.extent, format: .RGBA16,
                                                      colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
        else { throw EngineError(message: "Couldn't read the render of \(photo.lastPathComponent).") }
        let image = CIImage(cgImage: cg).settingProperties(read.properties)
        rescueFocusSource = (photo, image)
        return image
    }

    /// The matte of the subject at `centre` (0 to 1 across and down), or of
    /// all of them when it isn't on one, over the whole photo; nil when
    /// Vision finds no subject.
    func rescueFocusMatte(_ photo: URL, centre: CGPoint) async throws -> CIImage? {
        let image = try await rescueFocusImage(photo)
        let subjects: RescueFocus.Subjects?
        if let found = rescueFocusSubjects, found.url == photo {
            subjects = found.subjects
        } else {
            // Vision works at a few megapixels; the matte is soft and scales up
            let s = min(1, 2048 / max(image.extent.width, image.extent.height))
            let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
            guard let cg = compositeContext.createCGImage(small, from: small.extent.integral) else { return nil }
            subjects = try await Task.detached(priority: .userInitiated) { try RescueFocus.Subjects.find(in: cg) }.value
            rescueFocusSubjects = (photo, subjects)
        }
        guard let subjects else { return nil }
        let extent = image.extent
        return try await Task.detached(priority: .userInitiated) { try subjects.matte(at: centre, over: extent) }.value
    }

    /// A 512 px square of the photo at full size around `centre` (0 to 1 across
    /// and down), before and after, the rescue kept to `mask` if there is one.
    func rescueFocusPreview(_ photo: URL, kind: RescueFocus.Kind = .focus, centre: CGPoint, amount: Double,
                            mask: CIImage? = nil) async throws -> (before: CGImage, after: CGImage) {
        let image = try await rescueFocusImage(photo)
        let e = image.extent
        let side = min(512, e.width, e.height)
        let x = min(max(e.minX + centre.x * e.width - side / 2, e.minX), e.maxX - side)
        let y = min(max(e.maxY - centre.y * e.height - side / 2, e.minY), e.maxY - side)
        let crop = image.cropped(to: CGRect(x: x, y: y, width: side, height: side).integral)
        let cropMask = mask?.cropped(to: crop.extent)
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        return try await Task.detached(priority: .userInitiated) {
            let after = try RescueFocus.run(crop, kind: kind, amount: amount, space: space, mask: cropMask)
            let context = CIContext()
            guard let b = context.createCGImage(crop, from: crop.extent, format: .RGBA8, colorSpace: space),
                  let a = context.createCGImage(after, from: after.extent, format: .RGBA8, colorSpace: space)
            else { throw EngineError(message: "Couldn't show the preview.") }
            return (b, a)
        }.value
    }

    /// Rescues the whole photo into a new 16-bit TIFF next to it and opens that.
    func createRescueFocus(_ photo: URL, kind: RescueFocus.Kind = .focus, amount: Double, mask: CIImage? = nil) async {
        rescueFocusPhoto = nil
        let dest = Self.newPhotoName(for: photo, suffix: kind == .focus ? "Focus" : "Deblur")
        do {
            statusNote = "Rendering \(photo.lastPathComponent)…"
            let image = try await rescueFocusImage(photo)
            let progress: @Sendable (Double) -> Void = { p in
                Task { @MainActor [weak self] in self?.statusNote = "Rescuing focus… \(Int(p * 100))%" }
            }
            let started = Date()
            try await Task.detached(priority: .userInitiated) {
                let out = try RescueFocus.run(image, kind: kind, amount: amount, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                              mask: mask, progress: progress)
                try Self.writeTIFF16(out, properties: image.properties, to: dest)
            }.value
            FileHandle.standardError.write("Darkslide rescued focus into \(dest.lastPathComponent) in \(Int(Date().timeIntervalSince(started) * 1000)) ms\n".data(using: .utf8)!)
        } catch {
            statusNote = nil
            errorMessage = "Couldn't rescue the focus: \(error.localizedDescription)"
            return
        }
        statusNote = nil
        rescueFocusSource = nil
        rescueFocusSubjects = nil
        await open(dest)
    }
}

// MARK: - Rating and culling

extension EditorModel {
    /// Rates photos: 1 to 5 stars, 0 none, -1 rejected. Shown at once; the
    /// sidecars are written one after another behind, through darktable, so
    /// darktable and Lightroom see them.
    func setRating(_ value: Int, for photos: [URL]) {
        let files = photos.filter { PhotosLibrary.assetID($0) == nil }
        guard !files.isEmpty else { return }
        library.noteRating(value, for: files)
        ratingQueue.append(contentsOf: files.map { ($0, value) })
        guard !writingRatings else { return }
        writingRatings = true
        Task {
            defer { writingRatings = false }
            while !ratingQueue.isEmpty {
                let (photo, rating) = ratingQueue.removeFirst()
                // a later rating of the same photo wins; skip this one
                if ratingQueue.contains(where: { $0.0 == photo }) { continue }
                do {
                    try await engine?.setInfo(path: photo.path, rating: rating)
                    infoRevision += 1
                } catch {
                    errorMessage = "Couldn't save the rating to \(photo.lastPathComponent)'s sidecar: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Keeps one frame of a burst: it gets a star if it had none, and the
    /// burst's unrated frames are rejected. Rated frames are left as they are.
    func keepOnly(_ photo: URL) {
        let others = (culling.burst(of: photo) ?? []).filter { $0 != photo && library.rating(of: $0) == 0 }
        if library.rating(of: photo) <= 0 { setRating(1, for: [photo]) }
        if !others.isEmpty { setRating(-1, for: others) }
    }

    /// Every burst left unrated keeps its suggested frame, the rest rejected.
    /// Returns how many bursts it decided.
    @discardableResult
    func keepSuggestedInEveryBurst() -> Int {
        var keep: [URL] = [], reject: [URL] = []
        for (i, run) in culling.runs.enumerated() where run.count > 1 {
            guard run.allSatisfy({ library.rating(of: $0) == 0 }), let best = culling.suggested(in: i) else { continue }
            keep.append(best)
            reject += run.filter { $0 != best }
        }
        setRating(1, for: keep)
        setRating(-1, for: reject)
        return keep.count
    }

    /// the rejected photos showing, and the space they take
    var rejectedPhotos: (photos: [URL], bytes: Int64) {
        let photos = library.items.map(\.url).filter { library.rating(of: $0) < 0 && PhotosLibrary.assetID($0) == nil }
        let bytes = photos.reduce(Int64(0)) { sum, u in
            sum + Int64((try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0)
        }
        return (photos, bytes)
    }

    /// Moves the rejected photos, and their sidecars, to the Bin, where they
    /// can be put back from.
    func moveRejectedToBin() async {
        let photos = rejectedPhotos.photos
        guard !photos.isEmpty else { return }
        let sidecars = photos.map { Sidecar.url(for: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        do {
            _ = try await NSWorkspace.shared.recycle(photos + sidecars)
        } catch {
            errorMessage = "Couldn't move the rejected photos to the Bin: \(error.localizedDescription)"
        }
        library.rescan()
    }
}

// MARK: - Exporting several

extension EditorModel {
    /// Exports photos into a folder one after another, each with its own
    /// edit: opened in turn, as the export renders the open photo. With
    /// `autoAdjust`, a raw without an edit gets Auto first; for an HDR format
    /// an SDR edit is made HDR (HLG P3). Auto's edit is saved with the photo
    /// as it's left, like any other, so it looks the same when opened again;
    /// a photo only made HDR for the export keeps its sidecar as it was.
    /// The subtitle shows the progress; File › Stop Exporting stops after the
    /// photo in hand.
    func exportPhotos(_ photos: [URL], settings: ExportSettings, to folder: URL, autoAdjust: Bool, toPhotos: Bool = false) async {
        guard batchExport == nil, !photos.isEmpty else { return }
        let fromLibrary = showingLibrary
        batchExport = (0, photos.count)
        stopBatchExport = false
        var failed: [String] = []
        var done = 0
        var written: [URL] = []
        for (i, photo) in photos.enumerated() {
            if stopBatchExport { break }
            statusNote = "Exporting \(i + 1) of \(photos.count): \(photo.lastPathComponent)…"
            await open(photo)
            guard url?.standardizedFileURL == photo.standardizedFileURL else { failed.append(photo.lastPathComponent); continue }
            if settings.format.isGainMap, !exportTarget.isHDR {
                setOutputProfile(25)   // HLG P3
                await settleEdits()
            }
            if autoAdjust, Library.isRaw(photo), !openedWithEdit, canAuto {
                await autoAll()
                await settleEdits()
            }
            errorMessage = nil
            await export(settings, to: Self.freeName(folder.appendingPathComponent(
                photo.deletingPathExtension().lastPathComponent + "." + settings.format.fileExtension)), remember: false)
            if errorMessage != nil {
                failed.append(photo.lastPathComponent)
                errorMessage = nil
            } else {
                done += 1
                if let file = lastExport { written.append(file) }
            }
            batchExport = (i + 1, photos.count)
        }
        // into Photos, in an album named after the photos' folder
        var photosError: String?
        if toPhotos, !written.isEmpty {
            statusNote = "Adding \(written.count) photos to Photos…"
            do {
                try await PhotosLibrary.importFiles(written, album: photos[0].deletingLastPathComponent().lastPathComponent)
            } catch {
                photosError = "Couldn't add them to Photos: \(error.localizedDescription)"
            }
        }
        let stopped = stopBatchExport
        stopBatchExport = false
        batchExport = nil
        statusNote = nil
        if fromLibrary { await showLibrary() }
        if !failed.isEmpty || photosError != nil {
            errorMessage = (failed.isEmpty ? "Exported \(done) photos." : "Exported \(done) of \(photos.count). Couldn't export \(failed.joined(separator: ", ")).")
                + (photosError.map { " " + $0 } ?? "")
        } else {
            statusNote = stopped ? "Stopped after \(done) of \(photos.count)"
                : "Exported \(done) photos to \(folder.lastPathComponent)" + (toPhotos ? " and Photos" : "")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                if statusNote?.hasPrefix("Exported") == true || statusNote?.hasPrefix("Stopped") == true { statusNote = nil }
            }
        }
        FileHandle.standardError.write("Darkslide exported \(done) of \(photos.count) to \(folder.path)\n".data(using: .utf8)!)
    }

    /// the name, or "name 2", "name 3" and so on if it's taken
    static func freeName(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, dir = url.deletingLastPathComponent()
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent("\(base) \(n).\(ext)").path) { n += 1 }
        return dir.appendingPathComponent("\(base) \(n).\(ext)")
    }
}
