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
                    Label("Film LUTs are made for SDR, so in HDR the look clips everything brighter than white.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
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

    private var shown: [Film] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return model.films }
        return model.films.filter { f in
            let text = (f.group + [f.name]).joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    private var sections: [(title: String, films: [Film])] {
        var out: [(String, [Film])] = []
        let favourites = shown.filter { model.favouriteLooks.contains($0.id) }
        if !favourites.isEmpty { out.append(("Favourites", favourites)) }
        var order: [String] = []
        var byGroup: [String: [Film]] = [:]
        for f in shown {
            let g = f.group.map { $0.replacingOccurrences(of: "-", with: " ") }.joined(separator: " › ")
            if byGroup[g] == nil { order.append(g) }
            byGroup[g, default: []].append(f)
        }
        return out + order.map { ($0.isEmpty ? "Looks" : $0, byGroup[$0]!) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                TextField("Search films", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button("None") { model.applyLook(nil); close() }
                    .disabled(model.currentLook == nil)
            }
            if model.lutFolder == nil {
                ContentUnavailableView {
                    Label("No LUT folder", systemImage: "camera.filters")
                } description: {
                    Text("Choose a folder of film looks: Hald CLUT images (.png) or .cube files.")
                } actions: {
                    Button("Choose LUT Folder…", action: chooseFolder)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections, id: \.title) { section in
                            Section {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 12) {
                                    ForEach(section.films) { film in
                                        LookTile(film: film, close: close)
                                    }
                                }
                            } header: {
                                Text(section.title)
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                                    .background(.regularMaterial)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .overlay { if shown.isEmpty { Text("No films match").foregroundStyle(.secondary) } }
                HStack {
                    Text("\(model.films.count) films").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose LUT Folder…", action: chooseFolder).buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(12)
        .frame(width: 520, height: 600)
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

/// One film: the photo in its look, its name and a star.
struct LookTile: View {
    @Environment(EditorModel.self) private var model
    let film: Film
    let close: () -> Void
    @State private var preview: CGImage?
    @State private var previewFor = -1

    private var isCurrent: Bool { film.looks.contains { $0.path == model.currentLook } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let preview {
                        Image(decorative: preview, scale: 2).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color.primary.opacity(0.08)).overlay(ProgressView().controlSize(.small))
                    }
                }
                .frame(height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: isCurrent ? 2.5 : 0))
                Button {
                    model.toggleFavourite(film)
                } label: {
                    Image(systemName: model.favouriteLooks.contains(film.id) ? "star.fill" : "star")
                        .foregroundStyle(model.favouriteLooks.contains(film.id) ? .yellow : .white)
                        .shadow(radius: 2)
                        .padding(5)
                }
                .buttonStyle(.plain)
                .help(model.favouriteLooks.contains(film.id) ? "Remove from favourites" : "Add to favourites")
            }
            Text(film.name)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
            if film.looks.count > 1 {
                Text("\(film.looks.count) variants").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
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
