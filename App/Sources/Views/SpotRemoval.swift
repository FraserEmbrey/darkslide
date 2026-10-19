import SwiftUI

/// The spot removal tool's panel, in place of the inspector while it's on,
/// as the crop tool's is.
struct SpotPanel: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            Text("Spot Removal").font(.headline)
            Picker("Mode", selection: $model.spotClones) {
                Text("Heal").tag(false)
                Text("Clone").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ParamSlider(label: "Size", value: model.spotSize * 100, defaultValue: 2, range: 0.3...10,
                        isInteger: false, unit: "%", trackColors: nil, editsPhoto: false) { model.spotSize = $0 / 100 }
            Text("Click a spot to remove it. Darkslide picks a patch nearby to heal it from; drag either circle to move it. Heal blends the patch into its surroundings, clone copies it as it is. Delete removes the selected spot. [ and ] change the size.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(model.spots.isEmpty ? "No spots" : model.spots.count == 1 ? "1 spot" : "\(model.spots.count) spots")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Remove Selected") { if let id = model.selectedSpot { model.removeSpot(id) } }
                    .disabled(model.selectedSpot == nil)
            }
            Text("darktable's retouch module does the healing, so the spots are in the sidecar and darktable shows them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button { model.isRemovingSpots = false } label: { Text("Done").frame(maxWidth: .infinity) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
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
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The spots on the photo: each spot's circle, its source dashed, a line
/// between. A click elsewhere adds a spot; dragging a circle moves it.
/// `toView` and `toImage` map between output pixels and this view's points.
struct SpotOverlay: View {
    @Environment(EditorModel.self) private var model
    let toView: (CGPoint) -> CGPoint
    let toImage: (CGPoint) -> CGPoint

    @State private var drag: (spot: Engine.Spot, source: Bool, start: CGPoint)?
    @State private var hover: CGPoint?

    var body: some View {
        GeometryReader { _ in
            ZStack {
                Canvas { ctx, _ in
                    for s in model.spots { draw(s, in: &ctx) }
                    // the size a click would make
                    if let h = hover, drag == nil {
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
                    if drag == nil {
                        if let hit = hitTest(g.startLocation) {
                            model.selectedSpot = hit.spot.id
                            drag = (hit.spot, hit.source, toImage(g.startLocation))
                        } else {
                            return
                        }
                    }
                    guard let d = drag else { return }
                    let now = toImage(g.location)
                    var s = d.spot
                    let dx = now.x - d.start.x, dy = now.y - d.start.y
                    if d.source { s.sx += dx; s.sy += dy } else { s.x += dx; s.y += dy; s.sx += dx; s.sy += dy }
                    model.moveSpot(s)
                }
                .onEnded { g in
                    if drag == nil, hypot(g.translation.width, g.translation.height) < 3 {
                        let p = toImage(g.startLocation)
                        if p.x >= 0, p.y >= 0, p.x <= model.imageSize.width, p.y <= model.imageSize.height { model.addSpot(at: p) }
                    }
                    drag = nil
                })
        }
    }

    private func radiusInView(_ r: Double, at p: CGPoint) -> Double {
        let a = toView(p), b = toView(CGPoint(x: p.x + r, y: p.y))
        return hypot(b.x - a.x, b.y - a.y)
    }

    private func draw(_ s: Engine.Spot, in ctx: inout GraphicsContext) {
        let c = toView(s.center), src = toView(s.source), r = radiusInView(s.r, at: s.center)
        let selected = model.selectedSpot == s.id
        let colour: Color = selected ? .accentColor : .white
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
        for s in model.spots.reversed() {
            let r = radiusInView(s.r, at: s.center)
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
