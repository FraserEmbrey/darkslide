import SwiftUI

/// A photo's thumbnail, loading on first appearance. The model is optional
/// here (and in ItemBadges and ItemMenu): these appear in places SwiftUI hosts
/// outside the window, such as map pins, drag images and menus, where the
/// environment can be missing, and a missing required one crashes.
struct Thumbnail: View {
    @Environment(EditorModel.self) private var model: EditorModel?
    let item: LibraryItem
    /// fill the frame, cropping, rather than fit inside it
    var fill = false

    var body: some View {
        Group {
            if let image = model?.library.thumbnails[item.url] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.06))
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .onAppear { model?.library.requestThumbnail(for: item.url) }
    }
}

/// Small marks on a thumbnail: edited (an XMP sidecar) and exported, in
/// orange when edited since the last export.
struct ItemBadges: View {
    @Environment(EditorModel.self) private var model: EditorModel?
    let item: LibraryItem

    var body: some View {
        let exports = model?.catalog.exports(of: item.url) ?? []
        HStack(spacing: 2) {
            if model?.library.hdrPhotos.contains(item.url) == true {
                Text("HDR")
                    .font(.system(size: 8, weight: .heavy))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .help("Holds HDR: a gain map, HLG or PQ")
            }
            if let rating = model?.library.rating(of: item.url), rating != 0 {
                if rating < 0 {
                    badge("xmark", tint: .red, help: "Rejected")
                } else {
                    Text(String(repeating: "★", count: rating))
                        .font(.system(size: 8))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.yellow)
                        .help("\(rating) \(rating == 1 ? "star" : "stars")")
                }
            }
            if item.hasEdit { badge("slider.horizontal.3", help: "Edited") }
            if !exports.isEmpty {
                let stale = model?.catalog.modifiedSinceExport(item.url) ?? false
                badge("square.and.arrow.up", tint: stale ? .orange : .white,
                      help: stale ? "Edited since its last export" : "Exported")
            }
        }
    }

    private func badge(_ symbol: String, tint: Color = .white, help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .padding(3)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(tint)
            .help(help)
    }
}

/// Right-click menu for a photo: its exports, and Finder.
struct ItemMenu: View {
    @Environment(EditorModel.self) private var model: EditorModel?
    let item: LibraryItem

    var body: some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url.photoFile]) }
        if let model {
            Divider()
            // on a selected photo, paste goes to every selected one
            let targets = model.library.selected.contains(item.url) ? model.library.selectedInOrder : [item.url]
            Button("Copy Adjustments") { model.copyAdjustments(from: item.url) }
            Button(targets.count > 1 ? "Paste Adjustments to \(targets.count) Photos" : "Paste Adjustments") {
                model.pasteAdjustments(onto: targets)
            }
            .disabled(model.copiedAdjustments == nil || targets == [model.copiedAdjustments?.source])
            if targets.count > 1 {
                Divider()
                Button("New Composite from \(targets.count) Photos…") { model.newComposite(targets) }
                    .help("Blends them into a new photo; the first is the base")
            }
        }
        let exports = (model?.catalog.exports(of: item.url) ?? []).sorted { $0.date > $1.date }
        if !exports.isEmpty {
            Section("Exports") {
                ForEach(exports, id: \.self) { e in
                    let file = URL(fileURLWithPath: e.file)
                    Button("\(file.lastPathComponent) · \(e.format), \(e.date.formatted(date: .abbreviated, time: .shortened))") {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: e.file))
                }
            }
        }
    }
}

/// Filmstrip size and visibility, shared by the editor's strip and the map's,
/// and kept across launches.
enum FilmstripSettings {
    static let heightKey = "FilmstripHeight"
    static let visibleKey = "FilmstripVisible"
    static let range: ClosedRange<Double> = 36...180
    /// thumbnail width for a height: the 3:2 of most cameras, near enough
    static func width(_ height: Double) -> Double { (height * 1.4).rounded() }

    /// The scroll offset that centres a strip's photo. Worked out, as every
    /// cell is the same width: scrollTo(id:) laid out the strip up to the
    /// photo, seconds into a whole Photos library.
    static func centring(index: Int, height: Double, viewWidth: Double) -> Double {
        let cell = width(height) + 6        // the thumbnail and its padding
        return max(0, 10 + Double(index) * (cell + 6) + cell / 2 - viewWidth / 2)
    }
}

/// The top edge of a filmstrip: drag to make the thumbnails bigger or smaller.
struct FilmstripResizeHandle: View {
    @AppStorage(FilmstripSettings.heightKey) private var height = 60.0
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .contentShape(Rectangle())
            .overlay(Divider(), alignment: .top)
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { g in
                    if start == nil { start = height }
                    // dragging up makes it taller
                    height = (start! - g.translation.height).clamped(to: FilmstripSettings.range)
                }
                .onEnded { _ in start = nil })
            .help("Drag to resize the filmstrip; View › Hide Filmstrip hides it")
    }
}

/// The folder's photos along the bottom of the editor. Click one to open it;
/// ← and → step through them.
struct Filmstrip: View {
    @Environment(EditorModel.self) private var model
    @AppStorage(FilmstripSettings.heightKey) private var height = 60.0
    @State private var position = ScrollPosition(edge: .leading)
    @State private var viewWidth = 0.0

    var body: some View {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(model.library.items) { item in
                        let current = model.libraryURL?.standardizedFileURL == item.url.standardizedFileURL
                        Thumbnail(item: item)
                            .frame(width: FilmstripSettings.width(height), height: height)
                            .overlay(alignment: .bottomTrailing) { ItemBadges(item: item).padding(3) }
                            .padding(3)
                            .background(current ? Color.accentColor.opacity(0.35) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(current ? Color.accentColor : .clear, lineWidth: 2))
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await model.open(item.url) } }
                            .contextMenu { ItemMenu(item: item) }
                            .help(item.name)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onGeometryChange(for: Double.self) { $0.size.width } action: { viewWidth = $0 }
            .frame(height: height + 18)
            .background(.bar)
            .onChange(of: model.libraryURL, initial: true) { _, url in
                guard let i = model.library.items.firstIndex(where: { $0.url.standardizedFileURL == url?.standardizedFileURL }) else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    position.scrollTo(x: FilmstripSettings.centring(index: i, height: height, viewWidth: viewWidth))
                }
            }
    }
}

/// The folder as a grid: double-click (or Return) opens a photo for editing.
struct LibraryGrid: View {
    @Environment(EditorModel.self) private var model
    @FocusState private var focused: Bool

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 14)]
    @State private var position = ScrollPosition(edge: .top)
    @State private var viewSize = CGSize.zero
    @State private var rowHeight = 0.0
    @State private var scrollY = 0.0
    /// the far end of a Shift-arrow selection; the anchor is the selection
    @State private var cursor: URL?

    /// photos in a row, as the grid lays out its columns (adaptive, 170
    /// points and up, 14 apart, inside 20 of padding)
    private var perRow: Int { max(1, Int((viewSize.width - 40 + 14) / (170 + 14))) }

    /// Centres a photo, working out its row: scrollTo(id:) laid out every
    /// row above it, seconds into a whole Photos library.
    private func scroll(to url: URL) {
        guard rowHeight > 0, let i = model.library.index(of: url) else { return }
        let row = Double(i / perRow)
        position.scrollTo(y: max(0, 20 + row * (rowHeight + 18) + rowHeight / 2 - viewSize.height / 2))
    }

    var body: some View {
        Group {
            if model.library.items.isEmpty {
                if model.library.isScanning {
                    ProgressView()
                } else if case .folder(let folder) = model.library.source, model.library.isOffline(folder) {
                    OfflineFolderView(folder: folder)
                } else {
                    ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle",
                                           description: Text(emptyText))
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(model.library.items) { item in
                            cell(item)
                                .onGeometryChange(for: Double.self) { $0.size.height } action: { rowHeight = $0 }
                        }
                    }
                    .padding(20)
                }
                .scrollPosition($position)
                .onScrollGeometryChange(for: Double.self) { $0.contentOffset.y } action: { _, y in scrollY = y }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { viewSize = $0 }
                .onAppear {
                    model.library.selection = model.libraryURL ?? model.library.items.first?.url
                    focused = true
                    Task { @MainActor in
                        // once the first row is laid out and measured
                        try? await Task.sleep(for: .milliseconds(50))
                        if let s = model.library.selection { scroll(to: s) }
                    }
                }
            }
        }
        // fill the library area whatever's showing, so the map overlay does too
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // a folder or photo dropped here opens, as on the editor's canvas
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task { await model.openDropped(urls) }
            return true
        }
        .overlay {
            if model.library.showsMap {
                LibraryMap()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.sRGB, white: 0.11))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Grid | Map is in the toolbar; this bar is only for folders
            if case .folder = model.library.source {
                @Bindable var library = model.library
                HStack {
                    Picker("Show", selection: $library.ratingFilter) {
                        ForEach(Library.RatingFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .fixedSize()
                    Spacer()
                    Toggle("Include Subfolders", isOn: $library.includeSubfolders)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .background(Color(.sRGB, white: 0.11))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.return) { open(model.library.selection); return .handled }
        // ← → by a photo, ↑ ↓ by a row; Shift extends the selection, as in Finder
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
            let step = switch press.key {
            case .leftArrow: -1
            case .rightArrow: 1
            case .upArrow: -perRow
            default: perRow
            }
            move(step, extend: press.modifiers.contains(.shift))
            return .handled
        }

    }

    private var emptyText: String {
        switch model.library.source {
        case nil: "Add a folder in the sidebar, or choose File › Open Folder."
        case .edited: "Photos you edit and save appear here, from every folder."
        case .exported: "Photos you export appear here, from every folder."
        case .map: "Add folders to the library to see their photos on the map."
        case .smart: "No photos in the library's folders match this smart album."
        case .photos, .photosPlaces: PhotosLibrary.authorised ? "No photos here." : "Allow Darkslide to use Photos in System Settings › Privacy & Security › Photos."
        case .folder: model.library.includeSubfolders ? "No raw files or images in this folder or its subfolders."
                                                      : "No raw files or images in this folder. Turn on Include Subfolders to look further down."
        }
    }

    /// the folder a photo is in, where the grid spans more than one
    private var showsFolders: Bool {
        if case .folder = model.library.source { return model.library.includeSubfolders }
        return true
    }

    private func cell(_ item: LibraryItem) -> some View {
        let selected = model.library.selected.contains(item.url)
        return VStack(spacing: 6) {
            Thumbnail(item: item)
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .opacity(model.library.rating(of: item.url) < 0 ? 0.4 : 1)
                .overlay(alignment: .bottomTrailing) { ItemBadges(item: item).padding(4) }
                .padding(8)
                .background(selected ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 8))
            VStack(spacing: 1) {
                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(selected ? .primary : .secondary)
                if showsFolders {
                    Text(item.folderName)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contextMenu { ItemMenu(item: item) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(item.url) }
        .simultaneousGesture(TapGesture().onEnded {
            let keys = NSEvent.modifierFlags
            model.library.click(item.url, command: keys.contains(.command), shift: keys.contains(.shift))
            focused = true
        })
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        Task { await model.open(url) }
    }

    private func move(_ offset: Int, extend: Bool) {
        let library = model.library
        let items = library.items
        guard !items.isEmpty else { return }
        let from = extend ? (cursor ?? library.selection) : library.selection
        let i = library.index(of: from) ?? 0
        // up from the top row or down from the bottom one stays put, as in
        // Finder; down into a shorter last row goes to its last photo
        let j = i + offset
        let lastRow = (items.count - 1) / perRow
        guard j >= 0, j < items.count || abs(offset) == 1 || i / perRow < lastRow else { return }
        let target = items[min(max(j, 0), items.count - 1)].url
        if extend {
            library.click(target, command: false, shift: true)
            cursor = target
        } else {
            library.selection = target
            cursor = nil
        }
        reveal(target)
        // LogKeys: launch argument (-LogKeys YES) for testing
        if UserDefaults.standard.bool(forKey: "LogKeys") {
            FileHandle.standardError.write("Darkslide grid move \(offset): \(library.index(of: target) ?? -1) of \(items.count), \(perRow) a row, \(library.selected.count) selected\n".data(using: .utf8)!)
        }
    }

    /// scrolls just enough to show a photo's row, as Finder does
    private func reveal(_ url: URL) {
        guard rowHeight > 0, let i = model.library.index(of: url) else { return }
        let top = 20 + Double(i / perRow) * (rowHeight + 18), bottom = top + rowHeight
        if top < scrollY + 8 {
            position.scrollTo(y: max(0, top - 12))
        } else if bottom > scrollY + viewSize.height - 8 {
            position.scrollTo(y: bottom - viewSize.height + 12)
        }
    }
}

/// A folder whose share or drive isn't connected: what's happened, and a way back.
struct OfflineFolderView: View {
    @Environment(EditorModel.self) private var model
    let folder: URL

    var body: some View {
        let library = model.library
        let network = library.canReconnect(folder)
        ContentUnavailableView {
            Label("\(folder.lastPathComponent) Is Offline", systemImage: network ? "network.slash" : "externaldrive.badge.xmark")
        } description: {
            Text(network
                 ? "It's on a network share that isn't connected. Its photos and edits are safe there, and appear again when it's back."
                 : "It's on a drive that isn't connected. Its photos and edits are safe there, and appear again when you connect it.")
        } actions: {
            if network {
                if library.reconnecting.contains(folder) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Reconnect") { library.reconnect(folder) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .help(folder.path)
    }
}
