import SwiftUI

/// Aperture's loupe: a round lens showing an image at one image pixel to a
/// screen pixel, `pixel` at its centre. HDR images keep their highlights.
struct LoupeLens: View {
    @Environment(\.displayScale) private var displayScale
    let image: CGImage
    /// the image pixel under the lens's centre, in the image as magnified by `zoom`
    let pixel: CGPoint
    /// screen pixels to an image pixel (the editor renders at its zoom, so 1 there)
    var zoom: CGFloat = 1
    var diameter: CGFloat = 220
    var label: String?

    var body: some View {
        let w = CGFloat(image.width) * zoom / displayScale, h = CGFloat(image.height) * zoom / displayScale
        ZStack(alignment: .bottom) {
            Image(decorative: image, scale: displayScale)
                .resizable()
                .interpolation(.none)
                .allowedDynamicRange(.high)
                .frame(width: w, height: h)
                .offset(x: w / 2 - pixel.x / displayScale, y: h / 2 - pixel.y / displayScale)
                .frame(width: diameter, height: diameter)
                .background(Color.black)
                .clipShape(Circle())
            if let label {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
        .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 0.5).padding(-1))
        .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
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
        if let img = model.loupeImage {
            let o = toImage(pointer)
            // the image starts at loupeOrigin on the output, at loupeZoom
            let px = CGPoint(x: (o.x - model.loupeOrigin.x) * model.loupeZoom,
                             y: (o.y - model.loupeOrigin.y) * model.loupeZoom)
            LoupeLens(image: img, pixel: px, label: "\(Int(model.loupeZoom * 100))%")
                .position(pointer)
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
