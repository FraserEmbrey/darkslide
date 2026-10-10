import SwiftUI
import UniformTypeIdentifiers

/// One folder in the sidebar, with its subfolders loaded when expanded.
struct FolderNode: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var children: [FolderNode]? {
        let subs = Library.subfolders(of: url)
        return subs.isEmpty ? nil : subs.map(FolderNode.init)
    }
}

/// The library's source list: collections gathered from the catalog, then
/// the folders added to the library, each with its subfolders.
struct LibrarySidebar: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        let selection = Binding<LibrarySource?>(
            get: { model.library.source },
            set: { if let s = $0 { model.showSource(s) } })
        List(selection: selection) {
            Section("Library") {
                Label("Edited", systemImage: "slider.horizontal.3")
                    .badge(model.catalog.editedPhotos.count)
                    .tag(LibrarySource.edited)
                Label("Exported", systemImage: "square.and.arrow.up")
                    .badge(model.catalog.exportedPhotos.count)
                    .tag(LibrarySource.exported)
                Label("Map", systemImage: "map")
                    .tag(LibrarySource.map)
                    .help("Every photo in the library's folders, where it was taken")
            }

            // the folder being shown, when it hasn't been added
            if let folder = model.library.lastFolder, !model.catalog.isInLibrary(folder) {
                Section("Current Folder") {
                    Label(folder.lastPathComponent, systemImage: "folder")
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
        .listStyle(.sidebar)
        .overlay {
            if model.catalog.folders.isEmpty && model.library.lastFolder == nil {
                ContentUnavailableView("No Folders", systemImage: "folder.badge.plus",
                                       description: Text("Add folders of photos with + or by dragging them here."))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            model.catalog.addFolders(folders)
            return !folders.isEmpty
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
