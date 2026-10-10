import AppKit
import SwiftUI

/// The Look card's film looks: LUTs from the chosen folder, picked in a
/// browser of previews, with the film's push and pull variants and a strength.
struct FilmLookSection: View {
    @Environment(EditorModel.self) private var model

    private var current: FilmLook? { model.filmLooks.first { $0.path == model.currentLook } }
    private var currentFilm: Film? { current.flatMap { c in model.films.first { $0.looks.contains(c) } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Film look")
                    Text(current?.film ?? model.currentLook ?? "None")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Browse…") { model.lookBrowserOpen = true }
                    .popover(isPresented: Binding(get: { model.lookBrowserOpen }, set: { model.lookBrowserOpen = $0 }),
                             arrowEdge: .leading) {
                        LookBrowser(close: { model.lookBrowserOpen = false })
                    }
            }
            if model.currentLook != nil {
                // pushed and pulled versions of the same film
                if let film = currentFilm, film.looks.count > 1, let c = current {
                    WideSegments(options: film.looks.map { $0.variant ?? $0.film },
                                 selection: Binding(get: { film.looks.firstIndex(of: c) ?? 0 },
                                                    set: { model.applyLook(film.looks[$0]) }))
                        .help("Pulled (−) to pushed (+), as the film would be developed")
                }
                ParamSlider(label: "Strength", value: model.lookStrength, defaultValue: 100, range: 0...100,
                            isInteger: true, unit: "%", trackColors: nil, step: 5, ticks: [100]) {
                    model.setLookStrength($0.rounded())
                }
                if model.viewHDR {
                    Text("Brighter than white, the look keeps the photo's brightness and takes the film's colour.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Previews of the photo in each film, by folder, with search and favourites.
struct LookBrowser: View {
    @Environment(EditorModel.self) private var model
    let close: () -> Void
    @State private var search = ""
    @State private var scope = "All"

    /// All, Favourites, then the folder's top-level folders
    private var scopes: [String] {
        var tops: [String] = []
        for f in model.films where !f.group.isEmpty && !tops.contains(f.group[0]) { tops.append(f.group[0]) }
        return ["All", "Favourites"] + tops
    }

    private var shown: [Film] {
        var films = model.films
        switch scope {
        case "All": break
        case "Favourites": films = films.filter { model.favouriteLooks.contains($0.id) }
        default: films = films.filter { $0.group.first == scope }
        }
        let words = search.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return films }
        return films.filter { f in
            let text = (f.group + [f.name]).joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// by folder below the scope; films at the top level last, as Other
    private var sections: [(title: String, films: [Film])] {
        var order: [String] = []
        var byGroup: [String: [Film]] = [:]
        for f in shown {
            let path = scope == "All" || scope == "Favourites" ? f.group : Array(f.group.dropFirst())
            let g = path.map(Self.tidy).joined(separator: " › ")
            if byGroup[g] == nil { order.append(g) }
            byGroup[g, default: []].append(f)
        }
        order.sort { ($0.isEmpty ? 1 : 0, $0) < ($1.isEmpty ? 1 : 0, $1) }
        return order.map { ($0.isEmpty ? (scope == "All" || scope == "Favourites" ? "Other" : "") : $0, byGroup[$0]!) }
    }

    static func tidy(_ folder: String) -> String {
        folder.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "Color", with: "Colour")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    TextField("Search", text: $search)
                        .textFieldStyle(.roundedBorder)
                    Button("None") { model.applyLook(nil) }
                        .disabled(model.currentLook == nil)
                }
                Picker("Show", selection: $scope) {
                    ForEach(scopes, id: \.self) { Text(Self.tidy($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(12)
            Divider()
            if model.lutFolder == nil {
                ContentUnavailableView {
                    Label("No LUT Folder", systemImage: "camera.filters")
                } description: {
                    Text("Choose a folder of film looks: Hald CLUT images (.png) or .cube files.")
                } actions: {
                    Button("Choose LUT Folder…", action: chooseFolder)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(sections, id: \.title) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                if !section.title.isEmpty {
                                    Text(section.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 4),
                                          alignment: .leading, spacing: 12) {
                                    ForEach(section.films) { film in
                                        LookTile(film: film, maker: section.title.components(separatedBy: " › ").last ?? "")
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .overlay {
                    if shown.isEmpty {
                        ContentUnavailableView(scope == "Favourites" && search.isEmpty ? "No Favourites" : "No Films",
                                               systemImage: scope == "Favourites" ? "star" : "magnifyingglass",
                                               description: Text(scope == "Favourites" && search.isEmpty
                                                                 ? "Star a film to keep it here." : "Try other words."))
                    }
                }
                Divider()
                HStack {
                    Text("\(model.films.count) films").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose LUT Folder…", action: chooseFolder).buttonStyle(.link).font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 540, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.loadLookPreviewBase() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder of film looks: Hald CLUT images (.png) or .cube files, in folders if you like."
        panel.directoryURL = model.lutFolder
        if panel.runModal() == .OK, let url = panel.url { model.lutFolder = url }
    }
}

/// One film: the photo in its look, its name, a star, and how many variants.
struct LookTile: View {
    @Environment(EditorModel.self) private var model
    let film: Film
    /// the section's maker, left off the film's name ("FP-3000b" under Fuji)
    let maker: String
    @State private var preview: CGImage?
    @State private var previewFor = -1
    @State private var hovering = false

    private var isCurrent: Bool { film.looks.contains { $0.path == model.currentLook } }
    private var isFavourite: Bool { model.favouriteLooks.contains(film.id) }

    private var name: String {
        let prefix = maker + " "
        return !maker.isEmpty && film.name.hasPrefix(prefix) ? String(film.name.dropFirst(prefix.count)) : film.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Color.primary.opacity(0.06)
                .aspectRatio(3 / 2, contentMode: .fit)
                .overlay {
                    if let preview {
                        Image(decorative: preview, scale: 2).resizable().scaledToFill()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    if hovering || isFavourite {
                        Button { model.toggleFavourite(film) } label: {
                            Image(systemName: isFavourite ? "star.fill" : "star")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isFavourite ? .yellow : .white)
                                .padding(4)
                                .background(.black.opacity(0.35), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(4)
                        .help(isFavourite ? "Remove from Favourites" : "Add to Favourites")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if film.looks.count > 1 {
                        Label("\(film.looks.count)", systemImage: "square.stack")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.4), in: Capsule())
                            .padding(4)
                            .help("\(film.looks.count) variants, pulled to pushed")
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: isCurrent ? 2.5 : 0)
                }
            Text(name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                .help(film.name)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.applyLook(film.main) }
        .task(id: model.lookPreviewBaseID) { await loadPreview() }
    }

    private func loadPreview() async {
        guard let base = model.lookPreviewBase, let folder = model.lutFolder, previewFor != model.lookPreviewBaseID else { return }
        let url = folder.appendingPathComponent(film.main.path)
        let image = await Task.detached(priority: .utility) { LUTPreview.render(url, on: base) }.value
        preview = image
        previewFor = model.lookPreviewBaseID
    }
}
