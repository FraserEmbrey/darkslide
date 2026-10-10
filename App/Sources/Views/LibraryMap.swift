import MapKit
import SwiftUI

/// The library's photos where they were taken. Click a photo to select it,
/// double-click to edit it. When some photos have no location, a strip of
/// the photos runs underneath: drag one onto the map to place it there (or a
/// pin to a new spot).
struct LibraryMap: View {
    @Environment(EditorModel.self) private var model
    @State private var position: MapCameraPosition = .automatic
    // matching locations from a track
    @State private var matching = false
    @State private var matchSource: LocationMatcher.Source = .photosLibrary
    @State private var cameraZone = TimeZone.current.secondsFromGMT()
    @State private var clockMinutes = 0.0
    @State private var maxGapMinutes = 30.0
    @State private var captureDates: [URL: Date] = [:]    // unplaced photos, in the camera zone, uncorrected
    @State private var track: [LocationMatcher.TrackPoint] = []
    @State private var proposals: [URL: LocationMatcher.Match] = [:]
    @State private var matchStatus = ""
    @State private var matchBusy = false
    @AppStorage(FilmstripSettings.heightKey) private var stripHeight = 60.0
    @AppStorage(FilmstripSettings.visibleKey) private var stripVisible = true
    /// where a dragged photo is over the map, in the map's coordinates
    @State private var dropPoint: CGPoint?
    /// the photo being dragged, for the marker that shows where it'll land
    @State private var draggedURL: URL?
    /// the map's camera as the user leaves it, so jumping to a photo keeps the zoom
    @State private var camera: MapCamera?
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var found: MKMapItem?
    @State private var searching = false

    var body: some View {
        let library = model.library
        let placed = library.items.filter { library.locations[$0.url] != nil }
        let unplaced = library.items.count - placed.count
        VStack(spacing: 0) {
            MapReader { proxy in
                Map(position: $position) {
                    ForEach(placed) { item in
                        if let coordinate = library.locations[item.url] {
                            Annotation(item.name, coordinate: coordinate, anchor: .bottom) {
                                // MapKit hosts pins apart from the window's views: pass the model on
                                pin(item).environment(model)
                            }
                            .annotationTitles(.hidden)
                        }
                    }
                    if let found {
                        Marker(found.name ?? query, coordinate: found.location.coordinate)
                    }
                    if matching {
                        // the part of the track around the photos
                        if track.count > 1 {
                            MapPolyline(coordinates: visibleTrack.map(\.coordinate))
                                .stroke(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        }
                        ForEach(library.items.filter { proposals[$0.url] != nil }) { item in
                            if let m = proposals[item.url] {
                                Annotation(item.name, coordinate: m.coordinate, anchor: .bottom) {
                                    Thumbnail(item: item, fill: true).environment(model)
                                        .frame(width: 40, height: 40)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                        .overlay(RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3])))
                                        .opacity(0.85)
                                        .help("\(item.name): proposed, \(Self.gapText(m.gap)) from the track")
                                }
                                .annotationTitles(.hidden)
                            }
                        }
                    }
                }
                .onMapCameraChange(frequency: .onEnd) { context in camera = context.camera }
                .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
                .mapControls {
                    MapZoomStepper()
                    MapCompass()
                    MapScaleView()
                }
                .onDrop(of: [.fileURL], delegate: MapDrop(point: $dropPoint) { urls, point in
                    guard let coordinate = proxy.convert(point, from: .local) else { return }
                    let photos = urls.filter { model.library.contains($0) }
                    for photo in photos { Task { await model.setLocation(coordinate, for: photo) } }
                    model.library.selection = photos.last ?? model.library.selection
                    draggedURL = nil
                })
                .overlay(alignment: .topLeading) {
                    // where the photo will land: the pin's tip is the drop point, and
                    // the photo rides above it so the spot underneath stays visible
                    if let p = dropPoint {
                        DropMarker(image: draggedURL.flatMap { model.library.thumbnails[$0] })
                            .position(x: p.x, y: p.y - DropMarker.height / 2)
                            .allowsHitTesting(false)
                    }
                }
            }
            .overlay(alignment: .bottom) { status(placed: placed.count) }
            .overlay(alignment: .topLeading) { searchField.padding(12) }
            .overlay(alignment: .topTrailing) { if matching { matchPanel.padding(12) } }

            if !library.items.isEmpty && stripVisible {
                FilmstripResizeHandle()
                strip(unplaced: unplaced)
            }
        }
        // frame the photos again when the folder or collection changes
        .onChange(of: library.source) { _, _ in position = framing(placed) }
        .onChange(of: library.isLoadingLocations) { _, loading in if !loading { position = framing(placed) } }
        .onAppear {
            model.library.selection = model.url
            position = framing(placed)
            // StartMatching: launch argument (-StartMatching thisView) for testing
            if let s = UserDefaults.standard.string(forKey: "StartMatching"), let source = LocationMatcher.Source(rawValue: s) {
                matchSource = source
                Task { try? await Task.sleep(for: .seconds(2)); startMatching() }
            }
        }
    }

    private func pin(_ item: LibraryItem) -> some View {
        let selected = model.library.selection == item.url
        return Thumbnail(item: item, fill: true)
            .frame(width: selected ? 72 : 52, height: selected ? 72 : 52)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.accentColor : .white, lineWidth: selected ? 3 : 2))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .animation(.easeOut(duration: 0.15), value: selected)
            .onTapGesture(count: 2) { Task { await model.open(item.url) } }
            .onTapGesture { model.library.selection = item.url }
            .onDrag { dragItem(item) } preview: { DragPreview() }
            .contextMenu { menu(item) }
            .help(item.name)
            .zIndex(selected ? 1 : 0)
    }

    /// every photo in view, marked placed or not; drag one onto the map
    private func strip(unplaced: Int) -> some View {
        let library = model.library
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: unplaced > 0 ? "mappin.slash" : "mappin.and.ellipse")
                Text(unplaced > 0
                     ? "\(unplaced) of \(library.items.count) photos have no location. Drag a photo onto the map to place it."
                     : "All \(library.items.count) photos have a location. Drag one to a new spot to move it.")
                Spacer()
                if unplaced > 0 {
                    Button("Match Locations…") { startMatching() }
                        .controlSize(.small)
                        .disabled(matching)
                        .help("Place photos from a GPS track: your iPhone's photos, or located photos here")
                }
            }
            .padding(.trailing, 12)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 6)

            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(library.items) { item in
                        let located = library.locations[item.url] != nil
                        let selected = model.library.selection == item.url
                        Thumbnail(item: item)
                            .frame(width: FilmstripSettings.width(stripHeight), height: stripHeight)
                            .overlay(alignment: .bottomLeading) {
                                Image(systemName: located ? "mappin.circle.fill" : "mappin.slash.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, located ? Color.red : Color.gray)
                                    .font(.system(size: 14))
                                    .shadow(radius: 1)
                                    .padding(3)
                                    .help(located ? "Has a location" : "No location")
                            }
                            .padding(3)
                            .background(selected ? Color.accentColor.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                            .opacity(located ? 0.75 : 1)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { Task { await model.open(item.url) } }
                            .onTapGesture { select(item) }
                            .onDrag { dragItem(item) } preview: { DragPreview() }
                            .contextMenu { menu(item) }
                            .help(item.name)
                            .id(item.url)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.never)
            .frame(height: stripHeight + 12)
            // a pin clicked on the map shows its photo in the strip
            .onChange(of: model.library.selection) { _, url in
                guard let url else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(url, anchor: .center) }
            }
            }
        }
        .background(.bar)
    }

    /// Starts dragging a photo. The system's drag image is left empty: centred
    /// on the pointer, it would hide the spot the photo lands on. The map
    /// draws its own marker instead (DropMarker).
    private func dragItem(_ item: LibraryItem) -> NSItemProvider {
        draggedURL = item.url
        model.library.selection = item.url
        return NSItemProvider(object: item.url as NSURL)
    }

    /// clicking a placed photo in the strip shows it on the map, at the
    /// current zoom (or close enough to see the place, if zoomed far out)
    private func select(_ item: LibraryItem) {
        model.library.selection = item.url
        if let c = model.library.locations[item.url] {
            let distance = min(camera?.distance ?? 20_000, 200_000)
            withAnimation { position = .camera(MapCamera(centerCoordinate: c, distance: distance)) }
        }
    }

    // MARK: Matching from a track

    private var matchPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Match Locations").font(.headline)
            LabeledContent("Track") {
                Picker("Track", selection: $matchSource) {
                    ForEach(LocationMatcher.Source.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
            LabeledContent("Camera time zone") {
                Picker("Camera time zone", selection: $cameraZone) {
                    ForEach(Array(stride(from: -12 * 3600, through: 14 * 3600, by: 1800)), id: \.self) { s in
                        Text(Self.zoneName(s)).tag(s)
                    }
                }
                .labelsHidden()
            }
            .help("The zone the camera's clock was set to. Photos that record their own zone use that instead.")
            ParamSlider(label: "Clock correction", value: clockMinutes, defaultValue: 0, range: -60...60,
                        isInteger: true, unit: "min", trackColors: nil, step: 1, ticks: [-30, 0, 30]) { clockMinutes = $0 }
                .help("If the camera's clock was fast or slow: compare a photo of a clock, or line a photo up with your phone's")
            ParamSlider(label: "Furthest from the track", value: maxGapMinutes, defaultValue: 30, range: 5...240,
                        isInteger: true, unit: "min", trackColors: nil, step: 5, ticks: [30, 60, 120, 180]) { maxGapMinutes = $0 }
                .help("Photos taken further than this from a located photo are left alone")
            HStack(spacing: 6) {
                if matchBusy { ProgressView().controlSize(.small) }
                Text(matchStatus).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { stopMatching() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply to \(proposals.count) \(proposals.count == 1 ? "Photo" : "Photos")") { applyMatches() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(proposals.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .onChange(of: matchSource) { _, _ in loadTrack() }
        .onChange(of: cameraZone) { _, _ in readCaptureDates() }
        .onChange(of: clockMinutes) { _, _ in rematch() }
        .onChange(of: maxGapMinutes) { _, _ in rematch() }
    }

    /// the track near the photos being matched, so the line isn't the whole year
    private var visibleTrack: [LocationMatcher.TrackPoint] {
        let offset = clockMinutes * 60
        guard let first = captureDates.values.min(), let last = captureDates.values.max() else { return track }
        let margin = maxGapMinutes * 60 + abs(offset)
        return track.filter { $0.date >= first + offset - margin && $0.date <= last + offset + margin }
    }

    private func startMatching() {
        matching = true
        readCaptureDates()
    }

    private func stopMatching() {
        matching = false
        proposals = [:]
        track = []
        matchStatus = ""
    }

    /// the unplaced photos' capture times, in the chosen camera zone
    private func readCaptureDates() {
        let library = model.library
        let unplaced = library.items.map(\.url).filter { library.locations[$0] == nil }
        let zone = TimeZone(secondsFromGMT: cameraZone) ?? .current
        matchBusy = true
        matchStatus = "Reading capture times…"
        Task.detached(priority: .userInitiated) {
            var dates: [URL: Date] = [:]
            for url in unplaced {
                if let d = LocationMatcher.captureDate(of: url, zone: zone, clockOffset: 0) { dates[url] = d }
            }
            await MainActor.run {
                captureDates = dates
                loadTrack()
            }
        }
    }

    private func loadTrack() {
        guard let first = captureDates.values.min(), let last = captureDates.values.max() else {
            matchBusy = false
            matchStatus = "None of the photos without a location record when they were taken."
            proposals = [:]
            return
        }
        matchBusy = true
        matchStatus = "Reading the track…"
        let source = matchSource
        let library = model.library
        let located = library.items.compactMap { item in library.locations[item.url].map { (item.url, $0) } }
        let zone = TimeZone(secondsFromGMT: cameraZone) ?? .current
        // a day either side covers time zone and clock mistakes
        let start = first - 86_400, end = last + 86_400
        Task {
            do {
                let points: [LocationMatcher.TrackPoint]
                switch source {
                case .photosLibrary: points = try await LocationMatcher.photosLibraryTrack(from: start, to: end)
                case .thisView: points = await Task.detached { LocationMatcher.photosTrack(located, zone: zone) }.value
                }
                track = points
                rematch()
            } catch {
                track = []
                proposals = [:]
                matchBusy = false
                matchStatus = error.localizedDescription
            }
        }
    }

    private func rematch() {
        let offset = clockMinutes * 60
        let dates = captureDates.mapValues { $0 + offset }
        proposals = LocationMatcher.match(dates, track: track, maxGap: maxGapMinutes * 60)
        matchBusy = false
        let source = matchSource == .photosLibrary ? "your Photos library" : "the located photos here"
        matchStatus = track.isEmpty
            ? "No located photos in \(source) from around then."
            : "\(proposals.count) of \(captureDates.count) photos match a track of \(visibleTrack.count) points from \(source)."
        if !proposals.isEmpty {
            let pins = Array(proposals.values.map(\.coordinate))
            withAnimation { position = Self.framing(pins) }
        }
    }

    private func applyMatches() {
        let chosen = proposals
        stopMatching()
        Task {
            for (url, m) in chosen { await model.setLocation(m.coordinate, for: url) }
        }
    }

    private static func framing(_ coordinates: [CLLocationCoordinate2D]) -> MapCameraPosition {
        let points = coordinates.map(MKMapPoint.init)
        guard let first = points.first else { return .automatic }
        var rect = MKMapRect(origin: first, size: MKMapSize(width: 0, height: 0))
        for p in points.dropFirst() { rect = rect.union(MKMapRect(origin: p, size: MKMapSize(width: 0, height: 0))) }
        let minimum = MKMapPointsPerMeterAtLatitude(first.coordinate.latitude) * 2000
        let w = max(rect.width, minimum), h = max(rect.height, minimum)
        return .rect(MKMapRect(x: rect.midX - w * 0.7, y: rect.midY - h * 0.75, width: w * 1.4, height: h * 1.5))
    }

    private static func zoneName(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "−" : "+"
        let h = abs(seconds) / 3600, m = abs(seconds) % 3600 / 60
        let base = m == 0 ? "UTC\(sign)\(h)" : "UTC\(sign)\(h):\(String(format: "%02d", m))"
        return seconds == TimeZone.current.secondsFromGMT() ? "\(base) (this Mac)" : base
    }

    private static func gapText(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "under a minute" : "\(Int(seconds / 60)) min"
    }

    // MARK: Search

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Maps", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { search() }
                if searching {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty {
                    Button { clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            if !results.isEmpty {
                Divider()
                ForEach(results, id: \.self) { item in
                    Button { show(item) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name ?? "Unnamed place")
                            if let address = item.address?.shortAddress {
                                Text(address).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }

    /// Apple Maps search, near what the map is showing
    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.resultTypes = [.address, .pointOfInterest]
        if let region = position.region ?? camera.map({ MKCoordinateRegion(center: $0.centerCoordinate, latitudinalMeters: $0.distance, longitudinalMeters: $0.distance) }) {
            request.region = region
        }
        searching = true
        Task {
            defer { searching = false }
            let response = try? await MKLocalSearch(request: request).start()
            let items = Array((response?.mapItems ?? []).prefix(5))
            // one clear answer goes straight there
            if items.count == 1, let only = items.first { show(only) } else { results = items }
        }
    }

    private func show(_ item: MKMapItem) {
        found = item
        results = []
        query = item.name ?? query
        withAnimation {
            position = .camera(MapCamera(centerCoordinate: item.location.coordinate, distance: 6_000))
        }
    }

    private func clearSearch() {
        query = ""
        results = []
        found = nil
    }

    @ViewBuilder
    private func menu(_ item: LibraryItem) -> some View {
        ItemMenu(item: item)
        if model.library.locations[item.url] != nil {
            Divider()
            Button("Remove Location") { Task { await model.setLocation(nil, for: item.url) } }
        }
    }

    /// All the located photos, with room around them for the pins, which
    /// automatic framing doesn't allow for.
    private func framing(_ placed: [LibraryItem]) -> MapCameraPosition {
        let points = placed.compactMap { model.library.locations[$0.url] }.map(MKMapPoint.init)
        guard let first = points.first else { return .automatic }
        var rect = MKMapRect(origin: first, size: MKMapSize(width: 0, height: 0))
        for p in points.dropFirst() { rect = rect.union(MKMapRect(origin: p, size: MKMapSize(width: 0, height: 0))) }
        // at least a few kilometres across, so one photo or a close group isn't at street level
        let minimum = MKMapPointsPerMeterAtLatitude(first.coordinate.latitude) * 3000
        let w = max(rect.width, minimum), h = max(rect.height, minimum)
        let padded = MKMapRect(x: rect.midX - w * 0.7, y: rect.midY - h * 0.75, width: w * 1.4, height: h * 1.5)
        return .rect(padded)
    }

    @ViewBuilder
    private func status(placed: Int) -> some View {
        if model.library.items.isEmpty && !model.library.isScanning {
            Text(model.library.source == .map
                 ? "No photos yet: add folders to the library, or open a photo, to see them here."
                 : "No photos here to show on the map.")
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
        } else if model.library.isLoadingLocations && placed == 0 {
            Text("Reading locations…")
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 16)
        }
    }
}

/// The system drag image: empty, so it doesn't cover the drop point. (Drag
/// previews are drawn outside the window's views, without its environment,
/// so nothing here may read the model; Thumbnail did, and crashed.)
private struct DragPreview: View {
    var body: some View { Color.clear.frame(width: 1, height: 1) }
}

/// The photo being dropped, on a pin whose tip is exactly the drop point.
private struct DropMarker: View {
    let image: CGImage?
    static let height: CGFloat = 104

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            // the stalk down to the point
            Rectangle().fill(.white).frame(width: 2, height: 30)
                .shadow(color: .black.opacity(0.5), radius: 1)
            Circle().fill(.red).frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
        }
        .frame(height: Self.height, alignment: .bottom)
        // the dot's centre, not its bottom edge, is the point
        .offset(y: 5)
    }
}

/// Drops photos on the map, tracking the pointer during the drag so a pin
/// can show exactly where they'll land.
private struct MapDrop: DropDelegate {
    @Binding var point: CGPoint?
    let drop: @MainActor ([URL], CGPoint) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { point = info.location }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        point = info.location
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { point = nil }

    func performDrop(info: DropInfo) -> Bool {
        let location = info.location
        point = nil
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let drop = self.drop
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { drop([url], location) }
            }
        }
        return true
    }
}
