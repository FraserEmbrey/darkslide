import SwiftUI
import UniformTypeIdentifiers

@main
struct DevelopApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = EditorModel()
    @AppStorage(FilmstripSettings.visibleKey) private var filmstripVisible = true

    var body: some Scene {
        Window("Develop", id: "main") {
            ContentView()
                .environment(model)
                .task {
                    delegate.openFile = { url in Task { await model.openDropped([url]) } }
                    delegate.installKeys(model: model)
                    await model.startEngine()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    let model = model
                    Task { await model.stopEngine() }
                }
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { openPanel() }
                    .keyboardShortcut("o")
                    .disabled(!model.engineReady)
                Button("Open Folder…") { openFolderPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(!model.engineReady)
            }
            CommandGroup(replacing: .undoRedo) {
                // text fields keep their own undo
                Button(model.undoTitle ?? "Undo") {
                    if NSApp.keyWindow?.firstResponder is NSText { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                    else { Task { await model.undo() } }
                }
                .keyboardShortcut("z")
                .disabled(model.undoTitle == nil && !(NSApp.keyWindow?.firstResponder is NSText))
                Button(model.redoTitle ?? "Redo") {
                    if NSApp.keyWindow?.firstResponder is NSText { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                    else { Task { await model.redo() } }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(model.redoTitle == nil && !(NSApp.keyWindow?.firstResponder is NSText))
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                // as Photos: copy a photo's adjustments and paste them onto others
                Button("Copy Adjustments") { model.copyAdjustments() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.copySource == nil)
                Button("Copy Some Adjustments…") { model.choosingAdjustmentsToCopy = true }
                    .keyboardShortcut("c", modifiers: [.command, .shift, .option])
                    .disabled(model.url == nil || model.showingLibrary)
                Button("Paste Adjustments") { model.pasteAdjustments() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(!model.canPaste)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Edits") { Task { await model.save() } }
                    .keyboardShortcut("s")
                    .disabled(model.url == nil || !model.hasUnsavedChanges)
                Button("Export…") { ExportPanel.present(model: model) }
                    .keyboardShortcut("e")
                    .disabled(model.url == nil)
            }
            CommandMenu("Image") {
                Button("Auto") { Task { await model.autoAll() } }
                    .disabled(!model.canAuto)
                Button("Match Camera") { Task { await model.matchCamera() } }
                    .disabled(!model.canMatchCamera)
                Button(model.isCropping ? "Done Cropping" : "Crop and Straighten") {
                    model.isCropping ? model.commitCrop() : model.beginCrop()
                }
                .keyboardShortcut("k")
                .disabled(model.url == nil)
                // for interest: darktable's decoder or Apple's raw engine, per photo
                Menu("Raw Decoder") {
                    Toggle("darktable", isOn: Binding(get: { model.rawDecoderChoice == .darktable },
                                                      set: { if $0 { Task { await model.setRawDecoder(.darktable) } } }))
                    Divider()
                    Toggle("Apple, newest", isOn: Binding(get: { model.rawDecoderChoice == .apple(nil) },
                                                          set: { if $0 { Task { await model.setRawDecoder(.apple(nil)) } } }))
                        .disabled(!model.canDecodeWithApple)
                    ForEach(model.appleDecoderVersions, id: \.self) { v in
                        Toggle(AppleRawFallback.versionName(v), isOn: Binding(get: { model.rawDecoderChoice == .apple(v) },
                                                                              set: { if $0 { Task { await model.setRawDecoder(.apple(v)) } } }))
                    }
                    if let d = model.decoderInUse {
                        Divider()
                        Text("In use: \(d)")
                    }
                }
                .disabled(model.decoderInUse == nil)
                Button("Reset All Edits…") { model.confirmingReset = true }
                    .disabled(!model.canReset)
                Toggle("Compare with Original", isOn: Binding(get: { model.comparing }, set: { model.comparing = $0 }))
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(model.url == nil)
                Divider()
                Button("Apply Camera Style") {
                    if let style = model.suggestedStyle { Task { await model.applyStyle(style) } }
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.suggestedStyle == nil || model.url == nil)
                Divider()
                Toggle("Preview HDR", isOn: Binding(get: { model.viewHDR }, set: { model.viewHDR = $0 }))
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                // G and the arrow keys alone also work, outside text fields (see AppDelegate)
                Button(model.showingLibrary ? "Edit Photo" : "Library") { model.toggleLibrary() }
                    .keyboardShortcut("g", modifiers: [.command, .option])
                    .disabled(model.library.source == nil && model.library.lastFolder == nil)
                Divider()
                Button("Previous Photo") { Task { await model.openNeighbour(-1) } }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                    .disabled(model.showingLibrary || model.isCropping || model.library.neighbour(of: model.url, offset: -1) == nil)
                Button("Next Photo") { Task { await model.openNeighbour(1) } }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                    .disabled(model.showingLibrary || model.isCropping || model.library.neighbour(of: model.url, offset: 1) == nil)
            }
            CommandGroup(before: .toolbar) {
                // the library's view; from the editor, these open the library
                Toggle("as Grid", isOn: Binding(
                    get: { model.showingLibrary && !model.library.showsMap },
                    set: { _ in model.showLibrary(as: .grid) }))
                    .keyboardShortcut("1", modifiers: [.command, .option])
                    .disabled(model.library.source == nil && model.library.lastFolder == nil)
                Toggle("as Map", isOn: Binding(
                    get: { model.showingLibrary && model.library.showsMap },
                    set: { _ in model.showLibrary(as: .map) }))
                    .keyboardShortcut("2", modifiers: [.command, .option])
                    .disabled(model.library.source == nil && model.library.lastFolder == nil)
                Divider()
                Button(filmstripVisible ? "Hide Filmstrip" : "Show Filmstrip") { filmstripVisible.toggle() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Divider()
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom to Fit") { model.zoom = .fit }
                    .keyboardShortcut("0")
                Button("Actual Size") { model.zoom = .scale(1) }
                    .keyboardShortcut("1")
                Button("Zoom In") { model.zoomIn() }
                    .keyboardShortcut("=")
                Button("Zoom Out") { model.zoomOut() }
                    .keyboardShortcut("-")
                Divider()
                Picker("Background", selection: Binding(get: { model.canvasBackground },
                                                        set: { model.canvasBackground = $0 })) {
                    ForEach(CanvasBackground.allCases) { Text($0.title).tag($0) }
                }
            }
            InspectorCommands()
            ToolbarCommands()
        }

        // Window › Info (⌘I): the photo being looked at, as Photos' Info window
        Window("Info", id: "metadata") {
            MetadataWindow()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 300, height: 620)
        .keyboardShortcut("i", modifiers: [.command])
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    @MainActor
    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.showFolder(url)
    }

    @MainActor
    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.rawImage, .image]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.openDropped([url]) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files opened from Finder or `open -a`; set once the window exists.
    var openFile: ((URL) -> Void)? {
        didSet { if let openFile { queued.forEach(openFile); queued.removeAll() } }
    }
    private var queued: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let openFile { openFile(url) } else { queued.append(url) }
    }

    private var keyMonitor: Any?

    /// Lightroom-style single keys: G for the library, C for crop, ← and → for
    /// the previous and next photo. Not while typing in a text field, where they
    /// belong to the text.
    func installKeys(model: EditorModel) {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // ⌘A in the library selects every photo (in a text field it's the text's)
            if event.keyCode == 0, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
               model.showingLibrary, !(NSApp.keyWindow?.firstResponder is NSText) {
                model.library.selectAll()
                return nil
            }
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            switch event.keyCode {
            case 5:   // G
                model.toggleLibrary()
                return nil
            case 8:   // C: crop, and C again to finish
                guard !model.showingLibrary, model.url != nil else { return event }
                if model.isCropping { model.commitCrop() } else { model.beginCrop() }
                return nil
            case 123, 124:   // ← →
                // the grid moves its own selection
                guard !model.showingLibrary, !model.isCropping, model.url != nil else { return event }
                Task { await model.openNeighbour(event.keyCode == 123 ? -1 : 1) }
                return nil
            default:
                return event
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // needed when launched as a bare SwiftPM executable during development
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}
