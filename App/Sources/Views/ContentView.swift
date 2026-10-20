import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(EditorModel.self) private var model
    @State private var showInspector = true

    @AppStorage(FilmstripSettings.visibleKey) private var filmstripVisible = true
    /// the sidebar stays as the user leaves it, across launches
    @AppStorage("SidebarVisible") private var sidebarVisible = false
    @State private var columns: NavigationSplitViewVisibility =
        UserDefaults.standard.bool(forKey: "SidebarVisible") ? .all : .detailOnly

    var body: some View {
        // the column state is the view's own, so the sidebar button's change
        // animates as the split view expects; it's saved for the next launch
        NavigationSplitView(columnVisibility: $columns) {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            editor
        }
        .onChange(of: columns) { _, v in sidebarVisible = v != .detailOnly }
        .onChange(of: showInspector) { _, v in
            if UserDefaults.standard.bool(forKey: "TestFullScreen") {
                FileHandle.standardError.write("Darkslide full screen: inspector \(v), full screen \(model.isFullScreenEditor), columns \(columns)\n".data(using: .utf8)!)
            }
        }
        // full screen editing covers the window, and its toolbar goes
        .overlay {
            if model.isFullScreenEditor && !model.showingLibrary {
                FullScreenEditor().transition(.opacity)
            }
        }
        .toolbar(model.isFullScreenEditor ? .hidden : .visible, for: .windowToolbar)
        .animation(.easeInOut(duration: 0.25), value: model.isFullScreenEditor)
        .modifier(FullScreenWindowSync())
    }

    private var editor: some View {
        Group {
            if model.showingLibrary {
                if model.library.viewMode == .cull, !model.library.showsMap, model.library.source?.isPhotos != true {
                    CullView()
                } else {
                    LibraryGrid()
                }
            } else if model.isFullScreenEditor {
                // the canvas is the full screen editor's while it's showing
                Color.black
            } else {
                VStack(spacing: 0) {
                    CanvasView()
                    if model.library.items.count > 1 && !model.isCropping && filmstripVisible {
                        FilmstripResizeHandle()
                        Filmstrip()
                    }
                }

            }
        }
            // the grid is for choosing photos; the adjustments come back with the editor
            // (in full screen, in the HUD)
            .inspector(isPresented: Binding(get: { showInspector && !model.showingLibrary && !model.isFullScreenEditor },
                                            set: { if !model.showingLibrary && !model.isFullScreenEditor { showInspector = $0 } })) {
                InspectorView()
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
            }
            // editing: the photo's name can be renamed from the title, and its
            // file icon dragged, as for any document
            .navigationTitle(Binding(
                get: { model.showingLibrary ? (model.library.sourceTitle ?? "Library") : (model.url.map { LibraryItem(url: $0, hasEdit: false, version: $0.versionNumber).name } ?? "Darkslide") },
                set: { if !model.showingLibrary { model.renamePhoto(to: $0) } }))
            .background(DocumentIcon(url: model.showingLibrary || model.photosAsset != nil ? nil : model.url?.photoFile))
            .sheet(isPresented: Binding(get: { model.choosingAdjustmentsToCopy }, set: { model.choosingAdjustmentsToCopy = $0 })) {
                CopyAdjustmentsSheet()
            }
            .sheet(isPresented: Binding(get: { model.managingExportPresets }, set: { model.managingExportPresets = $0 })) {
                ExportPresetsSheet()
            }
            .sheet(isPresented: Binding(get: { model.choosingDenoise }, set: { model.choosingDenoise = $0 })) {
                DenoiseSheet()
            }
            .sheet(isPresented: Binding(get: { model.rescueFocusPhoto != nil },
                                        set: { if !$0 { model.rescueFocusPhoto = nil } })) {
                if let photo = model.rescueFocusPhoto { RescueFocusSheet(photo: photo) }
            }
            .sheet(isPresented: Binding(get: { model.compositeDraft != nil },
                                        set: { if !$0 { model.compositeDraft = nil } })) {
                if let draft = model.compositeDraft { CompositeSheet(draft: draft) }
            }
            // in a view of its own: the render time changes with every frame,
            // and read here it rebuilt the whole window (sidebar and all) each time
            .background(WindowSubtitle())
            // One customisable toolbar (right-click it, or View › Customize Toolbar).
            // The library and the editor show different items by hiding the
            // others: swapping two toolbars in a window makes AppKit throw. It goes
            // after the inspector, as before it the items were added more than once.
            .toolbar(id: "main") {
                sharedToolbar
                libraryToolbar
                editorToolbar
                outputToolbar
            }
            .confirmationDialog("Reset all edits?", isPresented: Binding(get: { model.confirmingReset },
                                                                         set: { model.confirmingReset = $0 })) {
                Button("Reset", role: .destructive) { Task { await model.resetAll() } }
            } message: {
                Text("The photo goes back to darktable's defaults and your new-photo settings. This can't be undone, but nothing on disk changes until you save.")
            }
            .preferredColorScheme(.dark)
            .onAppear {
                // with no photo there's no canvas to take focus, and macOS would
                // otherwise focus the search field at launch
                DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
                // StartMetadata: launch argument (-StartMetadata YES) for testing
                if UserDefaults.standard.bool(forKey: "StartMetadata") { InfoPanel.shared.show(model: model) }
            }
            .alert("Something went wrong", isPresented: errorBinding) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
    }

    /// progress and the library button, in both toolbars
    @ToolbarContentBuilder
    private var sharedToolbar: some CustomizableToolbarContent {
                ToolbarItem(id: "library", placement: .navigation) {
                    Toggle("Library", systemImage: "square.grid.2x2", isOn: Binding(
                        get: { model.showingLibrary },
                        set: { _ in model.toggleLibrary() }))
                    .disabled(model.library.source == nil && model.library.lastFolder == nil)
                    .help("Show the folder's photos (G); double-click one to edit it")
                }
    }

    /// the library's view switch
    @ToolbarContentBuilder
    private var libraryToolbar: some CustomizableToolbarContent {
        // never empty: AppKit throws laying out a toolbar item with no view
        ToolbarItem(id: "libraryView") {
            Picker("View", selection: Binding(
                get: { model.library.showsMap ? Library.ViewMode.map : model.library.viewMode },
                set: { model.showLibrary(as: $0) })) {
                Label("Grid", systemImage: "square.grid.2x2").tag(Library.ViewMode.grid)
                Label("Cull", systemImage: "rectangle.stack").tag(Library.ViewMode.cull)
                Label("Map", systemImage: "map").tag(Library.ViewMode.map)
            }
            .pickerStyle(.segmented)
            .help("Show these photos as a grid, one at a time to cull, or on a map (⌥⌘1, ⌥⌘3, ⌥⌘2)")
        }
        .hidden(!model.showingLibrary)
    }

    /// the editor's tools
    @ToolbarContentBuilder
    private var editorToolbar: some CustomizableToolbarContent {
                // crop, zoom and compare as one group, sharing one glass capsule
                ToolbarItem(id: "tools") {
                    @Bindable var model = model
                    ControlGroup {
                        Toggle("Crop", systemImage: "crop.rotate", isOn: Binding(
                            get: { model.isCropping },
                            set: { $0 ? model.beginCrop() : model.commitCrop() }))
                            .help("Crop and straighten (⌘K)")
                        Toggle("Spot Removal", systemImage: "bandage", isOn: $model.isRemovingSpots)
                            .help("Heal or clone away spots and blemishes")
                        Toggle("Remove Objects", systemImage: "eraser", isOn: Binding(
                            get: { model.isRemovingObjects },
                            set: { on in
                                Task {
                                    // the model is downloaded the first time, after asking
                                    if on, !(await model.ensureModel(.removeObjects)) { return }
                                    model.isRemovingObjects = on
                                }
                            }))
                            .disabled(!model.canRemoveObjects)
                            .help(model.canRemoveObjects ? "Paint over things to remove them, filled in by machine learning"
                                                         : "The Remove Objects model isn't available")
                        Menu {
                            Button("Fit") { model.zoom = .fit }
                            Divider()
                            ForEach(EditorModel.zoomSteps, id: \.self) { s in
                                Button("\(Int(s * 100))%") { model.zoom = .scale(s) }
                            }
                        } label: {
                            Label("Zoom", systemImage: "plus.magnifyingglass")
                        }
                        .help("Zoom (⌘0 fit, ⌘1 100%)")
                        Toggle("Compare", systemImage: "square.split.2x1", isOn: $model.comparing)
                            .help("Compare with the photo as it was when opened (⇧⌘B)")
                    } label: {
                        Label("Tools", systemImage: "crop.rotate")
                    }
                    .disabled(model.url == nil)
                }
                .hidden(model.showingLibrary)
                ToolbarSpacer(.fixed)
                ToolbarItem(id: "hdr") {
                    @Bindable var model = model
                    Picker("Preview", selection: $model.viewHDR) {
                        Text("SDR").tag(false)
                        Text("HDR").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .help("HDR shows the output as the export will encode it, using this display's EDR headroom")
                }
                .hidden(model.showingLibrary)
                ToolbarItem(id: "beyond") {
                    @Bindable var model = model
                    // orange when part of the photo is brighter than this display can show
                    let beyond = model.viewHDR ? model.hdrAnalysis?.fractionAboveDisplay ?? 0 : 0
                    let warn = beyond >= HDRAnalysis.beyondDisplayShown
                    Toggle("Beyond Display", systemImage: warn ? "sun.max.trianglebadge.exclamationmark.fill" : "sun.max.trianglebadge.exclamationmark",
                           isOn: $model.showHeadroomOverlay)
                        .foregroundStyle(warn && !model.showHeadroomOverlay ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                        // with nothing beyond the display there's nothing to highlight
                        .disabled(!model.viewHDR || !(warn || model.showHeadroomOverlay))
                        .help(!model.viewHDR ? "Switch to HDR to see what's brighter than this display can show"
                              : warn ? "\(beyond.formatted(.percent.precision(.fractionLength(1)))) of the photo is brighter than this display can show. Click to highlight it."
                              : "Nothing in the photo is brighter than this display can show right now")
                }
                .hidden(model.showingLibrary)
    }

    /// export, save and the rest, after the editor's tools
    @ToolbarContentBuilder
    private var outputToolbar: some CustomizableToolbarContent {
                ToolbarSpacer(.fixed)
                ToolbarItem(id: "export") {
                    Button("Export", systemImage: "square.and.arrow.up") { ExportPanel.present(model: model) }
                        .disabled(model.url == nil)
                        .help("Export (⌘E)")
                }
                .hidden(model.showingLibrary)
                ToolbarItem(id: "save") {
                    Button("Save Edits", systemImage: "square.and.arrow.down") {
                        Task { await model.save() }
                    }
                    .disabled(model.url == nil || !model.hasUnsavedChanges)
                    .help("Write the edit to the photo's XMP sidecar, which darktable can also read")
                }
                .hidden(model.showingLibrary)
                ToolbarItem(id: "auto", showsByDefault: false) {
                    Button("Auto", systemImage: "wand.and.rays") { Task { await model.autoAll() } }
                        .disabled(!model.canAuto)
                        .help("Camera style, automatic exposure, filmic auto-tune and tone equalizer fit")
                }
                .hidden(model.showingLibrary)
                ToolbarItem(id: "reset", showsByDefault: false) {
                    Button("Reset", systemImage: "arrow.counterclockwise") { model.confirmingReset = true }
                        .disabled(!model.canReset)
                        .help("Reset all edits")
                }
                .hidden(model.showingLibrary)
                ToolbarSpacer(.fixed)
                ToolbarItem(id: "inspector") {
                    Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
                        .help("Show or hide the inspector")
                }
                .hidden(model.showingLibrary)
    }


    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

struct CanvasView: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(.sRGB, white: model.canvasBackground.level)
                    .animation(.easeInOut(duration: 0.2), value: model.canvasBackground)
                if let image = model.image {
                    ZoomableImage(image: image)
                        .padding(model.imageIsZoomed ? 0 : 24)
                } else if model.url == nil {
                    ContentUnavailableView {
                        Label("No Photo Open", systemImage: "camera.aperture")
                    } description: {
                        Text(model.engineReady
                             ? "Choose File › Open, or drop a raw file here."
                             : "Starting the darktable engine…")
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .onChange(of: geo.size, initial: true) { _, size in
                model.canvasDidResize(toSize: size, displayScale: displayScale)
            }
            .overlay(alignment: .bottomLeading) {
                if model.url != nil { ZoomChip().padding(12) }
            }
            .overlay(alignment: .top) {
                if model.viewHDR, !model.displayCanShowHDR, model.url != nil, !model.showsClipping {
                    NoHDRDisplayBanner(presetIsTheCause: model.displayHasShownHDR).padding(.top, 12)
                } else if model.showLimitedHDRNote, model.url != nil, !model.showsClipping {
                    Label("This display has limited HDR support: up to \(DisplayHDRStatus.stops(model.displayPotentialHeadroom)), less when it's bright",
                          systemImage: "sun.max")
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 12)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: model.showLimitedHDRNote)
            .overlay(alignment: .top) {
                // what the Option-drag clipping view shows
                if model.showsClipping {
                    Text(model.imageIsHDR
                         ? "Showing what's brighter than this display"
                         : "Clipped highlights show in colour or white, clipped shadows in black. The rest is grey.")
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 12)
                        .transition(.opacity)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if model.showExportDone, let file = model.lastExport {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Exported \(file.lastPathComponent)")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    Button { model.showExportDone = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task {
                    try? await Task.sleep(for: .seconds(8))
                    model.showExportDone = false
                }
            }
        }
        .animation(.default, value: model.showExportDone)
        .overlay(alignment: .top) {
            if model.offerSuggestedStyle, let style = model.suggestedStyle {
                StyleSuggestionBanner(style: style)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.offerSuggestedStyle)
        .ignoresSafeArea(edges: .bottom)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task { await model.openDropped(urls) }
            return true
        }
    }
}

struct StyleSuggestionBanner: View {
    @Environment(EditorModel.self) private var model
    let style: StyleInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.filters")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Camera style available")
                    .font(.headline)
                Text("\(style.title) approximates the camera's own JPEG look.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Not Now") { model.offerSuggestedStyle = false }
            Button("Apply") { Task { await model.applyStyle(style) } }
                .keyboardShortcut(.defaultAction)
            // the same choice as Settings › Camera styles
            Menu {
                Button("Always Apply Camera Styles") {
                    model.cameraStyleMode = .automatic
                    Task { await model.applyStyle(style) }
                }
                Button("Stop Suggesting Camera Styles") {
                    model.cameraStyleMode = .off
                    model.offerSuggestedStyle = false
                }
                Divider()
                SettingsLink { Text("Settings…") }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Always apply the camera's style to new photos, or stop suggesting it. Also in Settings.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8, y: 2)
    }
}

/// The photo, with click to zoom (to 100% at the clicked point, or back to
/// fit) and drag to pan while zoomed.
struct ZoomableImage: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    let image: CGImage
    // pinch: the image scales live under the fingers, then renders sharply at the new zoom
    @State private var pinch: CGFloat = 1
    @State private var pinchAnchor: UnitPoint = .center
    @State private var pinchStartScale: Double?
    @State private var pinchPoint: CGPoint?      // the photo point under the fingers, 0...1
    @State private var pinchScreen: CGPoint = .zero
    @State private var waitingForFrame = false
    @State private var loupePointer: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: image.width, height: image.height)
            EDRImageView(image: model.clippingImage ?? image,
                         overlay: model.imageIsHDR && (model.showHeadroomOverlay || model.showsClipping) ? model.headroomOverlay : nil,
                         isHDR: model.imageIsHDR,
                         before: model.comparing ? model.beforeImage : nil,
                         split: model.compareSplit,
                         pixelExact: model.imageIsZoomed,
                         panOffset: panOffset,
                         backdrop: backdrop(in: geo.size)?.image,
                         backdropRect: backdrop(in: geo.size)?.rect ?? .zero,
                         canPan: model.imageIsZoomed && !model.comparing,
                         onClick: { p in
                             if model.whitePickTarget != nil {
                                 let u = imagePoint(at: p, in: geo.size, frame: size)
                                 if (0...1).contains(u.x), (0...1).contains(u.y) { model.pickWhite(at: u) }
                             } else if !model.isCropping {
                                 click(at: p, in: geo.size, frame: size)
                             }
                         },
                         onPan: { d in model.pan(byPixels: CGSize(width: d.width * displayScale, height: d.height * displayScale)) })
                // while straightening, turn the last frame at once; darktable's render follows
                .rotationEffect(.degrees(-model.straightenPreview.degrees), anchor: straightenAnchor(in: geo.size, frame: size))
                .scaleEffect(model.straightenPreview.scale, anchor: straightenAnchor(in: geo.size, frame: size))
                .mask {
                    if model.straightenPreview.degrees != 0 {
                        let r = EDRImageView.fittedRect(size, in: geo.size)
                        Rectangle().frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                    } else {
                        Rectangle()
                    }
                }
                .overlay {
                    if model.isCropping {
                        CropOverlay(frameSize: size)
                    } else if model.comparing {
                        CompareDivider(imageSize: size, pixelExact: model.imageIsZoomed)
                    } else if model.isRemovingObjects {
                        ObjectsOverlay(toView: { toView($0, in: geo.size, frame: size) },
                                       toImage: { toImage($0, in: geo.size, frame: size) })
                    } else if model.isRemovingSpots {
                        SpotOverlay(toView: { toView($0, in: geo.size, frame: size) },
                                    toImage: { toImage($0, in: geo.size, frame: size) })
                    } else if model.isBrushing {
                        BrushOverlay(toView: { toView($0, in: geo.size, frame: size) },
                                     toImage: { toImage($0, in: geo.size, frame: size) })
                    } else if model.selectedLocal != nil {
                        LocalShapeOverlay(toView: { toView($0, in: geo.size, frame: size) },
                                          toImage: { toImage($0, in: geo.size, frame: size) })
                    }
                }
                .overlay {
                    if model.showFocusPoint, !model.isCropping, !model.comparing, let corners = model.focusOutline {
                        FocusPointOverlay(corners: corners.map { toView($0, in: geo.size, frame: size) },
                                          inFocus: model.cameraFocus?.inFocus)
                    }
                }
                .scaleEffect(pinch, anchor: pinchAnchor)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { v in
                            if pinchStartScale == nil {
                                pinchStartScale = shownScale(in: geo.size, frame: size)
                                pinchAnchor = v.startAnchor
                                pinchPoint = imagePoint(at: v.startLocation, in: geo.size, frame: size)
                                pinchScreen = v.startLocation
                            }
                            pinch = v.magnification
                        }
                        .onEnded { v in
                            finishPinch(magnification: v.magnification, viewSize: geo.size)
                        }
                )
                .onChange(of: model.frameID) { _, _ in
                    // the sharp render has arrived: drop the live scaling
                    if waitingForFrame { pinch = 1; waitingForFrame = false }
                }
                .overlay {
                    if model.showLoupe, let p = loupePointer {
                        EditorLoupe(pointer: p, toImage: { toImage($0, in: geo.size, frame: size) })
                            .allowsHitTesting(false)
                    }
                }
                .onContinuousHover { phase in
                    guard model.showLoupe else { return }
                    if case .active(let p) = phase {
                        loupePointer = p
                        let o = toImage(p, in: geo.size, frame: size)
                        let on = o.x >= 0 && o.y >= 0 && o.x <= model.imageSize.width && o.y <= model.imageSize.height
                        model.pointLoupe(at: on ? o : nil)
                    } else {
                        loupePointer = nil
                        model.pointLoupe(at: nil)
                    }
                }
                .onHover { inside in
                    if model.whitePickTarget != nil {
                        if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                        return
                    }
                    guard case .scale = model.zoom else { return }
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                // not while the look browser is open over it, where it shows by the popover's edge
                .help(model.lookBrowserOpen ? "" : model.whitePickTarget != nil ? "Click something that should be grey or white" : model.imageIsZoomed ? "Drag to move around; click to fit the photo" : "Click to zoom to 100% here")
        }
    }
}

extension ZoomableImage {
    /// the centre of the photo as drawn, for turning it in place
    fileprivate func straightenAnchor(in view: CGSize, frame: CGSize) -> UnitPoint {
        let r = EDRImageView.fittedRect(frame, in: view)
        return UnitPoint(x: r.midX / max(view.width, 1), y: r.midY / max(view.height, 1))
    }

    /// Shifts the shown frame by the gap between the crop it shows and the crop
    /// now wanted, so a pan follows the pointer before its render arrives.
    fileprivate var panOffset: CGSize {
        guard model.imageIsZoomed, let shown = model.shownCrop, let wanted = model.currentCrop,
              shown.scale == wanted.scale else { return .zero }
        return CGSize(width: CGFloat(shown.x - wanted.x) / displayScale, height: CGFloat(shown.y - wanted.y) / displayScale)
    }

    /// While zoomed: the last whole-photo frame, placed where the whole photo
    /// would be at this zoom, under the sharp crop (only in the same HDR or
    /// SDR mode, so it matches)
    fileprivate func backdrop(in viewPoints: CGSize) -> (image: CGImage, rect: CGRect)? {
        guard model.imageIsZoomed, !model.comparing, let shown = model.shownCrop,
              let whole = model.panBackdrop, whole.isHDR == model.imageIsHDR else { return nil }
        let frame = CGSize(width: image.width, height: image.height)
        let r = EDRImageView.displayedRect(frame, in: viewPoints, pixelExact: true, displayScale: displayScale)
        let size = CGSize(width: model.imageSize.width * shown.scale / displayScale,
                          height: model.imageSize.height * shown.scale / displayScale)
        return (whole.image, CGRect(x: r.minX - CGFloat(shown.x) / displayScale, y: r.minY - CGFloat(shown.y) / displayScale,
                                    width: size.width, height: size.height))
    }

    /// a point of the processed photo (full-size output pixels) in this view
    fileprivate func toView(_ p: CGPoint, in view: CGSize, frame: CGSize) -> CGPoint {
        if model.imageIsZoomed, let c = model.shownCrop {
            let r = EDRImageView.displayedRect(frame, in: view, pixelExact: true, displayScale: displayScale)
            let o = panOffset
            return CGPoint(x: r.minX + o.width + (p.x * c.scale - CGFloat(c.x)) / displayScale,
                           y: r.minY + o.height + (p.y * c.scale - CGFloat(c.y)) / displayScale)
        }
        let r = EDRImageView.fittedRect(frame, in: view)
        let k = r.width / max(model.imageSize.width, 1)
        return CGPoint(x: r.minX + p.x * k, y: r.minY + p.y * k)
    }

    /// the inverse: a point of this view in the processed photo's pixels
    fileprivate func toImage(_ v: CGPoint, in view: CGSize, frame: CGSize) -> CGPoint {
        if model.imageIsZoomed, let c = model.shownCrop {
            let r = EDRImageView.displayedRect(frame, in: view, pixelExact: true, displayScale: displayScale)
            let o = panOffset
            return CGPoint(x: ((v.x - r.minX - o.width) * displayScale + CGFloat(c.x)) / c.scale,
                           y: ((v.y - r.minY - o.height) * displayScale + CGFloat(c.y)) / c.scale)
        }
        let r = EDRImageView.fittedRect(frame, in: view)
        let k = r.width / max(model.imageSize.width, 1)
        return CGPoint(x: (v.x - r.minX) / k, y: (v.y - r.minY) / k)
    }

    /// click: zoom to 100% at the point, or back to fit
    fileprivate func click(at p: CGPoint, in view: CGSize, frame: CGSize) {
        if case .scale = model.zoom {
            model.zoom = .fit
        } else {
            let r = EDRImageView.fittedRect(frame, in: view)
            guard r.contains(p) else { return }
            model.zoomCenter = CGPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)
            model.zoom = .scale(1)
        }
    }

    /// screen pixels per photo pixel as the photo is drawn now
    fileprivate func shownScale(in view: CGSize, frame: CGSize) -> Double {
        if model.imageIsZoomed, let c = model.shownCrop { return c.scale }
        let r = EDRImageView.fittedRect(frame, in: view)
        return r.width * displayScale / max(model.imageSize.width, 1)
    }

    /// the point of the photo (0...1) under a point of this view
    fileprivate func imagePoint(at p: CGPoint, in view: CGSize, frame: CGSize) -> CGPoint {
        if model.imageIsZoomed, let c = model.shownCrop {
            let r = EDRImageView.displayedRect(frame, in: view, pixelExact: true, displayScale: displayScale)
            let px = (p.x - r.minX) * displayScale + CGFloat(c.x), py = (p.y - r.minY) * displayScale + CGFloat(c.y)
            return CGPoint(x: px / (model.imageSize.width * c.scale), y: py / (model.imageSize.height * c.scale))
        }
        let r = EDRImageView.fittedRect(frame, in: view)
        return CGPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)
    }

    /// Picks the zoom the pinch ended at, centred so the photo point that was
    /// under the fingers stays where it is on screen, and keeps the live
    /// scaling until that render arrives.
    fileprivate func finishPinch(magnification m: CGFloat, viewSize: CGSize) {
        defer { pinchStartScale = nil }
        guard let start = pinchStartScale, let u = pinchPoint else { pinch = 1; return }
        let s = min(start * m, 4)
        if s <= model.fitScale * 1.02 {
            pinch = 1
            model.zoom = .fit
            return
        }
        // where the fingers were, in the zoomed canvas (which has no margin)
        let margin: CGFloat = model.imageIsZoomed ? 0 : 24
        let canvas = model.canvasPixelSize
        let ax = (pinchScreen.x + margin) * displayScale, ay = (pinchScreen.y + margin) * displayScale
        let cx = u.x - (ax - canvas.width / 2) / (model.imageSize.width * s)
        let cy = u.y - (ay - canvas.height / 2) / (model.imageSize.height * s)
        waitingForFrame = true
        model.zoomCenter = CGPoint(x: min(max(cx, 0), 1), y: min(max(cy, 0), 1))
        model.zoom = .scale(s)
        // in case no new frame comes (the zoom didn't change), don't stay scaled
        Task {
            try? await Task.sleep(for: .seconds(2))
            if waitingForFrame { pinch = 1; waitingForFrame = false }
        }
    }
}

/// Current zoom level, bottom left of the canvas; click to toggle fit and 100%.
struct ZoomChip: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        Button {
            if case .scale = model.zoom { model.zoom = .fit } else { model.zoom = .scale(1) }
        } label: {
            Text(text)
                .font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help("Zoom: ⌘0 fit, ⌘1 100%, ⌘+ and ⌘− to step")
    }

    private var text: String {
        switch model.zoom {
        case .fit: "Fit"
        case .scale(let s): "\(Int((s * 100).rounded()))%"
        }
    }
}

/// The draggable line between before (left) and after (right), on the photo.
struct CompareDivider: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    let imageSize: CGSize
    var pixelExact = false

    var body: some View {
        GeometryReader { geo in
            let r = EDRImageView.displayedRect(imageSize, in: geo.size, pixelExact: pixelExact, displayScale: displayScale)
            let x = r.minX + r.width * model.compareSplit
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.white)
                    .frame(width: 1.5, height: r.height)
                    .shadow(color: .black.opacity(0.4), radius: 1)
                    .offset(x: x - 0.75, y: r.minY)
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 28, height: 28)
                    .background(.white, in: Circle())
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: x - 14, y: r.midY - 14)
                CompareLabel(text: "Before")
                    .offset(x: r.minX + 10, y: r.maxY - 30)
                CompareLabel(text: "After")
                    .frame(width: r.width - 20, alignment: .trailing)
                    .offset(x: r.minX + 10, y: r.maxY - 30)
            }
            .contentShape(Rectangle().path(in: r))
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                model.compareSplit = min(max((g.location.x - r.minX) / max(r.width, 1), 0), 1)
            })
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Before and after divider")
        .accessibilityValue(Text(model.compareSplit, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { d in
            model.compareSplit = min(max(model.compareSplit + (d == .increment ? 0.05 : -0.05), 0), 1)
        }
    }
}

private struct CompareLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
    }
}

/// The open photo as the window's document: its file icon in the title,
/// which can be dragged, and the folder path on Command-click, as in other
/// Mac apps (AppKit's representedURL).
struct DocumentIcon: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let url = url
        DispatchQueue.main.async { view.window?.representedURL = url }
    }
}

/// The window's subtitle: status, camera, decoder, render time and edited state.
private struct WindowSubtitle: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        Color.clear.navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        if let note = model.statusNote { return note }
        if model.isOpening { return "Opening…" }
        if model.showingLibrary {
            if case .folder(let f) = model.library.source, model.library.isOffline(f) { return "Offline" }
            let n = model.library.items.count
            return "\(n) \(n == 1 ? "photo" : "photos")"
        }
        var parts: [String] = []
        if !model.camera.isEmpty { parts.append(model.camera) }
        if let d = model.decoderInUse, d != "darktable" { parts.append(model.openedAsHDR ? "HDR, \(d)" : d) } else if model.openedAsHDR { parts.append("HDR, decoded by macOS") }
        if let ms = model.lastRenderMs { parts.append("\(model.lastRenderWasDraft ? "draft" : "rendered") in \(ms) ms") }
        if model.hasUnsavedChanges { parts.append("edited") }
        return parts.joined(separator: " · ")
    }
}

/// Shown over an HDR view on a display that can't show HDR in its current
/// mode. macOS doesn't let an app read or change the display preset, so where
/// the display has shown HDR before (an SDR preset is the cause) it offers
/// Displays settings, where the preset is chosen; an SDR monitor gets none.
private struct NoHDRDisplayBanner: View {
    let presetIsTheCause: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(presetIsTheCause ? "This display's current preset doesn't show HDR" : "This display can't show HDR")
                Text("Highlights above white are clipped here. Exports aren't affected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if presetIsTheCause {
                Button("Display Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
