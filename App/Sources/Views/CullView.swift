import SwiftUI

/// Culling, one photo at a time: the camera's own preview, big and instant,
/// rated from the keyboard. Bursts are found (taken close together and alike)
/// and shown as a bar of their frames' sharpness, with the frame to keep
/// suggested; P keeps the frame showing and rejects the burst's other
/// unrated frames. Ratings go in the sidecars, as darktable keeps them.
struct CullView: View {
    @Environment(EditorModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @FocusState private var focused: Bool
    @AppStorage("CullAutoAdvance") private var autoAdvance = true
    @AppStorage("CullShowArea") private var showArea = false
    @State private var image: CGImage?
    @State private var imageURL: URL?
    @State private var viewSize = CGSize(width: 1200, height: 800)
    @State private var zoomed = false
    @State private var full: CGImage?
    @State private var pan = CGSize.zero
    @State private var panStart = CGSize.zero
    @State private var confirmingBin = false

    private var library: Library { model.library }
    private var culling: Culling { model.culling }
    private var current: URL? { library.selection }
    /// the long edge the previews load at: the view's, in pixels
    private var pixels: Int { min(4096, Int(max(viewSize.width, viewSize.height) * displayScale)) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            loupe
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let burst = culling.burst(of: current) {
                Divider()
                BurstBar(burst: burst, current: current) { select($0) }
                    .frame(height: 74)
            }
            Divider()
            RunStrip(current: current) { select($0) }
                .frame(height: 92)
            keyHints
        }
        .background(Color(.sRGB, white: 0.08))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear {
            focused = true
            // the photo you were on, as the grid does
            if current == nil || !library.contains(current!) { library.selection = model.libraryURL ?? library.items.first?.url }
            culling.analyse(library.allPhotos, from: current)
            // LogCull: launch argument (-LogCull YES) for testing
            if UserDefaults.standard.bool(forKey: "LogCull") {
                let shown = current
                FileHandle.standardError.write("Darkslide cull: starts on \(shown?.lastPathComponent ?? "-")\n".data(using: .utf8)!)
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    let measured = culling.facts.keys.map(\.lastPathComponent).sorted()
                    FileHandle.standardError.write("Darkslide cull: after 6 s, \(culling.progress.map { "\($0.done) of \($0.total)" } ?? "done"); this photo measured \(shown.map { culling.facts[$0] != nil } ?? false); measured from \(measured.first ?? "-") to \(measured.last ?? "-"); \(culling.burstCount) bursts so far; first run starts \(culling.runs.first?.first?.lastPathComponent ?? "-")\n".data(using: .utf8)!)
                }
            }
            // TestCull: launch argument (-TestCull YES) for testing: once measured, logs the
            // bursts, keeps the first burst's suggested frame and checks its sidecars
            if UserDefaults.standard.bool(forKey: "TestCull") { Task { await test() } }
        }
        .onChange(of: library.allPhotos) { _, photos in culling.analyse(photos, from: current) }
        .task(id: current) { await load() }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
            switch press.key {
            case .leftArrow: step(-1)
            case .rightArrow: step(1)
            case .upArrow: jumpRun(-1)
            default: jumpRun(1)
            }
            return .handled
        }
        .onKeyPress(.return) {
            if let current { Task { await model.open(current) } }
            return .handled
        }
        .onKeyPress(.space) { toggleZoom(); return .handled }
        .onKeyPress(phases: .down) { press in
            // ⇧X: the whole burst
            if press.characters.lowercased() == "x", press.modifiers.contains(.shift), let current, let burst = culling.burst(of: current) {
                model.setRating(-1, for: burst)
                if autoAdvance { jumpRun(1, fromEnd: true) }
                return .handled
            }
            return key(press.characters.lowercased()) ? .handled : .ignored
        }
        .confirmationDialog(binTitle, isPresented: $confirmingBin) {
            Button("Move to Bin", role: .destructive) { Task { await model.moveRejectedToBin() } }
        } message: {
            Text("Their sidecars go too. You can put them back from the Bin.")
        }
    }

    private func test() async {
        func log(_ s: String) { FileHandle.standardError.write("Darkslide cull test: \(s)\n".data(using: .utf8)!) }
        let started = Date()
        while culling.progress == nil, culling.runs.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        while culling.progress != nil { try? await Task.sleep(for: .milliseconds(500)) }
        log("measured \(culling.facts.count) in \(Int(Date().timeIntervalSince(started))) s; \(culling.runs.count) runs, \(culling.burstCount) bursts")
        guard let (i, run) = culling.runs.enumerated().first(where: { $0.element.count > 1 }), let best = culling.suggested(in: i) else { return }
        library.selection = best
        try? await Task.sleep(for: .seconds(2))
        model.keepOnly(best)
        try? await Task.sleep(for: .seconds(Double(run.count) * 0.2 + 3))
        let written = run.filter { FileManager.default.fileExists(atPath: Sidecar.url(for: $0).path) }
        let read = run.map { u in (try? String(contentsOf: Sidecar.url(for: u), encoding: .utf8)).flatMap(Sidecar.rating(inXMP:)) ?? 99 }
        log("burst of \(run.count), kept \(best.lastPathComponent); sidecars \(written.count); ratings in them \(Dictionary(grouping: read, by: { $0 }).mapValues(\.count)); edited \(run.filter(Sidecar.hasEdit).count)")
        // then the middle of the biggest burst, to see its bar
        if let big = culling.runs.max(by: { $0.count < $1.count }) {
            library.selection = big[big.count / 2]
            log("biggest burst \(big.count), suggested \(culling.isSuggested(big[big.count / 2]) ? "this" : (big.first(where: culling.isSuggested)?.lastPathComponent ?? "none"))")
        }
    }

    // MARK: Keys

    private func key(_ c: String) -> Bool {
        guard let current else { return false }
        switch c {
        case "1", "2", "3", "4", "5":
            model.setRating(Int(c)!, for: [current])
            if autoAdvance { step(1) }
        case "0":
            model.setRating(0, for: [current])
        case "x":
            model.setRating(-1, for: [current])
            if autoAdvance { step(1) }
        case "p":
            model.keepOnly(current)
            if autoAdvance { jumpRun(1, fromEnd: true) }
        case "z":
            toggleZoom()
        default:
            return false
        }
        return true
    }

    private func select(_ url: URL) {
        library.selection = url
        focused = true
    }

    /// the next or previous photo showing
    private func step(_ offset: Int) {
        if let next = library.neighbour(of: current, offset: offset) { library.selection = next }
    }

    /// The next or previous burst (or photo on its own) with something
    /// showing: its suggested frame if that's showing, else its first.
    /// `fromEnd`: from the end of this burst, after keeping a frame of it.
    private func jumpRun(_ direction: Int, fromEnd: Bool = false) {
        let showing = Set(library.items.map(\.url))
        guard let r = culling.run(of: current) else { step(direction); return }
        var i = r + direction
        while culling.runs.indices.contains(i) {
            let run = culling.runs[i].filter(showing.contains)
            if !run.isEmpty {
                let best = culling.suggested(in: i)
                library.selection = best.flatMap { showing.contains($0) ? $0 : nil } ?? run.first
                return
            }
            i += direction
        }
        // past the last burst: the last photo showing, if this one has gone
        if fromEnd, let last = library.items.last?.url, last != current { library.selection = last }
    }

    // MARK: Loupe

    private func load() async {
        zoomed = false
        full = nil
        pan = .zero
        guard let url = current else { image = nil; return }
        if let cached = culling.cachedPreview(url) {
            image = cached
            imageURL = url
        }
        if let loaded = await culling.preview(url, pixels: pixels), url == current {
            image = loaded
            imageURL = url
        }
        // the next few either way, so stepping or scrubbing a burst is instant
        var ahead: [URL] = []
        for o in [1, -1, 2, 3, -2] { if let n = library.neighbour(of: url, offset: o) { ahead.append(n) } }
        culling.prefetch(ahead, pixels: pixels)
    }

    private func toggleZoom() {
        guard let url = current else { return }
        zoomed.toggle()
        pan = .zero
        panStart = .zero
        if zoomed, full == nil {
            Task {
                let image = await Task.detached(priority: .userInitiated) { CullAnalysis.fullSize(url) }.value
                if url == current { full = image }
            }
        }
    }

    @ViewBuilder private var loupe: some View {
        GeometryReader { geo in
            ZStack {
                if zoomed, let full {
                    zoomedImage(full, in: geo.size)
                } else if let image {
                    let fit = fitted(image, in: geo.size)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                        .overlay {
                            if showArea, let area = culling.facts[imageURL ?? current!]?.subject {
                                Rectangle()
                                    .strokeBorder(Color.yellow.opacity(0.8), lineWidth: 1.5)
                                    .frame(width: area.width * fit.width, height: area.height * fit.height)
                                    .position(x: area.midX * fit.width, y: area.midY * fit.height)
                            }
                        }
                        .opacity(library.rating(of: current ?? URL(fileURLWithPath: "/")) < 0 ? 0.45 : 1)
                } else if current == nil {
                    ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle",
                                           description: Text(library.ratingFilter == .all ? "This folder has no photos." : "None match the filter."))
                } else {
                    ProgressView()
                }
                overlays
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onAppear { viewSize = geo.size }
            .onChange(of: geo.size) { _, s in viewSize = s }
        }
    }

    private func fitted(_ image: CGImage, in size: CGSize) -> CGSize {
        let s = min((size.width - 24) / CGFloat(image.width), (size.height - 24) / CGFloat(image.height))
        return CGSize(width: CGFloat(image.width) * s, height: CGFloat(image.height) * s)
    }

    /// at 100%: a screen pixel for each pixel, centred on where sharpness was
    /// measured, and dragged to look around
    private func zoomedImage(_ full: CGImage, in size: CGSize) -> some View {
        let w = CGFloat(full.width) / displayScale, h = CGFloat(full.height) / displayScale
        let area = current.flatMap { culling.facts[$0]?.subject } ?? CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
        // the area's middle at the view's
        let x = w / 2 - area.midX * w + pan.width, y = h / 2 - area.midY * h + pan.height
        return Image(decorative: full, scale: displayScale)
            .frame(width: w, height: h)
            .offset(x: x, y: y)
            .gesture(DragGesture()
                .onChanged { g in pan = CGSize(width: panStart.width + g.translation.width, height: panStart.height + g.translation.height) }
                .onEnded { _ in panStart = pan })
    }

    @ViewBuilder private var overlays: some View {
        if let url = current {
            let facts = culling.facts[url]
            VStack {
                // not measured yet: no burst or suggestion for it so far
                if facts == nil, let p = culling.progress {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Measuring photos: \(p.done) of \(p.total)").font(.callout.weight(.semibold))
                            Text("Bursts, sharpness and suggestions for this photo appear once it's measured. Rating works now.")
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                }
                HStack(alignment: .top) {
                    chip {
                        Text(url.lastPathComponent).font(.callout.weight(.semibold))
                        if let t = facts?.time {
                            Text(Date(timeIntervalSince1970: t), format: .dateTime.hour().minute().second())
                                .foregroundStyle(.secondary)
                        }
                        if zoomed { Text("100%").foregroundStyle(.secondary) }
                    }
                    Spacer()
                    RatingMark(rating: library.rating(of: url))
                }
                Spacer()
                HStack(spacing: 6) {
                    if let burst = culling.burst(of: url), let i = burst.firstIndex(of: url) {
                        chip { Text("Frame \(i + 1) of \(burst.count)") }
                    }
                    if culling.isSuggested(url) {
                        chip { Label("Suggested", systemImage: "star.circle.fill").foregroundStyle(.yellow) }
                            .help("The frame of this burst to keep: the sharpest where the camera focused, with eyes open")
                    }
                    if culling.burst(of: url) != nil, facts != nil {
                        chip { Text("Sharpness \(Int((culling.relativeSharpness(url) * 100).rounded()))%") }
                            .help("Against the sharpest frame of the burst, where the camera focused")
                    }
                    if facts?.eyesClosed == true {
                        chip { Label("Eyes may be closed", systemImage: "eye.slash").foregroundStyle(.orange) }
                    }
                    if facts?.focusOnSubject == false {
                        chip { Label("Focus off the subject", systemImage: "person.crop.rectangle.badge.xmark").foregroundStyle(.orange) }
                            .help("The camera's AF area wasn't on any of the people in the frame, so it likely focused on the background")
                    }
                    if facts?.inFocus == false {
                        chip { Label("Camera didn't confirm focus", systemImage: "scope").foregroundStyle(.orange) }
                    }
                    Spacer()
                }
            }
            .padding(12)
        }
    }

    private func chip<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) { content() }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.white)
    }

    // MARK: Bars

    private var topBar: some View {
        @Bindable var library = model.library
        return HStack(spacing: 14) {
            Picker("Show", selection: $library.ratingFilter) {
                ForEach(Library.RatingFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if let p = culling.progress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    .frame(width: 120)
                Text("Measuring \(p.done) of \(p.total)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if culling.burstCount > 0 {
                Text("\(culling.burstCount) bursts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Show Measured Area", isOn: $showArea)
                .help("Outline where each photo's sharpness was measured: the person the camera focused on (else the most prominent person), else the AF area")
            Toggle("Auto-advance", isOn: $autoAdvance)
                .help("Move on after rating a photo")
            Menu("Actions") {
                Button("Keep Suggested Frame of Every Unrated Burst") { model.keepSuggestedInEveryBurst() }
                    .disabled(culling.burstCount == 0 || culling.progress != nil)
                    .help("Each burst you haven't rated keeps its suggested frame; the rest of it is rejected")
                Divider()
                Button("Move Rejected to Bin…") { confirmingBin = true }
                    .disabled(!library.items.contains { library.rating(of: $0.url) < 0 })
            }
            .fixedSize()
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var binTitle: String {
        let r = model.rejectedPhotos
        let size = ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file)
        return "Move \(r.photos.count) rejected \(r.photos.count == 1 ? "photo" : "photos") (\(size)) to the Bin?"
    }

    private var keyHints: some View {
        Text("1–5 rate · X reject · ⇧X reject the burst · 0 clear · P keep this frame, reject the burst's other unrated frames · ← → photo · ↑ ↓ burst · Z or Space 100% · ↩ edit")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(.bar)
    }
}

/// A photo's rating as shown on it: stars, or Rejected.
struct RatingMark: View {
    let rating: Int

    var body: some View {
        if rating < 0 {
            Label("Rejected", systemImage: "xmark")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.white)
        } else if rating > 0 {
            HStack(spacing: 2) {
                ForEach(0..<rating, id: \.self) { _ in Image(systemName: "star.fill") }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.yellow)
        }
    }
}

/// A burst's frames as bars, from the softest frame's (short) to the sharpest's (tall):
/// click one to see it. The suggested frame has a star above it; rated
/// frames are yellow and rejected ones red.
struct BurstBar: View {
    @Environment(EditorModel.self) private var model
    let burst: [URL]
    let current: URL?
    let choose: (URL) -> Void

    var body: some View {
        let culling = model.culling
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Burst of \(burst.count)")
                if let a = culling.facts[burst.first!]?.time, let b = culling.facts[burst.last!]?.time {
                    Text(String(format: "%.2f s", b - a)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Bars: softest to sharpest where the camera focused · ★ suggested")
                    .foregroundStyle(.secondary)
                Button("Reject Burst") { model.setRating(-1, for: burst) }
                    .controlSize(.small)
                    .help("Reject every frame of this burst (⇧X)")
            }
            .font(.caption)
            GeometryReader { geo in
                let gap: CGFloat = burst.count > 60 ? 1 : 2
                let w = max(2, min(16, (geo.size.width - gap * CGFloat(burst.count - 1)) / CGFloat(burst.count)))
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(burst, id: \.self) { u in
                        let rating = model.library.rating(of: u)
                        let h = 3 + culling.sharpnessRank(u) * (geo.size.height - 15)
                        VStack(spacing: 1) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(.yellow)
                                .opacity(culling.isSuggested(u) ? 1 : 0)
                                .frame(height: 9)
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(rating < 0 ? Color.red.opacity(0.6) : rating > 0 ? Color.yellow : Color.secondary.opacity(0.6))
                                .frame(width: w, height: h)
                                .overlay(RoundedRectangle(cornerRadius: 1).strokeBorder(Color.accentColor, lineWidth: u == current ? 2 : 0))
                        }
                        .frame(width: w)
                        .contentShape(Rectangle())
                        .onTapGesture { choose(u) }
                        .help(u.lastPathComponent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Every burst and lone photo in a row, a burst as its suggested frame with
/// a count: click one to go to it.
struct RunStrip: View {
    @Environment(EditorModel.self) private var model
    let current: URL?
    let choose: (URL) -> Void

    var body: some View {
        let culling = model.culling, library = model.library
        let showing = Set(library.items.map(\.url))
        let runs = culling.runs.enumerated().compactMap { i, run -> (Int, [URL], URL)? in
            let shown = run.filter(showing.contains)
            guard !shown.isEmpty else { return nil }
            let face = culling.suggested(in: i).flatMap { showing.contains($0) ? $0 : nil } ?? shown[0]
            return (i, run, face)
        }
        let here = culling.run(of: current)
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(runs, id: \.0) { i, run, face in
                        Thumbnail(item: LibraryItem(url: face, hasEdit: false))
                            .frame(width: 96, height: 64)
                            .overlay(alignment: .topTrailing) {
                                if run.count > 1 {
                                    Text("\(run.count)")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(.black.opacity(0.65), in: Capsule())
                                        .foregroundStyle(.white)
                                        .padding(3)
                                }
                            }
                            .overlay(alignment: .bottomLeading) { runState(run).padding(3) }
                            .padding(3)
                            .background(i == here ? Color.accentColor.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(i == here ? Color.accentColor : .clear, lineWidth: 2))
                            .contentShape(Rectangle())
                            .onTapGesture { choose(face) }
                            .help(run.count > 1 ? "Burst of \(run.count), from \(run[0].lastPathComponent)" : face.lastPathComponent)
                            .id(i)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .background(.bar)
            .onChange(of: here, initial: true) { _, i in
                guard let i else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
    }

    /// done (every frame rated), started, or not yet
    @ViewBuilder private func runState(_ run: [URL]) -> some View {
        let ratings = run.map { model.library.rating(of: $0) }
        if ratings.allSatisfy({ $0 != 0 }) {
            Image(systemName: ratings.contains { $0 > 0 } ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ratings.contains { $0 > 0 } ? .green : .red)
                .background(Circle().fill(.black.opacity(0.5)))
        } else if ratings.contains(where: { $0 != 0 }) {
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(.yellow)
                .background(Circle().fill(.black.opacity(0.5)))
        }
    }
}
