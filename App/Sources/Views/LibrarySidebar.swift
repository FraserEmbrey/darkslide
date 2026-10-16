import SwiftUI
import UniformTypeIdentifiers

/// One folder in the sidebar. Its subfolders come from `FolderCache`, read in
/// the background: listing a folder on a network drive can take seconds, and
/// the sidebar asks for every visible folder's subfolders each time it draws.
struct FolderNode: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    @MainActor var children: [FolderNode]? {
        // not read yet: shown as expandable (empty) until the listing arrives
        guard let subs = FolderCache.shared.subfolders(of: url) else { return [] }
        return subs.isEmpty ? nil : subs.map(FolderNode.init)
    }
}

/// Subfolder listings for the sidebar, read off the main thread and kept.
@MainActor @Observable
final class FolderCache {
    static let shared = FolderCache()
    private var listings: [URL: [URL]] = [:]
    @ObservationIgnored private var reading: Set<URL> = []

    /// the subfolders if they've been read; otherwise starts reading them and returns nil
    func subfolders(of folder: URL) -> [URL]? {
        if let known = listings[folder] { return known }
        if reading.insert(folder).inserted {
            Task.detached(priority: .utility) {
                let subs = Library.subfolders(of: folder)
                await MainActor.run {
                    self.listings[folder] = subs
                    self.reading.remove(folder)
                }
            }
        }
        return nil
    }

    /// forgets what's been read, so folders are listed again (after a change on disk)
    func forget() { listings.removeAll() }
}

/// The library's source list, for one of two libraries: the folders on this
/// Mac that Darkslide works through (with the collections it gathers from them),
/// or Apple Photos. A switch at the top picks which; they never mix.
struct LibrarySidebar: View {
    @Environment(EditorModel.self) private var model
    @AppStorage("LibrarySidebarSide") private var side = Side.mac

    enum Side: String, CaseIterable, Identifiable {
        case mac, photos
        var id: String { rawValue }
        var title: String { self == .mac ? "Folders" : "Apple Photos" }
    }

    var body: some View {
        let selection = Binding<LibrarySource?>(
            get: { model.library.source },
            set: { s in
                guard let s else { return }
                // Photos asks for access the first time
                if s.isPhotos { model.showPhotos(s) } else { model.showSource(s) }
            })
        // what's showing decides the side (opening a folder from the menu, say)
        let showing = model.library.source.map { $0.isPhotos ? Side.photos : Side.mac } ?? side
        List(selection: selection) {
            if showing == .photos { photosSections } else { macSections }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Library", selection: Binding(get: { showing }, set: { switchTo($0) })) {
                ForEach(Side.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .onAppear { if showing == .photos { model.loadPhotosAlbums() } }
        .overlay {
            if showing == .mac, model.catalog.folders.isEmpty && model.library.lastFolder == nil {
                ContentUnavailableView("No Folders", systemImage: "folder.badge.plus",
                                       description: Text("Add folders of photos with + or by dragging them here."))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            model.catalog.addFolders(folders)
            if !folders.isEmpty, showing == .photos { switchTo(.mac) }
            return !folders.isEmpty
        }
    }

    private func switchTo(_ new: Side) {
        side = new
        switch new {
        case .photos:
            model.showPhotos(.photos(album: nil, title: "All Photos"))
        case .mac:
            if let folder = model.library.lastFolder { model.showSource(.folder(folder)) } else { model.showSource(.edited) }
        }
    }

    @ViewBuilder private var photosSections: some View {
        Section("Photos") {
            Label("All Photos", systemImage: "photo.on.rectangle")
                .tag(LibrarySource.photos(album: nil, title: "All Photos"))
                .help("Every photo in Apple Photos")
            Label("Places", systemImage: "map")
                .tag(LibrarySource.photosPlaces)
                .help("Photos in Apple Photos where they were taken")
            ForEach(model.photosAlbums.prefix(1).filter { $0.title == "Favourites" }) { album in
                Label(album.title, systemImage: "heart")
                    .badge(album.count > 0 ? album.count : 0)
                    .tag(LibrarySource.photos(album: album.id, title: album.title))
            }
        }
        let albums = model.photosAlbums.filter { $0.title != "Favourites" }
        if !albums.isEmpty {
            Section("Albums") {
                ForEach(albums) { album in
                    Label(album.title, systemImage: "rectangle.stack")
                        .badge(album.count > 0 ? album.count : 0)
                        .tag(LibrarySource.photos(album: album.id, title: album.title))
                }
            }
        }
    }

    @ViewBuilder private var macSections: some View {
        Section("Library") {
            Label("Edited", systemImage: "slider.horizontal.3")
                .badge(model.catalog.editedPhotos.count)
                .tag(LibrarySource.edited)
            Label("Exported", systemImage: "square.and.arrow.up")
                .badge(model.catalog.exportedPhotos.count)
                .tag(LibrarySource.exported)
            Label("Places", systemImage: "map")
                .tag(LibrarySource.map)
                .help("Every photo in the library's folders, where it was taken")
        }

        // the folder being shown, when it hasn't been added
        if let folder = model.library.lastFolder, !model.catalog.isInLibrary(folder) {
            Section("Current Folder") {
                FolderLabel(url: folder, offline: model.library.isOffline(folder))
                    .tag(LibrarySource.folder(folder))
                    .contextMenu {
                        Button("Add to Library") { model.catalog.addFolders([folder]) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    }
                    .help(folder.path)
            }
        }

        Section {
            ForEach(model.catalog.folders, id: \.self) { root in
                if model.library.isOffline(root) {
                    // nothing to list inside until it's back
                    FolderLabel(url: root.standardizedFileURL, offline: true)
                        .tag(LibrarySource.folder(root.standardizedFileURL))
                        .help("\(root.path) is offline")
                        .contextMenu {
                            if model.library.canReconnect(root) {
                                Button("Reconnect") { model.library.reconnect(root) }
                            }
                            Button("Remove from Library") { model.catalog.removeFolder(root) }
                        }
                } else {
                OutlineGroup(FolderNode(url: root.standardizedFileURL), children: \.children) { node in
                    Label(node.url.lastPathComponent, systemImage: "folder")
                        .tag(LibrarySource.folder(node.url.standardizedFileURL))
                        .help(node.url.path)
                        .contextMenu {
                            if node.url == root.standardizedFileURL {
                                Button("Remove from Library") { model.catalog.removeFolder(root) }
                            }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
                        }
                }
                }
            }
        } header: {
            HStack {
                Text("Folders")
                Spacer()
                Button { addFolders() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add folders to the library")
            }
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        guard panel.runModal() == .OK else { return }
        model.catalog.addFolders(panel.urls)
        if let first = panel.urls.first { model.showSource(.folder(first.standardizedFileURL)) }
    }
}

/// A folder in the sidebar, dimmed and marked when it's offline.
struct FolderLabel: View {
    let url: URL
    let offline: Bool

    var body: some View {
        Label {
            HStack {
                Text(url.lastPathComponent)
                if offline {
                    Spacer()
                    Text("Offline").font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: offline ? "folder.badge.questionmark" : "folder")
        }
        .foregroundStyle(offline ? .secondary : .primary)
    }
}
