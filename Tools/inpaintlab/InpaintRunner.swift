// Inpainting lab: runs LaMa (Core ML, made by convert_lama.py) on a photo
// with elliptical masks, as an object-removal tool would: a square around
// the mask, three times its size unless INPAINT_CONTEXT says, is cut out,
// scaled to the model's side (512, or INPAINT_SIZE), filled, scaled back and
// blended in with a soft edge.
//
//   swiftc -O Tools/inpaintlab/InpaintRunner.swift -o inpaint-runner
//   ./inpaint-runner photo.jpg LaMa512.mlpackage out.jpg x,y,w,h [x,y,w,h …]
//
// Rectangles are in the photo's pixels, top left origin; each is filled as an
// ellipse. INPAINT_DEBUG=<folder> writes each crop, mask and raw output there.
import CoreImage
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 5 else { print("usage: inpaint-runner photo model out x,y,w,h …"); exit(1) }
let debug = ProcessInfo.processInfo.environment["INPAINT_DEBUG"]
// INPAINT_SIZE: the model's side (512 or 1024); INPAINT_CONTEXT: the square's side over the mask's
let size = Int(ProcessInfo.processInfo.environment["INPAINT_SIZE"] ?? "") ?? 512
let context = Double(ProcessInfo.processInfo.environment["INPAINT_CONTEXT"] ?? "") ?? 3
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// a CGImage as 8-bit RGBA, top row first
func pixels(_ cg: CGImage) -> [UInt8] {
    var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    let ctx = CGContext(data: &px, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    return px
}

func image(_ px: [UInt8], width: Int, height: Int) -> CGImage {
    CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

func write(_ cg: CGImage, _ path: String, type: UTType = .png) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    CGImageDestinationFinalize(d)
}

/// a region of an image drawn into a square of `side` pixels
func resample(_ cg: CGImage, rect: CGRect, side: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // CGContext's origin is bottom left; rect is top left
    let s = Double(side) / rect.width
    ctx.draw(cg, in: CGRect(x: -rect.minX * s, y: -(Double(cg.height) - rect.maxY) * s,
                            width: Double(cg.width) * s, height: Double(cg.height) * s))
    return ctx.makeImage()!
}

let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!
var photo = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let W = photo.width, H = photo.height
let config = MLModelConfiguration()
config.computeUnits = .all
let model = try MLModel(contentsOf: try MLModel.compileModel(at: URL(fileURLWithPath: args[2])), configuration: config)

for (n, spec) in args[4...].enumerated() {
    let v = spec.split(separator: ",").map { Double($0)! }
    let hole = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    let grow = hole.insetBy(dx: -hole.width * 0.1, dy: -hole.height * 0.1)
    let side = min(max(max(hole.width, hole.height) * context, Double(size) / 2), Double(min(W, H)))
    let crop = CGRect(x: min(max(hole.midX - side / 2, 0), Double(W) - side),
                      y: min(max(hole.midY - side / 2, 0), Double(H) - side), width: side, height: side).integral

    // the crop at 512, and the mask over it (1 in the hole)
    let small = pixels(resample(photo, rect: crop, side: size))
    let k = Double(size) / crop.width
    var mask = [Float](repeating: 0, count: size * size)
    for y in 0..<size { for x in 0..<size {
        let px = crop.minX + (Double(x) + 0.5) / k, py = crop.minY + (Double(y) + 0.5) / k
        let dx = (px - grow.midX) / (grow.width / 2), dy = (py - grow.midY) / (grow.height / 2)
        if dx * dx + dy * dy <= 1 { mask[y * size + x] = 1 }
    } }
    let img = try MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
    let msk = try MLMultiArray(shape: [1, 1, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
    let ip = img.dataPointer.assumingMemoryBound(to: Float.self), mp = msk.dataPointer.assumingMemoryBound(to: Float.self)
    for i in 0..<(size * size) {
        for c in 0..<3 { ip[c * size * size + i] = Float(small[i * 4 + c]) / 255 }
        mp[i] = mask[i]
    }

    let start = Date()
    let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": img, "mask": msk]))
        .featureValue(for: "output")!.multiArrayValue!
    let ms = Int(Date().timeIntervalSince(start) * 1000)

    // the output, 0...1, half or single precision as the conversion left it
    func value(_ i: Int) -> Float {
        out.dataType == .float16 ? Float(out.dataPointer.assumingMemoryBound(to: Float16.self)[i])
                                 : out.dataPointer.assumingMemoryBound(to: Float.self)[i]
    }
    var filled = small
    for i in 0..<(size * size) { for c in 0..<3 { filled[i * 4 + c] = UInt8(max(0, min(255, value(c * size * size + i) * 255))) } }
    if let debug {
        write(image(small, width: size, height: size), "\(debug)/crop-\(n).png")
        write(image(mask.flatMap { [UInt8($0 * 255), UInt8($0 * 255), UInt8($0 * 255), 255] }, width: size, height: size), "\(debug)/mask-\(n).png")
        write(image(filled, width: size, height: size), "\(debug)/output-\(n).png")
    }

    // back into the photo, inside the grown ellipse with a soft edge
    let fill = image(filled, width: size, height: size)
    var full = pixels(photo)
    let back = pixels(resample(fill, rect: CGRect(x: 0, y: 0, width: size, height: size), side: Int(crop.width)))
    let cw = Int(crop.width)
    for y in 0..<cw { for x in 0..<cw {
        let px = Int(crop.minX) + x, py = Int(crop.minY) + y
        guard px < W, py < H else { continue }
        let dx = (Double(px) - grow.midX) / (grow.width / 2), dy = (Double(py) - grow.midY) / (grow.height / 2)
        let r = (dx * dx + dy * dy).squareRoot()
        let a = max(0, min(1, (1.08 - r) / 0.12))   // fully filled inside 0.96, gone by 1.08
        guard a > 0 else { continue }
        let f = (py * W + px) * 4, b = (y * cw + x) * 4
        for c in 0..<3 { full[f + c] = UInt8(Double(full[f + c]) * (1 - a) + Double(back[b + c]) * a) }
    } }
    photo = image(full, width: W, height: H)
    print("filled \(spec) from a \(Int(crop.width)) px square (scale \(String(format: "%.2f", k))) in \(ms) ms")
}
write(photo, args[3], type: .jpeg)
