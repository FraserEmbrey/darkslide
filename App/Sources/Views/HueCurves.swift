import SwiftUI

/// darktable's colour equaliser curve (iop/colorequal.c, _periodic_RBF_interpolate),
/// ported so the line drawn is the curve applied: eight nodes around the hue
/// circle, joined by a periodic radial-basis interpolation.
enum HueCurveMath {
    static let nodes = 8
    /// sRGB red sits at 20° in darktable's UCS, so the interface puts red at 0°
    private static let angleShift = 20.0

    private static func nodeAngle(_ k: Int, shift: Double) -> Double {
        (Double(k) * 360 / Double(nodes) + shift + angleShift) * .pi / 180
    }

    private static func coefficient(_ l: Double, _ c: Double) -> Double { exp(-l * l / c) }

    /// weights for the node values, solved once per edit
    static func weights(_ values: [Double], smoothing: Double, shift: Double) -> [Double] {
        let m = Int(ceil(3 * smoothing.squareRoot()))
        var a = [[Double]](repeating: [Double](repeating: 0, count: nodes), count: nodes)
        for i in 0..<nodes {
            for j in 0..<nodes {
                var sum = 0.0
                for l in 0..<m {
                    sum += coefficient(Double(l), smoothing) * cos(Double(l) * abs(nodeAngle(i, shift: shift) - nodeAngle(j, shift: shift)))
                }
                a[i][j] = exp(sum)
            }
        }
        return solve(a, values)
    }

    /// the curve at a conventional hue in degrees (red 0, yellow 90, cyan 180)
    static func evaluate(weights: [Double], smoothing: Double, shift: Double, atHue degrees: Double, clip: Bool) -> Double {
        let m = Int(ceil(3 * smoothing.squareRoot()))
        let hue = (degrees + angleShift) * .pi / 180
        var out = 0.0
        for k in 0..<nodes {
            var sum = 0.0
            for l in 0..<m {
                sum += coefficient(Double(l), smoothing) * cos(Double(l) * abs(hue - nodeAngle(k, shift: shift)))
            }
            out += weights[k] * exp(sum)
        }
        return clip ? max(out, 0) : out
    }

    /// Gaussian elimination with partial pivoting; the 8 × 8 system is well conditioned
    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double] {
        var a = a, b = b
        let n = b.count
        for col in 0..<n {
            let pivot = (col..<n).max { abs(a[$0][col]) < abs(a[$1][col]) }!
            a.swapAt(col, pivot); b.swapAt(col, pivot)
            guard abs(a[col][col]) > 1e-12 else { continue }
            for row in (col + 1)..<n {
                let f = a[row][col] / a[col][col]
                for k in col..<n { a[row][k] -= f * a[col][k] }
                b[row] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row][k] * x[k] }
            x[row] = abs(a[row][row]) > 1e-12 ? sum / a[row][row] : 0
        }
        return x
    }
}

/// The colour equaliser as Photomator-style hue curves: hue, saturation and
/// luminance, each against hue, with a handle on each of darktable's eight
/// colours. Drag a handle up or down; double-click it to reset.
struct HueCurveControls: View {
    @Environment(EditorModel.self) private var model
    let module: EngineModule
    @State private var tab = 0          // 0 hue, 1 saturation, 2 luminance
    @State private var showAdvanced = false

    static let colours = ["red", "orange", "yellow", "green", "cyan", "blue", "lavender", "magenta"]
    private static let prefixes = ["hue", "sat", "bright"]
    /// the curve's own fields; the rest go under Advanced
    static let curveFields = Set(prefixes.flatMap { p in colours.map { "\(p)_\($0)" } })

    private func value(_ field: String) -> Double {
        module.fields.first { $0.name == field }?.value.number ?? 0
    }

    var body: some View {
        let prefix = Self.prefixes[tab]
        let values = Self.colours.map { value("\(prefix)_\($0)") }
        VStack(alignment: .leading, spacing: 12) {
            WideSegments(options: ["Hue", "Saturation", "Luminance"], selection: $tab)
            HueCurveEditor(
                kind: tab == 0 ? .hue : .factor,
                values: values,
                smoothing: tab == 0 ? .pi / max(value("smoothing_hue"), 0.05) : .pi,
                shift: value("hue_shift")
            ) { i, v in
                model.setValue(.number(v), module: module.key, field: "\(prefix)_\(Self.colours[i])")
            }
            Text(["Turns each colour towards its neighbours.",
                  "Makes each colour more or less saturated.",
                  "Makes each colour lighter or darker."][tab])
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(module.fields.filter { !Self.curveFields.contains($0.name) && Presentation.isVisible($0, in: module) }) { f in
                        FieldControl(op: module.op, field: f) { model.setValue($0, module: module.key, field: f.name) }
                    }
                }
                .padding(.top, 8)
            }
        }
    }
}

struct HueCurveEditor: View {
    enum Kind { case hue, factor }
    let kind: Kind
    let values: [Double]
    let smoothing: Double
    let shift: Double
    let onChange: (Int, Double) -> Void

    @State private var live: [Double]?
    @State private var dragging: Int?

    /// the vertical range shown: ±90° of hue, or 0 to 2× for the factors
    private var range: ClosedRange<Double> { kind == .hue ? -90...90 : 0...2 }
    private var neutral: Double { kind == .hue ? 0 : 1 }

    private func nodeHue(_ k: Int) -> Double { Double(k) * 45 + shift }

    /// darktable's eight colours; its hue circle (UCS) isn't HSV's, so the
    /// handles and the band use the named colours rather than HSV hues
    static let swatches: [Color] = [
        Color(.sRGB, red: 0.90, green: 0.22, blue: 0.24), Color(.sRGB, red: 0.95, green: 0.55, blue: 0.18),
        Color(.sRGB, red: 0.93, green: 0.85, blue: 0.22), Color(.sRGB, red: 0.30, green: 0.75, blue: 0.30),
        Color(.sRGB, red: 0.22, green: 0.78, blue: 0.82), Color(.sRGB, red: 0.25, green: 0.42, blue: 0.92),
        Color(.sRGB, red: 0.62, green: 0.45, blue: 0.90), Color(.sRGB, red: 0.88, green: 0.30, blue: 0.70),
    ]

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 10
            let band: CGFloat = 8
            let plot = CGRect(x: inset, y: inset, width: geo.size.width - 2 * inset, height: geo.size.height - 2 * inset - band - 6)
            let values = live ?? self.values
            let toY = { (v: Double) in plot.maxY - CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)) * plot.height }
            let toX = { (hue: Double) in plot.minX + CGFloat((hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360) * plot.width }
            ZStack {
                Canvas { ctx, size in
                    // the hue band under the plot
                    let bandRect = CGRect(x: plot.minX, y: plot.maxY + 6, width: plot.width, height: band)
                    ctx.fill(Path(roundedRect: bandRect, cornerRadius: 3), with: .linearGradient(
                        Gradient(colors: Self.swatches + [Self.swatches[0]]),
                        startPoint: CGPoint(x: plot.minX, y: 0), endPoint: CGPoint(x: plot.maxX, y: 0)))
                    // node guides and the neutral line
                    for k in 0..<HueCurveMath.nodes {
                        let x = toX(nodeHue(k))
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.minY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY)) },
                                   with: .color(.primary.opacity(0.12)), lineWidth: 1)
                    }
                    ctx.stroke(Path { $0.move(to: CGPoint(x: plot.minX, y: toY(neutral))); $0.addLine(to: CGPoint(x: plot.maxX, y: toY(neutral))) },
                               with: .color(.primary.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    // the curve, as darktable interpolates it
                    let radians = kind == .hue ? values.map { $0 * .pi / 180 } : values
                    let w = HueCurveMath.weights(radians, smoothing: smoothing, shift: shift)
                    var curve = Path()
                    for i in 0...180 {
                        let hue = Double(i) * 2
                        var v = HueCurveMath.evaluate(weights: w, smoothing: smoothing, shift: shift, atHue: hue, clip: kind == .factor)
                        if kind == .hue { v = v * 180 / .pi }
                        let p = CGPoint(x: plot.minX + plot.width * CGFloat(i) / 180, y: toY(v))
                        if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
                    }
                    ctx.stroke(curve, with: .color(.primary.opacity(0.9)), lineWidth: 1.5)
                }
                ForEach(0..<HueCurveMath.nodes, id: \.self) { k in
                    let moved = abs(values[k] - neutral) > 1e-3
                    Circle()
                        .fill(Self.swatches[k])
                        .overlay(Circle().strokeBorder(dragging == k ? Color.accentColor : .primary, lineWidth: moved ? 2 : 1))
                        .frame(width: 14, height: 14)
                        .position(x: toX(nodeHue(k)), y: toY(values[k]))
                        .allowsHitTesting(false)
                }
                if let k = dragging {
                    Text(readout(k, values[k]))
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                        .position(x: min(max(toX(nodeHue(k)), plot.minX + 40), plot.maxX - 40), y: plot.minY + 8)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragging == nil {
                        // the nearest handle across, so a drag anywhere in its column works
                        dragging = (0..<HueCurveMath.nodes).min { abs(toX(nodeHue($0)) - g.startLocation.x) < abs(toX(nodeHue($1)) - g.startLocation.x) }
                        live = self.values
                    }
                    guard let k = dragging, var current = live else { return }
                    let t = Double((plot.maxY - g.location.y) / plot.height)
                    var v = range.lowerBound + min(max(t, 0), 1) * (range.upperBound - range.lowerBound)
                    // a little snap to neutral
                    if abs(v - neutral) < (range.upperBound - range.lowerBound) * 0.015 { v = neutral }
                    current[k] = kind == .hue ? v.rounded() : (v * 100).rounded() / 100
                    live = current
                    onChange(k, current[k])
                }
                .onEnded { _ in live = nil; dragging = nil })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { e in
                let k = (0..<HueCurveMath.nodes).min { abs(toX(nodeHue($0)) - e.location.x) < abs(toX(nodeHue($1)) - e.location.x) }!
                onChange(k, neutral)
            })
        }
        .frame(height: 190)
        .help("Drag a colour's handle up or down; double-click it to reset.")
    }

    private func readout(_ k: Int, _ v: Double) -> String {
        let name = HueCurveControls.colours[k].capitalized
        switch kind {
        case .hue: return "\(name) \(v >= 0 ? "+" : "−")\(Int(abs(v)))°"
        case .factor: return "\(name) \(Int((v * 100).rounded()))%"
        }
    }
}
