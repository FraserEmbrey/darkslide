import CoreImage
import SwiftUI

/// One image in the loupe: `pixel` (in the image as magnified by `zoom`) at
/// its centre. `smooth` scales it smoothly, for a stand-in at another size.
struct LoupeLayer {
    let image: CGImage
    let pixel: CGPoint
    var zoom: CGFloat = 1
    var smooth = false
}

/// Aperture's loupe, drawn as Preview's: a glossy black ring round a glass
/// lens, set in a clear glass halo. The images sit at one image pixel to a
/// screen pixel (`zoom` magnifies), bottom first, so a sharp render can cover
/// a softer stand-in. Colours fringe a little towards the rim, as through
/// glass, while the centre stays true for checking focus. HDR images keep
/// their highlights.
struct LoupeLens: View {
    @Environment(\.displayScale) private var displayScale
    let layers: [LoupeLayer]
    /// the lens, inside the ring
    var diameter: CGFloat = 220
    var label: String?

    init(layers: [LoupeLayer], diameter: CGFloat = 220, label: String? = nil) {
        self.layers = layers
        self.diameter = diameter
        self.label = label
    }

    init(image: CGImage, pixel: CGPoint, zoom: CGFloat = 1, label: String? = nil) {
        self.init(layers: [LoupeLayer(image: image, pixel: pixel, zoom: zoom)], label: label)
    }

    /// the black ring's width, and the glass halo's beyond it
    private let ring: CGFloat = 30
    private let halo: CGFloat = 26

    var body: some View {
        let outer = diameter + 2 * ring
        ZStack {
            // the clear glass the lens is set in, a little below it as in Preview's
            Color.clear
                .frame(width: outer + 2 * halo, height: outer + 2 * halo)
                .glassEffect(.clear, in: Circle())
                .offset(x: -halo * 0.35, y: halo * 0.45)
            if let lens = LensRender.render(layers, side: Int((diameter * displayScale).rounded()), scale: displayScale) {
                Image(decorative: lens, scale: displayScale)
                    .resizable()
                    .allowedDynamicRange(.high)
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
            }
            // the glass's own sheen, brightest towards the top left
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.16), .white.opacity(0.03), .clear],
                                     center: UnitPoint(x: 0.3, y: 0.22), startRadius: 0, endRadius: diameter * 0.7))
                .frame(width: diameter, height: diameter)
            Canvas { ctx, size in drawRing(in: &ctx, size: size) }
                .frame(width: outer, height: outer)
        }
        .frame(width: outer + 2 * halo, height: outer + 2 * halo)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
        .allowsHitTesting(false)
    }

    /// The ring: a black tube, shaded across its width and lit along the top
    /// left, with the zoom lettered round its lower right.
    private func drawRing(in ctx: inout GraphicsContext, size: CGSize) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r0 = diameter / 2, r1 = r0 + ring, mid = (r0 + r1) / 2
        var tube = Path(ellipseIn: CGRect(x: c.x - r1, y: c.y - r1, width: 2 * r1, height: 2 * r1))
        tube.addPath(Path(ellipseIn: CGRect(x: c.x - r0, y: c.y - r0, width: 2 * r0, height: 2 * r0)))
        let f = { (r: CGFloat) in (r - 0) / r1 }
        ctx.fill(tube, with: .radialGradient(Gradient(stops: [
            .init(color: Color(white: 0.02), location: f(r0)),
            .init(color: Color(white: 0.16), location: f(r0 + ring * 0.3)),
            .init(color: Color(white: 0.07), location: f(mid + ring * 0.12)),
            .init(color: Color(white: 0.0), location: 1),
        ]), center: c, startRadius: 0, endRadius: r1), style: FillStyle(eoFill: true))
        // light along the top of the tube
        func arc(_ from: Double, _ to: Double, radius: CGFloat) -> Path {
            Path { p in p.addArc(center: c, radius: radius, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false) }
        }
        var lit = ctx
        lit.addFilter(.blur(radius: 2.5))
        lit.stroke(arc(195, 300, radius: mid - ring * 0.08), with: .color(.white.opacity(0.55)),
                   style: StrokeStyle(lineWidth: ring * 0.16, lineCap: .round))
        lit.stroke(arc(20, 75, radius: mid + ring * 0.15), with: .color(.white.opacity(0.12)),
                   style: StrokeStyle(lineWidth: ring * 0.12, lineCap: .round))
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r1, y: c.y - r1, width: 2 * r1, height: 2 * r1)),
                   with: .color(.black.opacity(0.6)), lineWidth: 0.75)
        // the label, round the lower right, as Preview's says PREVIEW 10×
        guard let label else { return }
        let text = Array(label.uppercased())
        let glyphs = text.map { ctx.resolve(Text(String($0)).font(.system(size: 8.5, weight: .medium)).foregroundStyle(.white.opacity(0.42))) }
        let widths = glyphs.map { $0.measure(in: CGSize(width: 40, height: 40)).width + 1.2 }
        let r = mid - 1.5
        let total = widths.reduce(0, +) / r
        // centred on 45° (lower right), reading clockwise
        var angle = Double.pi / 4 + total / 2
        for (g, w) in zip(glyphs, widths) {
            angle -= w / 2 / r
            var t = ctx
            t.translateBy(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
            t.rotate(by: .radians(angle - .pi / 2))
            t.draw(g, at: .zero)
            angle -= w / 2 / r
        }
    }
}

/// The lens's picture: the layers composited at the lens's size, with the
/// slight colour fringing towards the rim that real glass gives.
@MainActor enum LensRender {
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])

    static func render(_ layers: [LoupeLayer], side: Int, scale: CGFloat) -> CGImage? {
        guard side > 0, !layers.isEmpty else { return nil }
        let s = CGFloat(side)
        let square = CGRect(x: 0, y: 0, width: s, height: s)
        var picture = CIImage(color: .black).cropped(to: square)
        for l in layers {
            var img = CIImage(cgImage: l.image)
            if !l.smooth { img = img.samplingNearest() }
            let h = CGFloat(l.image.height) * l.zoom
            // the layer's pixel (top-left origin) at the centre; Core Image's origin is bottom left
            img = img.transformed(by: CGAffineTransform(scaleX: l.zoom, y: l.zoom))
                .transformed(by: CGAffineTransform(translationX: s / 2 - l.pixel.x, y: s / 2 - (h - l.pixel.y)))
            picture = img.cropped(to: square).composited(over: picture)
        }
        // colour fringes, as real glass gives: each channel scaled a touch
        // differently about the centre, so they part towards the rim and the
        // middle stays exact. Each copy keeps one channel, opaque, and the
        // brightest of the three in each channel is taken, which puts them together
        func channel(_ k: Int, scale: CGFloat) -> CIImage {
            let t = CGAffineTransform(translationX: s / 2, y: s / 2).scaledBy(x: scale, y: scale).translatedBy(x: -s / 2, y: -s / 2)
            let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
            return picture.transformed(by: t).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": k == 0 ? CIVector(x: 1, y: 0, z: 0, w: 0) : zero,
                "inputGVector": k == 1 ? CIVector(x: 0, y: 1, z: 0, w: 0) : zero,
                "inputBVector": k == 2 ? CIVector(x: 0, y: 0, z: 1, w: 0) : zero,
                "inputAVector": zero, "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ]).cropped(to: square)
        }
        let lens = channel(0, scale: 1).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey:
            channel(1, scale: 1.006).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: channel(2, scale: 1.012)])])
        let hdr = layers.contains { $0.image.contentHeadroom > 1 }
        return context.createCGImage(lens, from: square, format: hdr ? .RGBAh : .RGBA8,
                                     colorSpace: CGColorSpace(name: hdr ? CGColorSpace.extendedLinearSRGB : CGColorSpace.sRGB)!,
                                     deferred: false, calculateHDRStats: hdr)
    }
}

/// The loupe over the editor's photo, at the pointer: the engine renders the
/// square under it at the loupe's zoom (EditorModel.pointLoupe).
struct EditorLoupe: View {
    @Environment(EditorModel.self) private var model
    let pointer: CGPoint
    let toImage: (CGPoint) -> CGPoint

    var body: some View {
        let o = toImage(pointer), zoom = model.loupeZoom
        var layers: [LoupeLayer] = []
        // the canvas's frame, magnified, under the sharp render: where that
        // doesn't reach yet (the pointer moved on), the lens is soft, not black
        if let frame = model.image {
            let m = model.frameMapping(frame, crop: model.currentCrop)
            let k = zoom / m.scale
            layers.append(LoupeLayer(image: frame, pixel: CGPoint(x: (o.x * m.scale - m.x) * k, y: (o.y * m.scale - m.y) * k),
                                     zoom: k, smooth: true))
        }
        // the render, which starts at loupeOrigin on the output, at loupeZoom
        if let img = model.loupeImage {
            layers.append(LoupeLayer(image: img, pixel: CGPoint(x: (o.x - model.loupeOrigin.x) * zoom,
                                                                y: (o.y - model.loupeOrigin.y) * zoom)))
        }
        return Group {
            if !layers.isEmpty {
                // while retouching, it sits up and to the left, so the pointer and
                // the spot under it stay in sight (while brushing it's hidden)
                let aside = model.isRemovingSpots || model.isRemovingObjects
                LoupeLens(layers: layers, label: "Darkslide  \(Int(zoom * 100))%")
                    .position(aside ? CGPoint(x: pointer.x - 190, y: pointer.y - 190) : pointer)
            }
        }
    }
}

/// The loupe over a grid thumbnail, at the point under the pointer. It shows
/// what the thumbnail does: a photo edited here (or rendered with darktable's
/// defaults) as darktable renders it at full size, with the thumbnail enlarged
/// until that's ready; any other as the camera's full-size preview (as the
/// cull view loads it). The camera's look beside a black and white edit, or
/// the other way round, was jarring.
struct GridLoupe: ViewModifier {
    @Environment(EditorModel.self) private var model
    let item: LibraryItem
    @State private var pointer: CGPoint?
    @State private var preview: CGImage?
    /// the preview is the thumbnail, enlarged, while the full-size render comes
    @State private var previewIsStandIn = false
    /// the stand-in enlarged to the photo's size, so the view holds when the render comes
    @State private var standInScale: CGFloat = 1
    @State private var rendered = false

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                guard model.showLoupe else { pointer = nil; return }
                if case .active(let p) = phase {
                    pointer = p
                    if model.loupeItem != item.url {
                        model.loupeItem = item.url
                        load()
                    }
                } else {
                    pointer = nil
                    if model.loupeItem == item.url { model.loupeItem = nil }
                }
            }
            .overlay {
                GeometryReader { geo in
                    if model.showLoupe, let p = pointer, let preview, let thumb = model.library.thumbnails[item.url] {
                        // the thumbnail as fitted in the frame, and the point on it
                        let k = min(geo.size.width / CGFloat(thumb.width), geo.size.height / CGFloat(thumb.height))
                        let w = CGFloat(thumb.width) * k, h = CGFloat(thumb.height) * k
                        let x0 = (geo.size.width - w) / 2, y0 = (geo.size.height - h) / 2
                        let u = CGPoint(x: (p.x - x0) / w, y: (p.y - y0) / h)
                        if (0...1).contains(u.x), (0...1).contains(u.y) {
                            let z = model.loupeZoom * (previewIsStandIn ? standInScale : 1)
                            LoupeLens(layers: [LoupeLayer(image: preview, pixel: CGPoint(x: u.x * CGFloat(preview.width) * z,
                                                                                         y: u.y * CGFloat(preview.height) * z),
                                                          zoom: z, smooth: previewIsStandIn)],
                                      label: "\(rendered ? (previewIsStandIn ? "Darkslide, rendering…" : "Darkslide") : "Camera preview")  \(Int(model.loupeZoom * 100))%")
                                .position(p)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
    }

    private func load() {
        let url = item.url
        preview = nil
        rendered = item.hasEdit || Library.hasStoredRender(for: url)
        guard rendered else {
            Task {
                let full = await model.culling.preview(url.photoFile, pixels: 8192)
                if model.loupeItem == url { preview = full }
            }
            return
        }
        preview = model.library.thumbnails[url]
        previewIsStandIn = true
        standInScale = 1
        Task {
            if let thumb = preview, let width = await Task.detached(operation: { Self.pixelWidth(url) }).value,
               model.loupeItem == url, previewIsStandIn {
                standInScale = CGFloat(width) / CGFloat(max(thumb.width, 1))
            }
        }
        Task {
            // only once the pointer rests: each render takes the engine a second or two
            try? await Task.sleep(for: .milliseconds(300))
            guard model.loupeItem == url, let full = await model.loupeRender(url), model.loupeItem == url else { return }
            preview = full
            previewIsStandIn = false
        }
    }

    /// the photo's width as shown (turned as the camera was held), from its metadata
    nonisolated private static func pixelWidth(_ url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url.photoFile as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let turned = [5, 6, 7, 8].contains(p[kCGImagePropertyOrientation] as? Int ?? 1)
        return turned ? h : w
    }
}
