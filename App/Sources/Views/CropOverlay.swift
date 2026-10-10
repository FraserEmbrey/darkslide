import SwiftUI

/// The crop box over the straightened photo: drag a corner or edge to resize,
/// inside to move. Holds the chosen ratio, and stays inside the photo.
struct CropOverlay: View {
    @Environment(EditorModel.self) private var model
    /// pixel size of the frame being shown, to place the photo in the view
    let frameSize: CGSize

    private enum Grab { case move, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight }
    @State private var grab: Grab?
    @State private var startRect: CGRect = .zero

    private static let minSize = 0.04
    private static let handleReach: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let photo = EDRImageView.fittedRect(frameSize, in: geo.size)
            let box = CGRect(x: photo.minX + model.cropRect.minX * photo.width,
                             y: photo.minY + model.cropRect.minY * photo.height,
                             width: model.cropRect.width * photo.width,
                             height: model.cropRect.height * photo.height)
            ZStack {
                // dim everything outside the box
                Path { p in
                    p.addRect(photo)
                    p.addRect(box)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

                // thirds while adjusting, as a composition guide
                if grab != nil {
                    Path { p in
                        for i in 1...2 {
                            let x = box.minX + box.width * CGFloat(i) / 3
                            let y = box.minY + box.height * CGFloat(i) / 3
                            p.move(to: CGPoint(x: x, y: box.minY)); p.addLine(to: CGPoint(x: x, y: box.maxY))
                            p.move(to: CGPoint(x: box.minX, y: y)); p.addLine(to: CGPoint(x: box.maxX, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
                }

                Rectangle()
                    .path(in: box)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)

                // corner handles
                Path { p in
                    let l: CGFloat = 18
                    for (c, dx, dy) in [(CGPoint(x: box.minX, y: box.minY), 1.0, 1.0), (CGPoint(x: box.maxX, y: box.minY), -1.0, 1.0),
                                        (CGPoint(x: box.minX, y: box.maxY), 1.0, -1.0), (CGPoint(x: box.maxX, y: box.maxY), -1.0, -1.0)] {
                        p.move(to: CGPoint(x: c.x + l * dx, y: c.y)); p.addLine(to: c); p.addLine(to: CGPoint(x: c.x, y: c.y + l * dy))
                    }
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .square))
                .shadow(color: .black.opacity(0.4), radius: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if grab == nil {
                            grab = region(at: v.startLocation, box: box)
                            startRect = model.cropRect
                        }
                        drag(by: CGSize(width: v.translation.width / max(photo.width, 1),
                                        height: v.translation.height / max(photo.height, 1)))
                    }
                    .onEnded { _ in grab = nil }
            )
            .onContinuousHover { phase in
                if case .active(let p) = phase { cursor(for: region(at: p, box: box)).set() }
            }
        }
    }

    private func region(at p: CGPoint, box: CGRect) -> Grab {
        let r = Self.handleReach
        let nearL = abs(p.x - box.minX) < r, nearR = abs(p.x - box.maxX) < r
        let nearT = abs(p.y - box.minY) < r, nearB = abs(p.y - box.maxY) < r
        let inX = p.x > box.minX - r && p.x < box.maxX + r, inY = p.y > box.minY - r && p.y < box.maxY + r
        switch (nearL, nearR, nearT, nearB) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _) where inY: return .left
        case (_, true, _, _) where inY: return .right
        case (_, _, true, _) where inX: return .top
        case (_, _, _, true) where inX: return .bottom
        default: return .move
        }
    }

    private func cursor(for g: Grab) -> NSCursor {
        switch g {
        case .move: .openHand
        case .left, .right: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        default: .crosshair
        }
    }

    /// d is the drag in 0...1 photo units
    private func drag(by d: CGSize) {
        guard let grab else { return }
        let s = startRect
        var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
        switch grab {
        case .move:
            let dx = (Double(d.width)).clamped(to: -s.minX...(1 - s.maxX))
            let dy = (Double(d.height)).clamped(to: -s.minY...(1 - s.maxY))
            model.cropRect = s.offsetBy(dx: dx, dy: dy)
            return
        case .left: minX += d.width
        case .right: maxX += d.width
        case .top: minY += d.height
        case .bottom: maxY += d.height
        case .topLeft: minX += d.width; minY += d.height
        case .topRight: maxX += d.width; minY += d.height
        case .bottomLeft: minX += d.width; maxY += d.height
        case .bottomRight: maxX += d.width; maxY += d.height
        }
        // keep inside the photo and above a minimum size
        minX = minX.clamped(to: 0...(maxX - Self.minSize)); maxX = maxX.clamped(to: (minX + Self.minSize)...1)
        minY = minY.clamped(to: 0...(maxY - Self.minSize)); maxY = maxY.clamped(to: (minY + Self.minSize)...1)
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if let ratio = model.cropNormalisedRatio { r = constrain(r, ratio: ratio, grab: grab) }
        model.cropRect = r
    }

    /// Holds the ratio: the dragged side leads, the other follows, anchored on
    /// the opposite side or corner, shrinking if it would leave the photo.
    private func constrain(_ r: CGRect, ratio: Double, grab: Grab) -> CGRect {
        var w = r.width, h = r.height
        switch grab {
        case .top, .bottom: w = h * ratio
        case .left, .right: h = w / ratio
        default: if w / h > ratio { h = w / ratio } else { w = h * ratio }
        }
        // anchor: the fixed edges of the drag
        let ax: Double, ay: Double   // anchor point, and which way the box grows from it (+1 or -1, 0 centred)
        let gx: Double, gy: Double
        switch grab {
        case .topLeft: (ax, ay, gx, gy) = (r.maxX, r.maxY, -1, -1)
        case .topRight: (ax, ay, gx, gy) = (r.minX, r.maxY, 1, -1)
        case .bottomLeft: (ax, ay, gx, gy) = (r.maxX, r.minY, -1, 1)
        case .bottomRight: (ax, ay, gx, gy) = (r.minX, r.minY, 1, 1)
        case .left: (ax, ay, gx, gy) = (r.maxX, r.midY, -1, 0)
        case .right: (ax, ay, gx, gy) = (r.minX, r.midY, 1, 0)
        case .top: (ax, ay, gx, gy) = (r.midX, r.maxY, 0, -1)
        case .bottom: (ax, ay, gx, gy) = (r.midX, r.minY, 0, 1)
        case .move: return r
        }
        // largest scale that stays inside 0...1 from the anchor
        func room(_ a: Double, _ g: Double) -> Double { g > 0 ? 1 - a : g < 0 ? a : 2 * min(a, 1 - a) }
        let k = min(1, room(ax, gx) / w, room(ay, gy) / h)
        w *= k; h *= k
        let x = gx > 0 ? ax : gx < 0 ? ax - w : ax - w / 2
        let y = gy > 0 ? ay : gy < 0 ? ay - h : ay - h / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// The inspector while cropping: ratio, straighten and the buttons to finish.
struct CropPanel: View {
    @Environment(EditorModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            Text("Crop and Straighten")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Aspect")
                    Spacer()
                    Picker("Aspect", selection: $model.cropAspect) {
                        ForEach(CropAspect.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if model.cropAspect != .free && model.cropAspect != .original && model.cropAspect != .square {
                        Button {
                            model.cropPortrait.toggle()
                        } label: {
                            Image(systemName: model.cropPortrait ? "rectangle.portrait" : "rectangle")
                        }
                        .buttonStyle(.borderless)
                        .help(model.cropPortrait ? "Portrait: click for landscape" : "Landscape: click for portrait")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ParamSlider(label: "Straighten", value: model.straighten, defaultValue: 0, range: -45...45,
                            isInteger: false, unit: "°", trackColors: nil) { model.setStraighten(($0 * 100).rounded() / 100) }
                HStack {
                    Button("Auto Straighten", systemImage: "level") { Task { await model.autoStraighten() } }
                        .help("Levels the photo from its straight lines, or failing those its horizon")
                    Spacer()
                    Button("Reset") { model.resetCrop() }
                        .help("Back to the whole photo, unrotated")
                }
            }

            Text("Drag the corners or edges to crop, or inside the box to move it. Straightening crops off the corners the rotation brings in, keeping the photo's shape.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            HStack {
                // the label fills, so the buttons share the width
                Button { model.cancelCrop() } label: { Text("Cancel").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.cancelAction)
                Button { model.commitCrop() } label: { Text("Done").frame(maxWidth: .infinity) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
