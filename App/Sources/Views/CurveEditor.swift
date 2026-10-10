import SwiftUI

/// darktable's monotone Hermite curve (common/curve_tools.c), ported so the
/// line drawn is the curve applied.
enum CurveMath {
    static func evaluate(_ nodes: [CGPoint], at x: Double) -> Double {
        let n = nodes.count
        guard n >= 2 else { return x }
        let xs = nodes.map { Double($0.x) }, ys = nodes.map { Double($0.y) }
        // flat beyond the end points, as darktable's curve is
        if x <= xs[0] { return ys[0] }
        if x >= xs[n - 1] { return ys[n - 1] }
        var delta = [Double](repeating: 0, count: n), m = [Double](repeating: 0, count: n + 1)
        for i in 0..<(n - 1) { delta[i] = (ys[i + 1] - ys[i]) / max(xs[i + 1] - xs[i], 1e-9) }
        delta[n - 1] = delta[n - 2]
        m[0] = delta[0]; m[n - 1] = delta[n - 1]
        for i in 1..<(n - 1) { m[i] = (delta[i - 1] + delta[i]) * 0.5 }
        for i in 0..<n {
            if abs(delta[i]) < 1e-6 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / delta[i], b = m[i + 1] / delta[i], tau = a * a + b * b
            if tau > 9 { m[i] = 3 * a * delta[i] / tau.squareRoot(); m[i + 1] = 3 * b * delta[i] / tau.squareRoot() }
        }
        var i = n - 2
        for k in 0..<(n - 2) where x < xs[k + 1] { i = k; break }
        let h = xs[i + 1] - xs[i], t = (x - xs[i]) / h, t2 = t * t, t3 = t2 * t
        let v = (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * m[i] + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * m[i + 1]
        return min(max(v, 0), 1)
    }

    /// the curve's axis is Lab lightness (darktable's "compensate middle
    /// gray"): 0.5 is middle grey; this gives stops from middle grey
    static func stops(atScale p: Double) -> Double {
        let l = p * 100
        let y = l > 8 ? pow((l + 16) / 116, 3) : l / 903.3
        return log2(max(y, 1e-6) / 0.1842)
    }
}

/// A curve on rgb curve's middle-grey-compensated scale, as in Photomator:
/// guides at blacks, shadows, mid-tones, highlights and whites, the input's
/// histogram behind, and a handle on each guide. A handle not yet moved rides
/// on the curve; one that has been moved is a point of the curve and shows a
/// dot. Click the curve between guides to add a point; double-click a handle
/// to reset it. While dragging, the curve is drawn from the drag itself, so it
/// keeps up with the pointer whatever the render is doing.
struct CurveEditor: View {
    let nodes: [CGPoint]
    let histogram: [Int]
    let onChange: ([CGPoint]) -> Void

    /// the nodes while a drag is under way, ahead of the model
    @State private var live: [CGPoint]?
    /// the handle grabbed, and once it has moved, the node it drags
    @State private var grabbed: Handle?
    @State private var draggingNode: Int?

    private struct Handle: Equatable {
        var point: CGPoint
        var node: Int?          // nil: an unmoved guide handle riding on the curve
        var isSet: Bool
    }

    private static let guides: [(x: Double, name: String)] = [
        (0, "Blacks"), (0.25, "Shadows"), (0.5, "Midtones"), (0.75, "Highlights"), (1, "Whites"),
    ]

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 10
            let plot = CGRect(x: inset, y: inset, width: geo.size.width - 2 * inset, height: geo.size.height - 2 * inset)
            let toView = { (p: CGPoint) in CGPoint(x: plot.minX + p.x * plot.width, y: plot.maxY - p.y * plot.height) }
            let nodes = live ?? self.nodes
            ZStack {
                Canvas { ctx, _ in
                    // histogram of the curve's input; the top bin collects everything above the
                    // curve's range (bright scene values), so it isn't used for scaling
                    if histogram.count > 2 {
                        let peak = Double(histogram.dropLast().max() ?? 1).squareRoot()
                        var path = Path()
                        path.move(to: CGPoint(x: plot.minX, y: plot.maxY))
                        for (i, c) in histogram.enumerated() {
                            let x = plot.minX + plot.width * CGFloat(i) / CGFloat(histogram.count - 1)
                            let h = min(Double(c).squareRoot() / max(peak, 1), 1)
                            path.addLine(to: CGPoint(x: x, y: plot.maxY - plot.height * 0.6 * h))
                        }
                        path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                        path.closeSubpath()
                        ctx.fill(path, with: .color(.primary.opacity(0.12)))
                    }
                    // guides
                    for g in Self.guides {
                        let x = plot.minX + plot.width * g.x
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) },
                                   with: .color(.primary.opacity(0.18)), lineWidth: 1)
                    }
                    // the identity, faintly, then the curve
                    ctx.stroke(Path { $0.move(to: toView(.zero)); $0.addLine(to: toView(CGPoint(x: 1, y: 1))) },
                               with: .color(.primary.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    var curve = Path()
                    for i in 0...200 {
                        let x = Double(i) / 200
                        let p = toView(CGPoint(x: x, y: CurveMath.evaluate(nodes, at: x)))
                        if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                    }
                    ctx.stroke(curve, with: .color(.primary.opacity(0.9)), lineWidth: 1.5)
                }
                // guide labels: name and stops from middle grey
                ForEach(Array(Self.guides.enumerated()), id: \.offset) { i, g in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(label(g.x)).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        Text(g.name).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    .fixedSize()
                    .position(x: plot.minX + plot.width * g.x + (i == 4 ? -26 : 26), y: i == 4 ? plot.maxY - 18 : plot.minY + 14)
                    .allowsHitTesting(false)
                }
                // handles; a moved one has a dot
                ForEach(Array(handles(nodes).enumerated()), id: \.offset) { _, h in
                    let active = draggingNode != nil && h.node == draggingNode
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(Circle().strokeBorder(active ? Color.accentColor : .primary, lineWidth: 1.5))
                        .overlay(Circle().fill(active ? Color.accentColor : .primary).frame(width: 4, height: 4).opacity(h.isSet ? 1 : 0))
                        .frame(width: 14, height: 14)
                        .position(toView(h.point))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in drag(g, plot: plot) }
                .onEnded { g in endDrag(g, plot: plot) })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { e in reset(near: e.location, plot: plot) })
        }
        .frame(height: 210)
        .help("Drag a handle; click the curve to add one, double-click one to reset it. Middle grey is at the centre.")
    }

    private func label(_ x: Double) -> String {
        if x == 0 { return "0" }
        if x == 0.5 { return "grey" }
        let s = CurveMath.stops(atScale: x)
        return String(format: "%+.1f EV", s)
    }

    private func toCurve(_ p: CGPoint, _ plot: CGRect) -> CGPoint {
        CGPoint(x: min(max((p.x - plot.minX) / plot.width, 0), 1), y: min(max((plot.maxY - p.y) / plot.height, 0), 1))
    }

    /// a handle for each node, plus one riding on the curve for each guide
    /// with no node near it; a node belongs to its nearest guide, so a handle
    /// dragged off its guide doesn't leave another behind
    private func handles(_ nodes: [CGPoint]) -> [Handle] {
        var claimed = Set<Int>()
        var out: [Handle] = nodes.enumerated().map { i, p in
            let g = Self.guides.indices.min { abs(Self.guides[$0].x - p.x) < abs(Self.guides[$1].x - p.x) }!
            claimed.insert(g)
            // the ends count as set once moved from their corners
            let isEnd = i == 0 || i == nodes.count - 1
            let home = CGPoint(x: i == 0 ? 0 : 1, y: i == 0 ? 0 : 1)
            return Handle(point: p, node: i, isSet: !isEnd || hypot(p.x - home.x, p.y - home.y) > 1e-3)
        }
        for (g, guide) in Self.guides.enumerated() where !claimed.contains(g) {
            out.append(Handle(point: CGPoint(x: guide.x, y: CurveMath.evaluate(nodes, at: guide.x)), node: nil, isSet: false))
        }
        return out
    }

    private func nearest(_ location: CGPoint, in nodes: [CGPoint], plot: CGRect) -> Handle? {
        let toView = { (p: CGPoint) in CGPoint(x: plot.minX + p.x * plot.width, y: plot.maxY - p.y * plot.height) }
        return handles(nodes)
            .map { h -> (Handle, CGFloat) in let v = toView(h.point); return (h, hypot(v.x - location.x, v.y - location.y)) }
            .filter { $0.1 < 14 }
            .min { $0.1 < $1.1 }?.0
    }

    private func drag(_ g: DragGesture.Value, plot: CGRect) {
        if grabbed == nil, live == nil {
            live = nodes
            grabbed = nearest(g.startLocation, in: nodes, plot: plot)
        }
        guard var current = live, let h = grabbed else { return }
        // nothing changes until the pointer actually moves, so a click or a
        // double-click doesn't add a point
        guard hypot(g.location.x - g.startLocation.x, g.location.y - g.startLocation.y) > 2 || draggingNode != nil else { return }
        if draggingNode == nil {
            if let i = h.node {
                draggingNode = i
            } else {
                // an unmoved guide handle becomes a point of the curve where it sits
                let i = current.firstIndex { $0.x > h.point.x } ?? current.count
                current.insert(h.point, at: i)
                draggingNode = i
            }
        }
        guard let i = draggingNode else { return }
        var p = toCurve(g.location, plot)
        // points keep their order; the ends can move in to compress the range
        if i > 0 { p.x = max(p.x, current[i - 1].x + 0.01) }
        if i < current.count - 1 { p.x = min(p.x, current[i + 1].x - 0.01) }
        current[i] = p
        live = current
        onChange(current)
    }

    private func endDrag(_ g: DragGesture.Value, plot: CGRect) {
        defer { live = nil; grabbed = nil; draggingNode = nil }
        // a click on the curve away from the handles adds a point there
        let moved = hypot(g.location.x - g.startLocation.x, g.location.y - g.startLocation.y)
        guard grabbed == nil, moved < 3, nodes.count < 20 else { return }
        let x = Double(toCurve(g.location, plot).x)
        let onCurve = abs((plot.maxY - g.location.y) / plot.height - CurveMath.evaluate(nodes, at: x)) < 0.08
        guard onCurve, x > 0.01, x < 0.99, !nodes.contains(where: { abs($0.x - x) < 0.02 }) else { return }
        var updated = nodes
        updated.append(CGPoint(x: x, y: CurveMath.evaluate(nodes, at: x)))
        updated.sort { $0.x < $1.x }
        onChange(updated)
    }

    /// double-click: an end goes back to its corner, any other point is
    /// removed, so a guide's handle rides on the curve again
    private func reset(near location: CGPoint, plot: CGRect) {
        guard let h = nearest(location, in: nodes, plot: plot), h.isSet, let i = h.node else { return }
        var updated = nodes
        if i == 0 || i == nodes.count - 1 {
            updated[i] = i == 0 ? .zero : CGPoint(x: 1, y: 1)
        } else {
            updated.remove(at: i)
        }
        onChange(updated)
    }
}

/// The rgb curve card: the linked RGB curve, darktable's "preserve colors"
/// and a note on the scale.
struct RGBCurveControls: View {
    @Environment(EditorModel.self) private var model
    let module: EngineModule

    private var nodes: [CGPoint] {
        let raw = model.curveInfo?.nodes.first?.map { CGPoint(x: $0[0], y: $0[1]) } ?? []
        // an untouched curve is its two ends; the guide handles ride on it
        if raw.count < 2 || raw.allSatisfy({ abs($0.x - $0.y) < 1e-4 }) {
            return [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        }
        return raw
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CurveEditor(nodes: nodes, histogram: model.curveInfo?.histogram ?? []) { updated in
                model.setCurve(module: module.key, channel: 0, nodes: updated)
            }
            if let field = module.fields.first(where: { $0.name == "preserve_colors" }) {
                FieldControl(op: module.op, field: field) { model.setValue($0, module: module.key, field: field.name) }
            }
            Text("Middle grey is at the centre. Brighter than the top (+2.4 EV), the curve carries on along its last slope, so HDR highlights aren't clipped.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { model.curveEditorModule = module.key }
        .onDisappear { if model.curveEditorModule == module.key { model.curveEditorModule = nil } }
    }
}
