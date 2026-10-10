import AppKit
import QuartzCore
import SwiftUI

/// Shows a frame in a Core Animation layer that is allowed to use the
/// display's EDR headroom. SwiftUI's Image clipped our float output to SDR
/// white; layers are explicit. On macOS 26 a layer only goes beyond SDR when
/// its image carries a content headroom tag, which Engine adds to HDR frames.
struct EDRImageView: NSViewRepresentable {
    let image: CGImage
    let overlay: CGImage?
    let isHDR: Bool
    var before: CGImage? = nil   // shown left of `split` when comparing
    var split: Double = 0.5
    /// draw one image pixel per screen pixel, centred (zoomed crops) instead of fitting
    var pixelExact = false
    /// shifts the shown frame while a pan waits for its render, in points
    var panOffset: CGSize = .zero
    /// the whole photo, soft, drawn under a zoomed frame at `backdropRect` (view
    /// points, before the pan offset), so a pan shows something at once where
    /// the sharp render hasn't reached yet
    var backdrop: CGImage? = nil
    var backdropRect: CGRect = .zero
    /// clicks (in view points, top-left origin) and pans (content movement in points)
    var canPan = false
    var onClick: ((CGPoint) -> Void)? = nil
    var onPan: ((CGSize) -> Void)? = nil

    func makeNSView(context: Context) -> LayerView { LayerView() }

    /// Where the image sits inside a view, as the layers draw it: aspect-fitted,
    /// or centred at one image pixel per screen pixel when pixel-exact.
    static func displayedRect(_ image: CGSize, in view: CGSize, pixelExact: Bool, displayScale: CGFloat) -> CGRect {
        guard pixelExact else { return fittedRect(image, in: view) }
        let size = CGSize(width: image.width / displayScale, height: image.height / displayScale)
        return CGRect(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Where an aspect-fitted image sits inside a view, as the layers draw it.
    static func fittedRect(_ image: CGSize, in view: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: view) }
        let scale = min(view.width / image.width, view.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    func updateNSView(_ view: LayerView, context: Context) {
        view.update(image: image, overlay: overlay, isHDR: isHDR, before: before, split: split, pixelExact: pixelExact)
        view.onClick = onClick
        view.onPan = onPan
        view.canPan = canPan
        view.setPanOffset(panOffset)
        view.setBackdrop(backdrop, rect: backdropRect, isHDR: isHDR)
    }

    final class LayerView: NSView {
        private let backdropLayer = CALayer()
        private let imageLayer = CALayer()
        private let overlayLayer = CALayer()
        private let probeLayer = CALayer()
        private let beforeLayer = CALayer()
        private let beforeMask = CALayer()
        private var split: Double = 0.5
        private var imageSize = CGSize(width: 1, height: 1)

        /// the before image shows left of the split, measured across the photo
        private func updateMask() {
            let r = EDRImageView.displayedRect(imageSize, in: bounds.size, pixelExact: pixelExact,
                                               displayScale: window?.backingScaleFactor ?? 2)
            beforeMask.frame = CGRect(x: 0, y: 0, width: r.minX + r.width * split, height: bounds.height)
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for l in [imageLayer, overlayLayer] {
                l.contentsGravity = .resizeAspect
                l.minificationFilter = .trilinear
                layer?.addSublayer(l)
            }
            overlayLayer.magnificationFilter = .nearest
            backdropLayer.contentsGravity = .resize
            backdropLayer.isHidden = true
            layer?.insertSublayer(backdropLayer, below: imageLayer)
            beforeLayer.contentsGravity = .resizeAspect
            beforeLayer.minificationFilter = .trilinear
            beforeMask.backgroundColor = CGColor(gray: 1, alpha: 1)
            beforeLayer.mask = beforeMask
            beforeLayer.isHidden = true
            layer?.insertSublayer(beforeLayer, above: imageLayer)
            setUpProbe()
        }

        /// macOS reports the EDR headroom in use, which with only our image on
        /// screen is just the image's own peak. A 1×1 black layer tagged with the
        /// maximum headroom makes it report what the display can give right now
        /// (which shrinks as brightness goes up). Black, so it's invisible.
        private func setUpProbe() {
            guard #available(macOS 26.0, *) else { return }
            let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            probeLayer.backgroundColor = CGColor(headroom: 16, colorSpace: space, red: 0, green: 0, blue: 0, alpha: 1)
            probeLayer.preferredDynamicRange = .high
            probeLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            probeLayer.isHidden = true
            layer?.addSublayer(probeLayer)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        // The canvas takes keyboard focus when the window opens, so the search
        // field doesn't start focused (macOS gives the first text field focus).
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, window.firstResponder is NSTextView || window.firstResponder === window else { return }
                window.makeFirstResponder(self)
            }
        }

        // Mouse handling lives here because this AppKit view receives the
        // events before SwiftUI's gestures would.
        var onClick: ((CGPoint) -> Void)?
        var onPan: ((CGSize) -> Void)?
        var canPan = false
        private var dragged = false

        override var isFlipped: Bool { true }

        func setPanOffset(_ o: CGSize) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.sublayerTransform = CATransform3DMakeTranslation(o.width, o.height, 0)
            CATransaction.commit()
        }

        func setBackdrop(_ image: CGImage?, rect: CGRect, isHDR: Bool) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdropLayer.contents = image
            backdropLayer.isHidden = image == nil
            backdropLayer.frame = rect
            backdropLayer.contentsScale = window?.backingScaleFactor ?? 2
            if #available(macOS 26.0, *) {
                backdropLayer.preferredDynamicRange = isHDR ? .high : .standard
            } else {
                backdropLayer.wantsExtendedDynamicRangeContent = isHDR
            }
            CATransaction.commit()
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)   // clicking the photo leaves the search field
            dragged = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard canPan else { return }
            if !dragged { dragged = true; NSCursor.closedHand.push() }
            onPan?(CGSize(width: event.deltaX, height: event.deltaY))
        }

        override func mouseUp(with event: NSEvent) {
            if dragged { NSCursor.pop(); dragged = false; return }
            onClick?(convert(event.locationInWindow, from: nil))
        }

        // two-finger trackpad scrolling (and the mouse wheel) pan while zoomed
        override func scrollWheel(with event: NSEvent) {
            guard canPan else { return super.scrollWheel(with: event) }
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            onPan?(CGSize(width: event.scrollingDeltaX * k, height: event.scrollingDeltaY * k))
        }

        private var pixelExact = false

        func update(image: CGImage, overlay: CGImage?, isHDR: Bool, before: CGImage?, split: Double, pixelExact: Bool) {
            self.pixelExact = pixelExact
            let gravity: CALayerContentsGravity = pixelExact ? .center : .resizeAspect
            imageLayer.contentsGravity = gravity
            overlayLayer.contentsGravity = gravity
            beforeLayer.contentsGravity = gravity
            CATransaction.begin()
            CATransaction.setDisableActions(true)   // no cross-fade between renders
            imageLayer.contents = image
            beforeLayer.contents = before
            beforeLayer.isHidden = before == nil
            self.split = split
            imageSize = CGSize(width: image.width, height: image.height)
            updateMask()
            overlayLayer.contents = overlay
            overlayLayer.isHidden = overlay == nil
            probeLayer.isHidden = !isHDR   // only spend the power while viewing HDR
            if #available(macOS 26.0, *) {
                imageLayer.preferredDynamicRange = isHDR ? .high : .standard
                beforeLayer.preferredDynamicRange = isHDR ? .high : .standard
            } else {
                imageLayer.wantsExtendedDynamicRangeContent = isHDR
                beforeLayer.wantsExtendedDynamicRangeContent = isHDR
            }
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.frame = bounds
            overlayLayer.frame = bounds
            beforeLayer.frame = bounds
            updateMask()
            let scale = window?.backingScaleFactor ?? 2
            imageLayer.contentsScale = scale
            overlayLayer.contentsScale = scale
            beforeLayer.contentsScale = scale
            CATransaction.commit()
        }
    }
}
