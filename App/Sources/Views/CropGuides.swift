import SwiftUI

/// Composition guides drawn in the crop box. Each is worked out for a
/// landscape box and turned for a portrait one; the golden spiral can also be
/// flipped to any corner.
enum CropGuide: String, CaseIterable, Identifiable {
    case none, thirds, phiGrid, spiral, diagonals, rebatement, grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .thirds: "Rule of thirds"
        case .phiGrid: "Golden ratio"
        case .spiral: "Golden spiral"
        case .diagonals: "Diagonals"
        case .rebatement: "Rebatement"
        case .grid: "Grid"
        }
    }

    var help: String {
        switch self {
        case .none: "No guide"
        case .thirds: "Lines a third of the way in. Place the subject or horizon on one."
        case .phiGrid: "Lines at the golden ratio, 0.382 and 0.618 of the way in: a little closer to the centre than thirds."
        case .spiral: "The golden spiral, winding in to the strongest point. Flip it to put that point where the subject is."
        case .diagonals: "Both diagonals, and the lines from each corner that meet them at right angles (dynamic symmetry). Lines and edges in the photo can follow them."
        case .rebatement: "The square on each short side swung into the frame. Its edges are calm places for a subject, and the diagonals cross them at strong points."
        case .grid: "An even grid, for levelling and checking straight lines."
        }
    }

    /// whether flipping changes it
    var flips: Bool { self == .spiral }

    /// The guide's lines in `box`. `orientation` 0 to 3 flips it across and down.
    func path(in box: CGRect, orientation: Int) -> Path {
        guard box.width > 1, box.height > 1 else { return Path() }
        let portrait = box.height > box.width
        // the landscape shape to work in
        let w = portrait ? box.height : box.width, h = portrait ? box.width : box.height
        var p = Path()
        func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
            p.move(to: CGPoint(x: x0, y: y0)); p.addLine(to: CGPoint(x: x1, y: y1))
        }
        switch self {
        case .none: return Path()
        case .thirds, .phiGrid:
            let a: CGFloat = self == .thirds ? 1 / 3 : 0.381966
            for f in [a, 1 - a] {
                line(w * f, 0, w * f, h)
                line(0, h * f, w, h * f)
            }
        case .grid:
            // square cells, about eight down the short side
            let step = h / 8
            var x = step
            while x < w - 0.5 { line(x, 0, x, h); x += step }
            var y = step
            while y < h - 0.5 { line(0, y, w, y); y += step }
        case .diagonals:
            line(0, 0, w, h)
            line(0, h, w, 0)
            // reciprocals: from each corner, at right angles to the diagonal it doesn't sit on
            let r = h * h / w
            line(0, 0, r, h); line(w, 0, w - r, h)
            line(0, h, r, 0); line(w, h, w - r, 0)
        case .rebatement:
            if w - h > 0.5 {
                line(h, 0, h, h)
                line(w - h, 0, w - h, h)
            }
            line(0, 0, w, h)
            line(0, h, w, 0)
            // each square's own diagonal
            line(0, 0, h, h); line(w, 0, w - h, h)
            line(0, h, h, 0); line(w, h, w - h, 0)
        case .spiral:
            p = Self.spiral(w: w, h: h)
        }
        // flip, turn for a portrait box, then move onto it
        var t = CGAffineTransform.identity
        if orientation & 1 == 1 { t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)) }
        if orientation & 2 == 2 { t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)) }
        if portrait { t = t.concatenating(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)) }
        t = t.concatenating(CGAffineTransform(translationX: box.minX, y: box.minY))
        return p.applying(t)
    }

    /// A golden rectangle cut into squares, a quarter circle in each, then
    /// stretched to w × h: the squares go left, top, right, bottom, round and
    /// round, winding in towards the lower right third.
    private static func spiral(w: CGFloat, h: CGFloat) -> Path {
        let phi: CGFloat = 1.618034
        var r = CGRect(x: 0, y: 0, width: phi, height: 1)
        var p = Path()
        var arcs = Path()
        let k: CGFloat = 0.5523   // a quarter circle as one cubic
        func arc(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) {
            if arcs.isEmpty { arcs.move(to: a) }
            arcs.addCurve(to: b,
                          control1: CGPoint(x: a.x + k * (b.x - c.x), y: a.y + k * (b.y - c.y)),
                          control2: CGPoint(x: b.x + k * (a.x - c.x), y: b.y + k * (a.y - c.y)))
        }
        for i in 0..<12 {
            switch i % 4 {
            case 0:   // square on the left
                let s = r.height
                arc(CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX + s, y: r.minY), CGPoint(x: r.minX + s, y: r.maxY))
                p.move(to: CGPoint(x: r.minX + s, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY))
                r = CGRect(x: r.minX + s, y: r.minY, width: r.width - s, height: r.height)
            case 1:   // on top
                let s = r.width
                arc(CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY + s), CGPoint(x: r.minX, y: r.minY + s))
                p.move(to: CGPoint(x: r.minX, y: r.minY + s)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + s))
                r = CGRect(x: r.minX, y: r.minY + s, width: r.width, height: r.height - s)
            case 2:   // on the right
                let s = r.height
                arc(CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX - s, y: r.maxY), CGPoint(x: r.maxX - s, y: r.minY))
                p.move(to: CGPoint(x: r.maxX - s, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY))
                r = CGRect(x: r.minX, y: r.minY, width: r.width - s, height: r.height)
            default:  // at the bottom
                let s = r.width
                arc(CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY - s), CGPoint(x: r.maxX, y: r.maxY - s))
                p.move(to: CGPoint(x: r.minX, y: r.maxY - s)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - s))
                r = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - s)
            }
        }
        p.addPath(arcs)
        return p.applying(CGAffineTransform(scaleX: w / phi, y: h))
    }
}

/// The crop guide settings, kept between photos and launches.
enum CropGuideSettings {
    static let guideKey = "CropGuide"
    static let orientationKey = "CropGuideOrientation"
    static let alwaysKey = "CropGuideAlways"
}

/// The crop panel's guide chooser.
struct CropGuidePicker: View {
    @AppStorage(CropGuideSettings.guideKey) private var guide = CropGuide.thirds
    @AppStorage(CropGuideSettings.orientationKey) private var orientation = 0
    @AppStorage(CropGuideSettings.alwaysKey) private var always = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Guide", selection: $guide) {
                    ForEach(CropGuide.allCases) { g in
                        Text(g.title).tag(g)
                        if g == .none { Divider() }
                    }
                }
                .labelsHidden()
                .help(guide.help)
                Button("Flip", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") { orientation = (orientation + 1) % 4 }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!guide.flips)
                    .help("Flip the spiral to the next corner (O)")
                    .keyboardShortcut("o", modifiers: [])
            }
            Toggle("Only while dragging", isOn: Binding(get: { !always }, set: { always = !$0 }))
                .disabled(guide == .none)
        }
    }
}
