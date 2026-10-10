import SwiftUI

/// The local adjustments card: linear and radial gradients, each its own
/// masked exposure instance. Selecting one shows its shape on the photo.
struct LocalAdjustmentsCard: View {
    @Environment(EditorModel.self) private var model
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardTitle(title: "Local adjustments", isExpanded: $expanded)
                Menu {
                    Button("Linear Gradient", systemImage: "square.tophalf.filled") { model.addLocal(.gradient) }
                    Button("Radial Gradient", systemImage: "circle.dashed") { model.addLocal(.ellipse) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a linear or radial gradient that brightens or darkens part of the photo")
            }
            if expanded {
                if model.localAdjustments.isEmpty {
                    Text("Brighten or darken part of the photo with a linear or radial gradient.")
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
                        Text(m.instanceName)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(selected ? "Hide its shape" : "Show and edit its shape on the photo")
                Toggle("", isOn: Binding(get: { m.enabled }, set: { model.setEnabled($0, module: m.key) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            if selected, let ev = m.fields.first(where: { $0.name == "exposure" }) {
                ParamSlider(label: "Exposure", value: ev.value.number, defaultValue: 0, range: -3...3,
                            isInteger: false, unit: "EV", trackColors: nil) {
                    model.setValue(.number(($0 * 100).rounded() / 100), module: m.key, field: "exposure")
                }
                HStack {
                    Spacer()
                    Button("Delete", role: .destructive) { model.deleteLocal(m.key) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Text(model.localShape?.kind == .ellipse
                     ? "Drag the centre to move it, the side handles to size it, the outer handle for a softer edge."
                     : "Drag the centre to move it, the arrow to turn it, the dashed line for a softer edge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
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
