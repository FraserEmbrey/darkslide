import MapKit
import SwiftUI

/// Window › Info (⌘I): the photo being looked at (the open one in the
/// editor, or the one selected in the library; several selected are summed
/// up), laid out as Photos' Info window, in a floating panel (InfoPanel). Title, caption, keywords and rating
/// are editable, saved to the sidecar through darktable. All Metadata lists
/// every tag.
struct MetadataWindow: View {
    @Environment(EditorModel.self) private var model
    @State private var metadata: PhotoMetadata?
    @State private var shownURL: URL?
    /// the place name, kept with the coordinate it names so a reread of the
    /// same photo doesn't flash back to coordinates while geocoding
    @State private var place: (coordinate: CLLocationCoordinate2D, name: String)?
    @State private var showAll = false
    @State private var filter = ""
    @State private var titleDraft = ""
    @State private var captionDraft = ""
    @State private var keywordDraft = ""
    @State private var optionDown = false
    @State private var optionMonitor: Any?
    @FocusState private var focus: Field?

    private enum Field { case title, caption, keyword }

    private var photo: URL? {
        model.showingLibrary ? (model.library.selection ?? model.url) : model.url
    }

    /// several selected in the library: Info sums them up (MultiInfo)
    private var several: [URL]? {
        guard model.showingLibrary, model.library.selected.count > 1 else { return nil }
        return model.library.selectedInOrder
    }

    var body: some View {
        Group {
            if let several {
                MultiInfo(photos: several)
            } else if let photo, let metadata, shownURL == photo {
                content(metadata, photo: photo)
            } else if photo == nil {
                ContentUnavailableView("No Photo", systemImage: "info.circle",
                                       description: Text("Open or select a photo to see its information."))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(.system(size: 13))
        .frame(minWidth: 280, idealWidth: 300, minHeight: 360, idealHeight: 600)
        .task(id: "\(photo?.path ?? "")#\(model.infoRevision)") { await load() }
        .onAppear {
            // Option shows the true focal length, as Photos does
            optionMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                optionDown = event.modifierFlags.contains(.option)
                return event
            }
            // no field starts with the cursor in it (the panel isn't key, so
            // the main window keeps its own focus)
            DispatchQueue.main.async { focus = nil }
        }
        .onDisappear { if let m = optionMonitor { NSEvent.removeMonitor(m) } }
    }

    private func load() async {
        guard let photo else { metadata = nil; shownURL = nil; return }
        let read = await Task.detached(priority: .userInitiated) { PhotoMetadata.read(photo) }.value
        guard !Task.isCancelled else { return }
        let samePhoto = shownURL == photo
        metadata = read
        shownURL = photo
        if focus != .title || !samePhoto { titleDraft = read.facts.title ?? "" }
        if focus != .caption || !samePhoto { captionDraft = read.facts.caption ?? "" }
        guard let c = read.location else { place = nil; return }
        if let p = place, abs(p.coordinate.latitude - c.latitude) < 1e-7, abs(p.coordinate.longitude - c.longitude) < 1e-7 { return }
        place = nil
        if let request = MKReverseGeocodingRequest(location: CLLocation(latitude: c.latitude, longitude: c.longitude)),
           let item = (try? await request.mapItems)?.first, let a = item.addressRepresentations {
            // "Brighton, England, United Kingdom", as Photos names places
            var name = a.cityWithContext(.full) ?? a.cityWithContext ?? a.cityName ?? item.name ?? ""
            if let region = a.regionName, !name.isEmpty, !name.contains(region) { name += ", \(region)" }
            if !name.isEmpty { place = (c, name) }
        }
    }

    // MARK: Layout

    private func content(_ m: PhotoMetadata, photo: URL) -> some View {
        let f = m.facts
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(f, photo: photo)
                    Divider()
                    cameraCard(f).padding(10)
                    Divider()
                    field("Add a Caption", text: $captionDraft, focus: .caption) {
                        if captionDraft != (f.caption ?? "") { Task { await model.setInfo(photo, caption: captionDraft) } }
                    }
                    Divider()
                    keywords(f, photo: photo)
                    Divider()
                    if !f.editedWith.isEmpty {
                        row("slider.horizontal.3", "Edited in darktable",
                            secondary: f.editedWith.joined(separator: ", "))
                        Divider()
                    }
                    allMetadata(m)
                }
            }
            // the details take the height they need, the map the rest
            .fixedSize(horizontal: false, vertical: m.location != nil)
            if let c = m.location {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text(place?.name ?? String(format: "%.4f, %.4f", c.latitude, c.longitude))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .textSelection(.enabled)
                        .help(f.locationFromSidecar ? "Placed in Develop or darktable" : "From the camera's GPS")
                    Map(initialPosition: .camera(MapCamera(centerCoordinate: c, distance: 3000))) {
                        Annotation("", coordinate: c, anchor: .bottom) { Pin() }
                    }
                    .mapControls { MapZoomStepper() }
                    .frame(minHeight: 180)
                    .id("\(c.latitude),\(c.longitude)")
                }
            }
        }
    }

    private func header(_ f: PhotoMetadata.Facts, photo: URL) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                // saved to the sidecar's dc:title on Return or when you click away
                TextField("Add a Title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .title)
                    .onSubmit { saveTitle(photo, f) }
                    .onChange(of: focus) { old, _ in if old == .title { saveTitle(photo, f) } }
                stars(f.rating, photo: photo)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(f.fileName).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 6)
                if model.showingLibrary || model.url != photo {
                    Button("Edit") { Task { await model.open(photo) } }.buttonStyle(.link)
                }
            }
            if let taken = f.taken {
                HStack(spacing: 12) {
                    Text(taken.formatted(date: .long, time: .omitted))
                    Text(taken.formatted(date: .omitted, time: .standard))
                }
                .lineLimit(1)
            }
        }
        .padding(12)
    }

    private func saveTitle(_ photo: URL, _ f: PhotoMetadata.Facts) {
        let text = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != (f.title ?? "") else { return }
        Task { await model.setInfo(photo, title: text) }
    }

    /// click a star to rate, the same star again to clear; saved to the sidecar
    private func stars(_ rating: Int?, photo: URL) -> some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Button {
                    Task { await model.setInfo(photo, rating: rating == i ? 0 : i) }
                } label: {
                    Image(systemName: i <= max(rating ?? 0, 0) ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .help(rating == i ? "Clear the rating" : "\(i) \(i == 1 ? "star" : "stars")")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize()
    }

    /// camera and lens, size and format, and the exposure, as in Photos
    private func cameraCard(_ f: PhotoMetadata.Facts) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.camera ?? "Unknown camera").lineLimit(1)
                    // focal length and aperture are in the exposure line below
                    if let lens = f.lens { Text(lens).lineLimit(1).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 6)
                HStack(spacing: 7) {
                    if let auto = f.whiteBalanceAuto {
                        badge(auto ? "AWB" : "WB", help: auto ? "Auto white balance" : "Manual white balance")
                    }
                    if let m = f.metering, let symbol = Self.meteringSymbols[m] {
                        Image(systemName: symbol).help(Self.meteringNames[m] ?? "Metering")
                    }
                    if let flash = f.flashFired {
                        Image(systemName: flash ? "bolt.fill" : "bolt.slash").help(flash ? "Flash fired" : "No flash")
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            }
            HStack {
                if let mp = f.megapixels { Text(mp) }
                Spacer(minLength: 4)
                if let w = f.width, let h = f.height { Text("\(w) × \(h)") }
                Spacer(minLength: 4)
                if let size = f.fileSize { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                Spacer(minLength: 4)
                if f.hdr { badge("HDR", help: "Holds HDR: a gain map, HLG or PQ") }
                badge(f.format, help: "File format")
            }
            .lineLimit(1)
            Divider()
            HStack(spacing: 0) {
                ForEach(Array(exposure(f).enumerated()), id: \.offset) { i, item in
                    Text(item)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .help(i == 1 ? (optionDown ? "True focal length" : "Full-frame equivalent focal length; hold Option for the true one")
                              : i == 3 && f.apertureEstimated ? "Estimated by the camera: the lens doesn't report its aperture (a Leica M lens, say), so the camera compares its light meter with the exposure" : "")
                }
            }
            .font(.system(size: 12))
        }
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }

    /// the full-frame equivalent focal length, or with Option held the true one
    private func exposure(_ f: PhotoMetadata.Facts) -> [String] {
        let focal = optionDown || f.focal35 == nil ? f.focalText : f.focal35.map { "\($0) mm" }
        return [f.iso.map { "ISO \($0)" } ?? "ISO –", focal ?? "– mm", f.biasText ?? "– ev", f.apertureText ?? "ƒ –", f.shutterText ?? "– s"]
    }

    private func badge(_ text: String, help: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.secondary)
            .help(help)
    }

    /// an editable line, saved on Return or when you click away
    private func field(_ prompt: String, text: Binding<String>, focus field: Field, save: @escaping () -> Void) -> some View {
        TextField(prompt, text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .focused($focus, equals: field)
            .onSubmit(save)
            .onChange(of: focus) { old, _ in if old == field { save() } }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    /// keywords (darktable tags), after a tag icon; right-click one to remove
    /// it, and type in the field to add one
    private func keywords(_ f: PhotoMetadata.Facts, photo: URL) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "tag").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                if !f.tags.isEmpty {
                    FlowLayout(spacing: 0) {
                        ForEach(Array(f.tags.enumerated()), id: \.offset) { i, tag in
                            Text(tag + (i < f.tags.count - 1 ? ", " : ""))
                                .contextMenu {
                                    Button("Remove “\(tag)”") { Task { await model.setInfo(photo, removeKeyword: tag) } }
                                }
                                .help("Right-click to remove")
                        }
                    }
                }
                TextField(f.tags.isEmpty ? "Add a Keyword" : "Add Another", text: $keywordDraft)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .keyword)
                    .onSubmit {
                        let k = keywordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        keywordDraft = ""
                        if !k.isEmpty { Task { await model.setInfo(photo, addKeyword: k) } }
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func row(_ symbol: String, _ text: String, secondary: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                if let secondary { Text(secondary).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: All metadata

    /// opens every tag in a sheet, with a filter
    private func allMetadata(_ m: PhotoMetadata) -> some View {
        Button { showAll = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle").frame(width: 18)
                Text("All Metadata")
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .sheet(isPresented: $showAll) { AllMetadataSheet(metadata: m, filter: $filter) }
    }

    private static let meteringSymbols = [1: "camera.metering.center.weighted.average", 2: "camera.metering.center.weighted",
                                          3: "camera.metering.spot", 4: "camera.metering.multispot", 5: "camera.metering.matrix",
                                          6: "camera.metering.partial"]
    private static let meteringNames = [1: "Average metering", 2: "Centre-weighted metering", 3: "Spot metering",
                                        4: "Multi-spot metering", 5: "Matrix metering", 6: "Partial metering"]
}

/// The red map pin, as Photos shows a photo's place.
private struct Pin: View {
    var body: some View {
        VStack(spacing: 0) {
            Circle().fill(.red).frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
            Rectangle().fill(.gray).frame(width: 2, height: 12)
        }
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
    }
}

/// Lays out keyword capsules in lines, wrapping as needed.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// Every tag the photo has, by dictionary, with a filter.
private struct AllMetadataSheet: View {
    let metadata: PhotoMetadata
    @Binding var filter: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let text = filter.lowercased()
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter", text: $filter).textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            .padding(12)
            List {
                ForEach(metadata.all) { section in
                    let rows = text.isEmpty ? section.rows : section.rows.filter {
                        $0.label.lowercased().contains(text) || $0.value.lowercased().contains(text)
                    }
                    if !rows.isEmpty {
                        Section(section.title) {
                            ForEach(rows, id: \.self) { row in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                                    Text(row.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.system(size: 12))
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 440, height: 520)
    }
}
