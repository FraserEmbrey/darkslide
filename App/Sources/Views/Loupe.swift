import SwiftUI

/// One image in the loupe: `pixel` (in the image as magnified by `zoom`) at
/// its centre. `smooth` scales it smoothly, for a stand-in at another size.
struct LoupeLayer {
    let image: CGImage
    let pixel: CGPoint
    var zoom: CGFloat = 1
    var smooth = false
}

/// Aperture's loupe, as a lens of Liquid Glass: images at one image pixel to
/// a screen pixel (`zoom` magnifies), drawn bottom first, so a sharp render
/// can sit over a softer stand-in until it covers the lens. HDR images keep
/// their highlights.
struct LoupeLens: View {
    @Environment(\.displayScale) private var displayScale
    let layers: [LoupeLayer]
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

    /// the glass rim's width
    private let rim: CGFloat = 14

    var body: some View {
        ZStack {
            Color.black
            ForEach(layers.indices, id: \.self) { i in
                let l = layers[i]
                let w = CGFloat(l.image.width) * l.zoom / displayScale, h = CGFloat(l.image.height) * l.zoom / displayScale
                Image(decorative: l.image, scale: displayScale)
                    .resizable()
                    .interpolation(l.smooth ? .high : .none)
                    .allowedDynamicRange(.high)
                    .frame(width: w, height: h)
                    .offset(x: w / 2 - l.pixel.x / displayScale, y: h / 2 - l.pixel.y / displayScale)
                    .frame(width: diameter, height: diameter)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        // the rim: a ring of glass that bends the picture at the lens's edge
        .overlay {
            Color.clear
                .glassEffect(.clear, in: Circle().inset(by: rim / 2).stroke(lineWidth: rim))
        }
        .overlay(alignment: .bottom) {
            if let label {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .glassEffect(.regular.tint(.black.opacity(0.35)), in: Capsule())
                    .padding(.bottom, rim + 4)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .allowsHitTesting(false)
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
                LoupeLens(layers: layers, label: "\(Int(zoom * 100))%")
                    .position(pointer)
            }
        }
    }
}

/// The loupe over a grid thumbnail: the camera's full-size preview of the
/// photo (as the cull view loads it), at the point under the pointer.
struct GridLoupe: ViewModifier {
    @Environment(EditorModel.self) private var model
    let item: LibraryItem
    @State private var pointer: CGPoint?
    @State private var preview: CGImage?

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
                            LoupeLens(image: preview, pixel: CGPoint(x: u.x * CGFloat(preview.width) * model.loupeZoom,
                                                                     y: u.y * CGFloat(preview.height) * model.loupeZoom),
                                      zoom: model.loupeZoom, label: "\(Int(model.loupeZoom * 100))%")
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
        Task {
            let full = await model.culling.preview(url.photoFile, pixels: 8192)
            if model.loupeItem == url { preview = full }
        }
    }
}
