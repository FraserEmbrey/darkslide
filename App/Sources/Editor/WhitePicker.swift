import CoreImage
import Foundation

/// Click something that should be neutral, and the white balance makes it so.
///
/// darktable's own picker reads the module's input, which needs its GUI. This
/// reads the frame as shown instead and corrects by the cast it finds there,
/// then reads the next frame and corrects again, up to three times: the tone
/// mapper and the rest of the pipe sit between the white balance and the
/// screen, but they keep a neutral neutral, so the correction converges.
///
/// - Colour calibration: von Kries in Bradford LMS. The light it adapts from
///   is scaled by the cast, so a patch that shows blue moves the light bluer.
/// - Raw white balance: the same in the camera's own channels, through its matrix.
extension EditorModel {
    /// Starts picking for a white balance module (its key), or stops.
    func pickWhite(for module: String?) {
        whitePickTarget = module
        whitePickNote = nil
    }

    /// The point picked, 0...1 across the photo as processed.
    func pickWhite(at point: CGPoint) {
        guard let target = whitePickTarget else { return }
        whitePickTarget = nil
        whitePickTask?.cancel()
        whitePickTask = Task {
            for pass in 0..<3 {
                if pass > 0 { await nextFullFrame() }
                guard !Task.isCancelled, let xyz = sampleShown(at: point) else { return }
                if pass == 0, xyz[1] < 0.004 {
                    whitePickNote = "That's too dark to read. Pick something lighter."
                    return
                }
                if pass == 0, xyz[1] > 0.98, !imageIsHDR {
                    whitePickNote = "That's clipped. Pick something a little darker."
                    return
                }
                let cast = Self.castInBradford(xyz)
                if UserDefaults.standard.string(forKey: "TestWhitePick") != nil {
                    FileHandle.standardError.write("Darkslide white: pass \(pass) cast \(cast)\n".data(using: .utf8)!)
                }
                // under half a percent off neutral: done
                if cast.map({ abs($0 - 1) }).max()! < 0.005 { break }
                guard let m = modules.first(where: { $0.key == target }) else { return }
                if m.op == "channelmixerrgb" { correctSceneWhite(m, cast: cast) }
                else if m.op == "temperature" { correctRawWhite(m, xyz: xyz) }
            }
        }
    }

    // MARK: Reading the frame

    /// The average of a small patch of the frame on screen around a photo
    /// point, in XYZ (D65), nil when it isn't on screen.
    private func sampleShown(at p: CGPoint) -> [Double]? {
        guard let img = image else { return nil }
        var x = p.x * Double(img.width), y = p.y * Double(img.height)
        if imageIsZoomed, let c = shownCrop {
            x = p.x * imageSize.width * c.scale - Double(c.x)
            y = p.y * imageSize.height * c.scale - Double(c.y)
        }
        let r = max(2, Double(img.width) / 400)
        let box = CGRect(x: x - r, y: Double(img.height) - y - r, width: 2 * r + 1, height: 2 * r + 1)
            .intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height)).integral
        guard box.width >= 1, box.height >= 1 else { return nil }
        let w = Int(box.width), h = Int(box.height)
        var buf = [Float](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        Self.sampleContext.render(CIImage(cgImage: img).cropped(to: box), toBitmap: &buf, rowBytes: w * 16,
                                  bounds: box, format: .RGBAf, colorSpace: space)
        var rgb = [0.0, 0.0, 0.0]
        for i in 0..<(w * h) { for c in 0..<3 { rgb[c] += Double(buf[i * 4 + c]) } }
        rgb = rgb.map { $0 / Double(w * h) }
        // linear sRGB to XYZ, D65
        return [0.4124 * rgb[0] + 0.3576 * rgb[1] + 0.1805 * rgb[2],
                0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2],
                0.0193 * rgb[0] + 0.1192 * rgb[1] + 0.9505 * rgb[2]]
    }

    private static let sampleContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])

    /// Waits for the next full-size frame, or a few seconds.
    private func nextFullFrame() async {
        let start = frameID
        for _ in 0..<150 {
            try? await Task.sleep(for: .milliseconds(20))
            if frameID != start, !lastRenderWasDraft { return }
        }
    }

    // MARK: Colour calibration

    private static let bradford = [[0.8951, 0.2664, -0.1614], [-0.7502, 1.7135, 0.0367], [0.0389, -0.0685, 1.0296]]
    private static let bradfordInverse = [[0.9869929, -0.1470543, 0.1599627], [0.4323053, 0.5183603, 0.0492912],
                                          [-0.0085287, 0.0400428, 0.9684867]]
    private static let d65 = [0.95047, 1.0, 1.08883]

    private static func apply(_ m: [[Double]], _ v: [Double]) -> [Double] {
        m.map { row in zip(row, v).reduce(0) { $0 + $1.0 * $1.1 } }
    }

    /// the patch over white, per Bradford cone, at the patch's brightness
    private static func castInBradford(_ xyz: [Double]) -> [Double] {
        let patch = apply(bradford, xyz.map { $0 / xyz[1] }), white = apply(bradford, d65)
        return zip(patch, white).map { $0 / $1 }
    }

    private func correctSceneWhite(_ m: EngineModule, cast: [Double]) {
        func number(_ name: String) -> Double { m.fields.first { $0.name == name }?.value.number ?? 0 }
        let now: (x: Double, y: Double)
        switch Int(number("illuminant")) {
        case 2, 6: now = Illuminant.xy(kelvin: number("temperature"), tint: 0)
        default: now = (number("x"), number("y"))
        }
        guard now.y > 0 else { return }
        let lms = Self.apply(Self.bradford, CameraWhite.xyz(now))
        let xyz = Self.apply(Self.bradfordInverse, zip(lms, cast).map { $0 * $1 })
        let sum = xyz.reduce(0, +)
        guard sum > 0 else { return }
        let x = xyz[0] / sum, y = xyz[1] / sum
        let kt = Illuminant.kelvinAndTint(x: x, y: y)
        guard (1667...25000).contains(kt.kelvin) else {
            whitePickNote = "That doesn't look like something neutral."
            return
        }
        setValue(.number(7), module: m.key, field: "illuminant")   // custom
        setValue(.number(x), module: m.key, field: "x")
        setValue(.number(y), module: m.key, field: "y")
        setValue(.number(kt.kelvin), module: m.key, field: "temperature")
    }

    // MARK: Raw white balance

    private func correctRawWhite(_ m: EngineModule, xyz: [Double]) {
        guard let cam = cameraWhite else { return }
        func number(_ name: String) -> Double { m.fields.first { $0.name == name }?.value.number ?? 0 }
        let patch = cam.camera(xyz.map { $0 / xyz[1] }), white = cam.camera(Self.d65)
        let names = ["red", "green", "blue", "various"]
        var mul = names.map(number)
        for k in 0..<3 where patch[k] > 0 { mul[k] *= white[k] / patch[k] }
        let g = mul[1] > 0 ? mul[1] : 1
        for k in 0..<3 { setValue(.number(mul[k] / g), module: m.key, field: names[k]) }
    }
}
