import SwiftUI

/// The local adjustments card: linear and radial gradients and the subject,
/// each a masked exposure instance, with colour balance rgb and local
/// contrast instances sharing its shape for the other sliders. Selecting one shows its shape on the photo.
struct LocalAdjustmentsCard: View {
    @Environment(EditorModel.self) private var model
    @State private var expanded = true
    /// the adjustment being renamed, and its name as typed
    @State private var renaming: String?
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardTitle(title: "Local adjustments", isExpanded: $expanded)
                if model.isFindingSubject { ProgressView().controlSize(.small) }
                Menu {
                    Button("Subject", systemImage: "person.crop.rectangle") { model.addSubject() }
                    Divider()
                    Button("Linear Gradient", systemImage: "square.tophalf.filled") { model.addLocal(.gradient) }
                    Button("Radial Gradient", systemImage: "circle.dashed") { model.addLocal(.ellipse) }
                    Divider()
                    // Aperture's Quick Brushes
                    Section("Brushes") {
                        ForEach(QuickBrush.allCases) { b in
                            Button(b.title, systemImage: b.symbol) { model.startBrush(b) }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.isFindingSubject)
                .help("Adjust the subject, part of the photo with a gradient, or paint it in with a brush")
            }
            if expanded {
                if let brush = model.pendingBrush {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Paint where you want \(brush.title.lowercased()).", systemImage: brush.symbol)
                            .font(.callout)
                        brushControls
                        Button("Cancel") { model.pendingBrush = nil }
                    }
                    .padding(8)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                if model.localAdjustments.isEmpty && model.pendingBrush == nil {
                    Text("Adjust the light, colour and clarity of the subject (found by macOS), or of part of the photo with a linear or radial gradient.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.localAdjustments) { m in
                    row(m)
                }
            }
        }
        .cardStyle()
    }

    /// the brush's size and edge, and painting or erasing
    @ViewBuilder private var brushControls: some View {
        @Bindable var model = model
        ParamSlider(label: "Brush Size", value: model.brushSize * 100, defaultValue: 4, range: 0.5...20,
                    isInteger: false, unit: "%", trackColors: nil, editsPhoto: false) { model.brushSize = $0 / 100 }
        ParamSlider(label: "Softness", value: model.brushSoftness * 100, defaultValue: 50, range: 0...100,
                    isInteger: true, unit: "%", trackColors: nil, editsPhoto: false) { model.brushSoftness = $0 / 100 }
        Picker("Pen Pressure", selection: $model.penPressure) {
            ForEach(BrushPressure.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .help("What a pen's pressure changes as it paints: a drawing tablet's, or Apple Pencil's with an iPad as a Sidecar display")
        Toggle("Show Mask", isOn: $model.showBrushMask)
            .toggleStyle(.checkbox)
            .help("Tint the painted strokes red on the photo, to see exactly where the adjustment is")
        if model.pendingBrush == nil {
            Toggle("Erase", isOn: $model.brushErases)
                .toggleStyle(.checkbox)
                .help("Strokes take the adjustment away; Option does it for one stroke")
        }
    }

    private var hint: String {
        switch model.localShape?.kind {
        case .ellipse: "Drag the centre to move it, the side handles to size it, the outer handle for a softer edge."
        case .subject: "The subject as macOS found it, outlined on the photo."
        case .brush: "Paint to add to it; hold Option, or turn on Erase, to take it away."
        default: "Drag the centre to move it, the arrow to turn it, the dashed line for a softer edge."
        }
    }

    @ViewBuilder
    private func row(_ m: EngineModule) -> some View {
        let selected = model.selectedLocal == m.key
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    model.selectedLocal = selected ? nil : m.key
                } label: {
                    HStack {
                        Image(systemName: selected ? "eye" : "eye.slash")
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                            .frame(width: 18)
                        if renaming == m.key {
                            TextField("Name", text: $draftName)
                                .textFieldStyle(.roundedBorder)
                                .focused($nameFocused)
                                .onSubmit { finishRename(m) }
                                .onExitCommand { renaming = nil }
                                .onChange(of: nameFocused) { _, focused in if !focused { finishRename(m) } }
                        } else {
                            Text(model.localTitle(m))
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded { startRename(m) })
                .help(selected ? "Hide its shape; double-click to rename it" : "Show and edit its shape on the photo; double-click to rename it")
                Toggle("", isOn: Binding(get: { m.enabled }, set: { model.setEnabled($0, module: m.key) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            if selected {
                ForEach(LocalControl.allCases) { c in
                    ParamSlider(label: c.label, value: model.localValue(c, of: m), defaultValue: 0, range: c.range,
                                isInteger: c != .exposure, unit: c.unit,
                                trackColors: c == .warmth ? [.blue, .yellow] : nil, clipping: c == .exposure) {
                        model.setLocal(c, to: $0, of: m)
                    }
                }
                HStack {
                    Spacer()
                    Button("Delete", role: .destructive) { model.deleteLocal(m.key) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                if model.localShape?.kind == .brush { brushControls }
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Rename…") { startRename(m) }
            Button(m.enabled ? "Turn Off" : "Turn On") { model.setEnabled(!m.enabled, module: m.key) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteLocal(m.key) }
        }
    }

    private func startRename(_ m: EngineModule) {
        draftName = model.localTitle(m)
        renaming = m.key
        DispatchQueue.main.async { nameFocused = true }
    }

    private func finishRename(_ m: EngineModule) {
        guard renaming == m.key else { return }
        renaming = nil
        model.renameLocal(m.key, to: draftName)
    }
}

/// The selected local adjustment's shape over the photo, with handles.
/// `toView` and `toImage` map between output pixels and this view's points.
struct LocalShapeOverlay: View {
    @Environment(EditorModel.self) private var model
    let toView: (CGPoint) -> CGPoint
    let toImage: (CGPoint) -> CGPoint

    /// the shape while a drag is under way, ahead of the engine
    @State private var live: LocalShape?
    @State private var start: LocalShape?

    var body: some View {
        if let shape = live ?? model.localShape {
            ZStack {
                Canvas { ctx, size in
                    switch shape.kind {
                    case .gradient: drawGradient(shape, in: &ctx, size: size)
                    case .ellipse: drawEllipse(shape, in: &ctx)
                    case .subject: drawOutlines(shape, in: &ctx)
                    case .brush: break   // BrushOverlay
                    }
                }
                .allowsHitTesting(false)
                ForEach(Array(handles(shape).enumerated()), id: \.offset) { i, h in
                    Circle()
                        .fill(i == 0 ? Color.white : Color.accentColor)
                        .overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 1))
                        .frame(width: i == 0 ? 14 : 11, height: i == 0 ? 14 : 11)
                        .shadow(radius: 1)
                        .position(toView(h))
                        .gesture(DragGesture(coordinateSpace: .named("localOverlay"))
                            .onChanged { g in drag(handle: i, to: toImage(g.location), from: toImage(g.startLocation)) }
                            .onEnded { _ in live = nil; start = nil })
                }
            }
            .coordinateSpace(.named("localOverlay"))
        }
    }

    // MARK: drawing

    private func drawGradient(_ s: LocalShape, in ctx: inout GraphicsContext, size: CGSize) {
        guard s.points.count >= 5 else { return }
        let a = toView(s.points[0]), along = toView(s.points[1]), side = toView(s.points[2])
        let plus = toView(s.points[3]), minus = toView(s.points[4])
        let d = CGVector(dx: along.x - a.x, dy: along.y - a.y)
        let len = max(hypot(d.dx, d.dy), 1)
        let reach = hypot(size.width, size.height) * 2 / len
        func line(through p: CGPoint) -> Path {
            Path { $0.move(to: CGPoint(x: p.x - d.dx * reach, y: p.y - d.dy * reach)); $0.addLine(to: CGPoint(x: p.x + d.dx * reach, y: p.y + d.dy * reach)) }
        }
        ctx.stroke(line(through: a), with: .color(.white), lineWidth: 1.5)
        ctx.stroke(line(through: plus), with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        ctx.stroke(line(through: minus), with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        // the arrow: the side the adjustment fades in toward
        ctx.stroke(Path { $0.move(to: a); $0.addLine(to: side) }, with: .color(.white), lineWidth: 1.5)
    }

    private func drawEllipse(_ s: LocalShape, in ctx: inout GraphicsContext) {
        guard s.points.count >= 131 else { return }
        func ring(_ range: Range<Int>) -> Path {
            Path { p in
                p.addLines(range.map { toView(s.points[$0]) })
                p.closeSubpath()
            }
        }
        ctx.stroke(ring(0..<64), with: .color(.white), lineWidth: 1.5)
        ctx.stroke(ring(64..<128), with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
    }

    private func drawOutlines(_ s: LocalShape, in ctx: inout GraphicsContext) {
        let path = Path { p in
            for o in s.outlines where o.count > 2 {
                p.addLines(o.map(toView))
                p.closeSubpath()
            }
        }
        // dark under light, so the outline shows on any photo
        ctx.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 3)
        ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
    }

    // MARK: handles, in output pixels

    private func handles(_ s: LocalShape) -> [CGPoint] {
        switch s.kind {
        case .gradient:
            guard s.points.count >= 5 else { return [] }
            return [s.points[0], s.points[2], s.points[3]]
        case .ellipse:
            guard s.points.count >= 131 else { return [] }
            let c = s.points[128], a = s.points[129]
            // the border handle sits on the outer ring, beyond radius a
            let k = 1 + s.border
            let outer = CGPoint(x: c.x + (a.x - c.x) * k, y: c.y + (a.y - c.y) * k)
            return [c, a, s.points[130], outer]
        case .subject, .brush:
            return []
        }
    }

    private func drag(handle i: Int, to p: CGPoint, from p0: CGPoint) {
        guard let base = start ?? model.localShape else { return }
        if start == nil { start = base }
        var s = base
        switch base.kind {
        case .gradient:
            guard base.points.count >= 5 else { return }
            let a = base.points[0], side = base.points[2]
            let diag = hypot(model.imageSize.width, model.imageSize.height)
            switch i {
            case 0:     // move the line
                let dx = p.x - p0.x, dy = p.y - p0.y
                s.points = base.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
                model.moveShape(.gradient(anchor: s.points[0], toward: s.points[2], compression: nil))
            case 1:     // turn it: the arrow follows the pointer
                let r = hypot(side.x - a.x, side.y - a.y)
                let ang = atan2(p.y - a.y, p.x - a.x)
                let turn = ang - atan2(side.y - a.y, side.x - a.x)
                s.points = base.points.map { q in
                    let x = q.x - a.x, y = q.y - a.y
                    return CGPoint(x: a.x + x * cos(turn) - y * sin(turn), y: a.y + x * sin(turn) + y * cos(turn))
                }
                s.points[2] = CGPoint(x: a.x + r * cos(ang), y: a.y + r * sin(ang))
                model.moveShape(.gradient(anchor: a, toward: p, compression: nil))
            default:    // the transition's width
                let ux = side.x - a.x, uy = side.y - a.y
                let ul = max(hypot(ux, uy), 1)
                let dist = abs((p.x - a.x) * ux / ul + (p.y - a.y) * uy / ul)
                let compression = min(max(dist / diag, 0.005), 1)
                let scale = compression / max(base.compression, 0.001)
                s.compression = compression
                s.points[3] = CGPoint(x: a.x + (base.points[3].x - a.x) * scale, y: a.y + (base.points[3].y - a.y) * scale)
                s.points[4] = CGPoint(x: a.x + (base.points[4].x - a.x) * scale, y: a.y + (base.points[4].y - a.y) * scale)
                model.moveShape(.gradient(anchor: a, toward: side, compression: compression))
            }
        case .ellipse:
            guard base.points.count >= 131 else { return }
            let c = base.points[128], a = base.points[129], b = base.points[130]
            switch i {
            case 0:
                let dx = p.x - p0.x, dy = p.y - p0.y
                s.points = base.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
                model.moveShape(.ellipse(center: s.points[128], a: s.points[129], b: s.points[130], border: nil))
            case 1, 2:
                // a radius: its end follows the pointer, the other keeps its length at right angles
                let moved = p
                let other = i == 1 ? b : a
                let otherLen = hypot(other.x - c.x, other.y - c.y)
                let ang = atan2(moved.y - c.y, moved.x - c.x) + (i == 1 ? .pi / 2 : -.pi / 2)
                let perp = CGPoint(x: c.x + otherLen * cos(ang), y: c.y + otherLen * sin(ang))
                let na = i == 1 ? moved : perp, nb = i == 1 ? perp : moved
                s.points = ellipsePoints(c: c, a: na, b: nb, border: base.border)
                model.moveShape(.ellipse(center: c, a: na, b: nb, border: nil))
            default:
                let ra = max(hypot(a.x - c.x, a.y - c.y), 1)
                let border = min(max(hypot(p.x - c.x, p.y - c.y) / ra - 1, 0.01), 4)
                s.border = border
                s.points = ellipsePoints(c: c, a: a, b: b, border: border)
                model.moveShape(.ellipse(center: c, a: a, b: b, border: border))
            }
        case .subject, .brush:
            return
        }
        live = s
    }

    /// an ellipse's outline points in the order the engine sends them
    private func ellipsePoints(c: CGPoint, a: CGPoint, b: CGPoint, border: Double) -> [CGPoint] {
        let ra = hypot(a.x - c.x, a.y - c.y), rb = hypot(b.x - c.x, b.y - c.y)
        let rot = atan2(a.y - c.y, a.x - c.x)
        var out: [CGPoint] = []
        for ring in 0..<2 {
            let k = ring == 0 ? 1 : 1 + border
            for i in 0..<64 {
                let t = 2 * Double.pi * Double(i) / 64
                let x = ra * k * cos(t), y = rb * k * sin(t)
                out.append(CGPoint(x: c.x + x * cos(rot) - y * sin(rot), y: c.y + x * sin(rot) + y * cos(rot)))
            }
        }
        return out + [c, a, b]
    }
}


/// Painting a brushed local adjustment: its strokes tinted on the photo (as
/// Aperture's brush overlay showed them), the stroke being drawn, and the
/// brush under the pointer. Option-drag erases. A pen's pressure (a tablet's,
/// or Apple Pencil's over Sidecar) sets each point's size or opacity.
struct BrushOverlay: View {
    @Environment(EditorModel.self) private var model
    let toView: (CGPoint) -> CGPoint
    let toImage: (CGPoint) -> CGPoint

    @State private var stroke: [CGPoint] = []
    /// the pen's pressure at each point of the stroke, if a pen is drawing it
    @State private var pressures: [Double]?
    @State private var erasing = false
    @State private var hover: CGPoint?
    /// the stroke just painted, shown until darktable's render of it arrives
    @State private var landing: MaskStroke?

    private var radius: Double { model.brushSize * min(model.imageSize.width, model.imageSize.height) }

    /// a stroke as the mask draws it, in this view's points
    struct MaskStroke {
        var points: [CGPoint]
        var width: Double
        var sizes: [Double]? = nil
        var opacities: [Double]? = nil
        var erase = false
    }

    private var liveStroke: MaskStroke? {
        guard !stroke.isEmpty else { return landing }
        let pen = model.penPressure == .off ? nil : pressures
        return MaskStroke(points: stroke, width: 2 * viewRadius(radius, at: toImage(stroke[0])),
                          sizes: model.penPressure == .size ? pen?.map { max($0, 0.1) } : nil,
                          opacities: model.penPressure == .opacity ? pen?.map { max($0, 0.05) } : nil, erase: erasing)
    }

    private var savedStrokes: [MaskStroke] {
        (model.localShape?.strokes ?? []).map {
            MaskStroke(points: $0.points.map(toView), width: 2 * viewRadius($0.radius, at: $0.points[0]),
                       sizes: $0.sizes, opacities: $0.opacities, erase: $0.erase)
        }
    }

    var body: some View {
        let live = liveStroke
        ZStack {
            if !model.showBrushMask, let live {
                if let p = model.brushPreview {
                    // the adjustment's look, through the stroke
                    let a = toView(p.origin), b = toView(CGPoint(x: p.origin.x + p.size.width, y: p.origin.y + p.size.height))
                    Image(decorative: p.image, scale: 1)
                        .resizable()
                        .allowedDynamicRange(.high)
                        .frame(width: b.x - a.x, height: b.y - a.y)
                        .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                        .mask { mask([live]) }
                } else {
                    // a brush with nothing set yet: a faint trace
                    Color.white.opacity(0.25).mask { mask([live]) }
                }
            }
            if model.showBrushMask {
                Color.red.opacity(0.4).mask { mask(savedStrokes + (live.map { [$0] } ?? [])) }
            }
            Canvas { ctx, _ in
                guard stroke.isEmpty, let h = hover else { return }
                let r = viewRadius(radius, at: toImage(h))
                let inner = r * (1 - model.brushSoftness)
                ctx.stroke(Path(ellipseIn: CGRect(x: h.x - r, y: h.y - r, width: 2 * r, height: 2 * r)), with: .color(.white.opacity(0.8)), lineWidth: 1)
                if inner > 2 {
                    ctx.stroke(Path(ellipseIn: CGRect(x: h.x - inner, y: h.y - inner, width: 2 * inner, height: 2 * inner)),
                               with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .contentShape(Rectangle())
        .onAppear { PenInput.shared.start() }
        .onDisappear { PenInput.shared.stop() }
        .onContinuousHover { phase in
            if case .active(let p) = phase { hover = p } else { hover = nil }
        }
        // darktable's render of the stroke has arrived
        .onChange(of: model.frameID) { _, _ in
            guard stroke.isEmpty, landing != nil else { return }
            landing = nil
            model.endBrushPreview()
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                let pen = PenInput.shared
                if stroke.isEmpty {
                    stroke = [g.startLocation]
                    pressures = pen.pressure.map { [$0] }
                    erasing = model.brushErases || NSEvent.modifierFlags.contains(.option) || pen.eraser
                    landing = nil
                    model.startBrushPreview(erase: erasing)
                }
                if let last = stroke.last, hypot(g.location.x - last.x, g.location.y - last.y) > 3 {
                    stroke.append(g.location)
                    // smoothed a little, as a pen's readings jitter
                    if let p = pen.pressure, let before = pressures?.last { pressures?.append(0.6 * p + 0.4 * before) }
                }
            }
            .onEnded { _ in
                let points = stroke.map(toImage)
                let pen = pressures?.count == points.count ? pressures : nil
                landing = liveStroke
                stroke = []
                pressures = nil
                model.paintStroke(points, erase: erasing, pressure: pen)
            })
    }

    /// The strokes as one soft mask (white where painted), so a pen's pieces
    /// and overlapping strokes don't pile up: each piece is drawn lightening,
    /// keeping the stronger where they meet, and erasing ones in black.
    private func mask(_ strokes: [MaskStroke]) -> some View {
        let soft = model.brushSoftness
        return Canvas { ctx, _ in
            let blur = (strokes.first?.width ?? 0) / 2 * soft * 0.5
            if blur > 0.5 { ctx.addFilter(.blur(radius: blur)) }
            for s in strokes where !s.points.isEmpty {
                var c = ctx
                c.blendMode = s.erase ? .normal : .lighten
                let w = s.width * (1 - soft * 0.5)
                let style = { (w: Double) in StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round) }
                guard s.points.count > 1, s.sizes?.count == s.points.count || s.opacities?.count == s.points.count else {
                    c.stroke(path(s.points), with: .color(s.erase ? .black : .white), style: style(w))
                    continue
                }
                for i in 1..<s.points.count {
                    let size = s.sizes.map { ($0[i - 1] + $0[i]) / 2 } ?? 1
                    let alpha = s.opacities.map { ($0[i - 1] + $0[i]) / 2 } ?? 1
                    c.stroke(path([s.points[i - 1], s.points[i]]), with: .color(s.erase ? .black : Color(white: alpha)),
                             style: style(w * size))
                }
            }
        }
        .luminanceToAlpha()
        .allowsHitTesting(false)
    }

    private func path(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(pts)
        if pts.count == 1 { p.addLine(to: pts[0]) }
        return p
    }

    private func viewRadius(_ r: Double, at p: CGPoint) -> Double {
        let a = toView(p), b = toView(CGPoint(x: p.x + r, y: p.y))
        return hypot(b.x - a.x, b.y - a.y)
    }
}
