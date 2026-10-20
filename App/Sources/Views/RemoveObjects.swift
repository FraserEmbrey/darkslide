import SwiftUI

/// The Remove Objects tool's panel, in place of the inspector while it's on.
struct ObjectsPanel: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Remove Objects").font(.headline)
                Spacer()
                if model.isFillingObjects { ProgressView().controlSize(.small) }
            }
            ParamSlider(label: "Brush", value: model.objectBrush * 100, defaultValue: 2, range: 0.3...10,
                        isInteger: false, unit: nil, trackColors: nil, editsPhoto: false, showsValue: false) { model.objectBrush = $0 / 100 }
            Text("Paint over something to remove it, covering it and a little around it. A machine learning model (LaMa) fills it in from what's around. Click a painted area to select it; Delete removes it. [ and ] change the brush.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(model.cleanUpMarks.isEmpty ? "Nothing removed" : model.cleanUpMarks.count == 1 ? "1 area" : "\(model.cleanUpMarks.count) areas")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Remove Selected") { if let id = model.selectedMark { model.removeObjectMark(id) } }
                    .disabled(model.selectedMark == nil)
            }
            Button("Remove All") { model.removeAllObjectMarks() }
                .disabled(model.cleanUpMarks.isEmpty)
            Text("Works best on small and medium things with plenty around them; large ones come out softer. Darkslide keeps this layer itself, over darktable's edit, so darktable doesn't show it. For dust and spots, Spot Removal is sharper.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Done") { model.isRemovingObjects = false }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            Group {
                Button("") { if let id = model.selectedMark { model.removeObjectMark(id) } }
                    .keyboardShortcut(.delete, modifiers: [])
                Button("") { model.objectBrush = max(0.003, model.objectBrush / 1.2) }
                    .keyboardShortcut("[", modifiers: [])
                Button("") { model.objectBrush = min(0.1, model.objectBrush * 1.2) }
                    .keyboardShortcut("]", modifiers: [])
            }
            .frame(width: 0, height: 0).opacity(0)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Painting over the photo: the stroke shows as it's drawn, and the areas
/// already removed are outlined. A click without a drag selects one.
struct ObjectsOverlay: View {
    @Environment(EditorModel.self) private var model
    let toView: (CGPoint) -> CGPoint
    let toImage: (CGPoint) -> CGPoint

    @State private var stroke: [CGPoint] = []   // view points
    @State private var hover: CGPoint?

    private var brushRadius: Double { model.objectBrush * min(model.imageSize.width, model.imageSize.height) }

    var body: some View {
        Canvas { ctx, _ in
            for m in model.cleanUpMarks {
                guard let p = model.placedMarks[m.id] else { continue }
                let path = viewPath(p.points)
                let width = viewRadius(p.radius, at: p.points[0]) * 2
                let selected = model.selectedMark == m.id
                ctx.stroke(path, with: .color((selected ? Color.accentColor : .white).opacity(selected ? 0.35 : 0.15)),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
            if !stroke.isEmpty {
                var path = Path()
                path.addLines(stroke)
                if stroke.count == 1 { path.addLine(to: stroke[0]) }
                let width = viewRadius(brushRadius, at: toImage(stroke[0])) * 2
                ctx.stroke(path, with: .color(.red.opacity(0.45)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            } else if let h = hover {
                let r = viewRadius(brushRadius, at: toImage(h))
                ctx.stroke(Path(ellipseIn: CGRect(x: h.x - r, y: h.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(.white.opacity(0.7)), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let p) = phase { hover = p } else { hover = nil }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if stroke.isEmpty { stroke = [g.startLocation] }
                // a point every few pixels is plenty for a round brush
                if let last = stroke.last, hypot(g.location.x - last.x, g.location.y - last.y) > 3 { stroke.append(g.location) }
            }
            .onEnded { g in
                defer { stroke = [] }
                // a click on an area selects it
                if hypot(g.translation.width, g.translation.height) < 3, let hit = hitTest(g.startLocation) {
                    model.selectedMark = hit
                    return
                }
                model.addObjectMark(stroke.map(toImage), radius: brushRadius)
            })
    }

    private func viewPath(_ pts: [CGPoint]) -> Path {
        var p = Path()
        let v = pts.map(toView)
        p.addLines(v)
        if v.count == 1 { p.addLine(to: v[0]) }
        return p
    }

    private func viewRadius(_ r: Double, at p: CGPoint) -> Double {
        let a = toView(p), b = toView(CGPoint(x: p.x + r, y: p.y))
        return hypot(b.x - a.x, b.y - a.y)
    }

    private func hitTest(_ v: CGPoint) -> UUID? {
        let p = toImage(v)
        for m in model.cleanUpMarks.reversed() {
            guard let placed = model.placedMarks[m.id] else { continue }
            if placed.points.contains(where: { hypot($0.x - p.x, $0.y - p.y) <= placed.radius }) { return m.id }
        }
        return nil
    }
}
