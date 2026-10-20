import SwiftUI

/// The Retouch tool's panel, in place of the inspector while it's on, as the
/// crop tool's is: Heal and Clone (darktable's retouch) or Remove (machine
/// learning), as one tool, as Lightroom has them.
struct RetouchPanel: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Retouch").font(.headline)
                if model.isFillingObjects { ProgressView().controlSize(.small) }
                Spacer()
            }
            Picker("Mode", selection: Binding(get: { model.retouchMode },
                                              set: { m in Task { await model.chooseRetouchMode(m) } })) {
                ForEach(RetouchMode.allCases) { m in
                    Text(m.title).tag(m)
                        .disabled(m == .remove && !model.canRemoveObjects)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Heal blends a nearby patch in, Clone copies it as it is, Remove fills in what was behind with machine learning")
            if model.isRemovingObjects { ObjectControls() } else { SpotControls() }
            Spacer()
            // as the crop panel's
            HStack {
                // the label fills, so the buttons share the width
                Button { Task { await model.cancelRetouching() } } label: { Text("Cancel").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                    .help("Undo what was retouched since the tool was opened")
                Button { Task { await model.setRetouching(false) } } label: { Text("Done").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Heal and Clone's controls in the Retouch panel.
struct SpotControls: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ParamSlider(label: "Size", value: model.spotSize * 100, defaultValue: 2, range: 0.3...10,
                        isInteger: false, unit: nil, trackColors: nil, editsPhoto: false, showsValue: false) { model.spotSize = $0 / 100 }
            Text("Click a spot to remove it, or paint over something longer, such as a wire. Darkslide picks a patch nearby to heal it from; drag the spot or its dashed source to move them. Delete removes the selected spot. [ and ] change the size.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(model.spots.isEmpty ? "No spots" : model.spots.count == 1 ? "1 spot" : "\(model.spots.count) spots")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Remove Selected") { if let id = model.selectedSpot { model.removeSpot(id) } }
                    .disabled(model.selectedSpot == nil)
            }
            Text("darktable's retouch module does the healing, so the spots are in the sidecar and darktable shows them. For people and bigger things, Remove fills in better.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Delete and the bracket keys
            Group {
                Button("") { if let id = model.selectedSpot { model.removeSpot(id) } }
                    .keyboardShortcut(.delete, modifiers: [])
                Button("") { model.spotSize = max(0.003, model.spotSize / 1.2) }
                    .keyboardShortcut("[", modifiers: [])
                Button("") { model.spotSize = min(0.1, model.spotSize * 1.2) }
                    .keyboardShortcut("]", modifiers: [])
            }
            .frame(width: 0, height: 0).opacity(0)
        }
    }
}

/// The spots on the photo: each spot's circle or painted stroke, its source
/// dashed, a line between. A click elsewhere adds a spot, a drag paints a
/// stroke to heal; dragging a spot moves it, its source moves the source.
/// `toView` and `toImage` map between output pixels and this view's points.
struct SpotOverlay: View {
    @Environment(EditorModel.self) private var model
    let toView: (CGPoint) -> CGPoint
    let toImage: (CGPoint) -> CGPoint

    @State private var drag: (spot: Engine.Spot, source: Bool, start: CGPoint)?
    /// a stroke being painted, in this view's points
    @State private var painting: [CGPoint] = []
    @State private var hover: CGPoint?

    var body: some View {
        GeometryReader { _ in
            ZStack {
                Canvas { ctx, _ in
                    for s in model.spots { draw(s, in: &ctx) }
                    if let first = painting.first {
                        let r = radiusInView(model.spotSize * min(model.imageSize.width, model.imageSize.height), at: toImage(first))
                        ctx.stroke(path(painting), with: .color(.white.opacity(0.35)),
                                   style: StrokeStyle(lineWidth: 2 * r, lineCap: .round, lineJoin: .round))
                    }
                    // the size a click would make
                    if let h = hover, drag == nil, painting.isEmpty {
                        let r = radiusInView(model.spotSize * min(model.imageSize.width, model.imageSize.height), at: toImage(h))
                        ctx.stroke(Path(ellipseIn: CGRect(x: h.x - r, y: h.y - r, width: 2 * r, height: 2 * r)),
                                   with: .color(.white.opacity(0.6)), lineWidth: 1)
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = p } else { hover = nil }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if drag == nil, painting.isEmpty {
                        if let hit = hitTest(g.startLocation) {
                            model.selectedSpot = hit.spot.id
                            drag = (hit.spot, hit.source, toImage(g.startLocation))
                        } else {
                            painting = [g.startLocation]
                        }
                    }
                    if !painting.isEmpty {
                        if let last = painting.last, hypot(g.location.x - last.x, g.location.y - last.y) > 3 { painting.append(g.location) }
                        return
                    }
                    guard let d = drag else { return }
                    let now = toImage(g.location)
                    model.moveSpot(d.spot.moved(dx: now.x - d.start.x, dy: now.y - d.start.y, sourceOnly: d.source))
                }
                .onEnded { _ in
                    defer { drag = nil; painting = [] }
                    guard let start = painting.first else { return }
                    let inside = { (p: CGPoint) in p.x >= 0 && p.y >= 0 && p.x <= model.imageSize.width && p.y <= model.imageSize.height }
                    if painting.count < 3 {
                        // a click: a spot there
                        let p = toImage(start)
                        if inside(p) { model.addSpot(at: p) }
                    } else {
                        let pts = painting.map(toImage).filter(inside)
                        if pts.count > 1 { model.addHealStroke(pts) }
                    }
                })
        }
    }

    private func radiusInView(_ r: Double, at p: CGPoint) -> Double {
        let a = toView(p), b = toView(CGPoint(x: p.x + r, y: p.y))
        return hypot(b.x - a.x, b.y - a.y)
    }

    private func path(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(pts)
        if pts.count == 1 { p.addLine(to: pts[0]) }
        return p
    }

    private func draw(_ s: Engine.Spot, in ctx: inout GraphicsContext) {
        let c = toView(s.center), src = toView(s.source), r = radiusInView(s.r, at: s.center)
        let selected = model.selectedSpot == s.id
        let colour: Color = selected ? .accentColor : .white
        if let stroke = s.stroke?.map(toView), !stroke.isEmpty {
            // a painted stroke: its outline, and its source's, as for a circle
            let outline = path(stroke).strokedPath(StrokeStyle(lineWidth: 2 * r, lineCap: .round, lineJoin: .round))
            ctx.stroke(outline, with: .color(.black.opacity(0.5)), lineWidth: 3)
            ctx.stroke(outline, with: .color(colour), lineWidth: 1.5)
            if selected {
                let from = outline.offsetBy(dx: src.x - c.x, dy: src.y - c.y)
                ctx.stroke(from, with: .color(colour), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            return
        }
        let circle = { (p: CGPoint) in Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
        ctx.stroke(circle(c), with: .color(.black.opacity(0.5)), lineWidth: 3)
        ctx.stroke(circle(c), with: .color(colour), lineWidth: 1.5)
        if selected {
            ctx.stroke(circle(src), with: .color(colour), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            let d = hypot(src.x - c.x, src.y - c.y)
            if d > 2 * r {
                let ux = (src.x - c.x) / d, uy = (src.y - c.y) / d
                var line = Path()
                line.move(to: CGPoint(x: c.x + ux * r, y: c.y + uy * r))
                line.addLine(to: CGPoint(x: src.x - ux * r, y: src.y - uy * r))
                ctx.stroke(line, with: .color(colour.opacity(0.8)), lineWidth: 1)
            }
        }
    }

    /// the spot (or, for the selected one, its source) under a point
    private func hitTest(_ v: CGPoint) -> (spot: Engine.Spot, source: Bool)? {
        /// how far a point is from a stroke
        func distance(_ p: CGPoint, to pts: [CGPoint]) -> Double {
            guard pts.count > 1 else { return pts.first.map { hypot(p.x - $0.x, p.y - $0.y) } ?? .infinity }
            return (1..<pts.count).map { i in
                let a = pts[i - 1], b = pts[i]
                let dx = b.x - a.x, dy = b.y - a.y, len = dx * dx + dy * dy
                let t = len > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len)) : 0
                return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
            }.min()!
        }
        for s in model.spots.reversed() {
            let r = radiusInView(s.r, at: s.center)
            if let stroke = s.stroke?.map(toView) {
                if s.id == model.selectedSpot {
                    let c = toView(s.center), src = toView(s.source)
                    if distance(v, to: stroke.map { CGPoint(x: $0.x + src.x - c.x, y: $0.y + src.y - c.y) }) <= r { return (s, true) }
                }
                if distance(v, to: stroke) <= r { return (s, false) }
                continue
            }
            if s.id == model.selectedSpot {
                let src = toView(s.source)
                if hypot(v.x - src.x, v.y - src.y) <= r { return (s, true) }
            }
            let c = toView(s.center)
            if hypot(v.x - c.x, v.y - c.y) <= r { return (s, false) }
        }
        return nil
    }
}
