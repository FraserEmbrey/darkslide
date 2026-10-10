// Mask lab: Apple's masks for each test photo and click.
//
//   vision-subject   Vision's subject (foreground instance) mask, the instance under the click
//   vision-person    Vision's person segmentation, accurate quality (not click-based)
//   apple-sam-<size> Apple's Core ML SAM 2.1, the best of its three masks for the click
//
// Usage: AppleRunner <images dir> <prompts.json> <models dir> <out dir>
// Masks are written as 8-bit grey PNGs the size of the photo, named
// <photo>__<prompt>__<model>.png, with timings appended to timings.jsonl.

import CoreImage
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

struct Prompt: Decodable { let name: String; let x: Double; let y: Double }

let args = CommandLine.arguments
let imagesDir = URL(fileURLWithPath: args[1]), modelsDir = URL(fileURLWithPath: args[3]), outDir = URL(fileURLWithPath: args[4])
let prompts = try JSONDecoder().decode([String: [Prompt]].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let timings = outDir.appendingPathComponent("timings.jsonl")
if !FileManager.default.fileExists(atPath: timings.path) { FileManager.default.createFile(atPath: timings.path, contents: nil) }

func log(_ photo: String, _ prompt: String, _ model: String, _ seconds: Double, _ note: String = "") {
    let line = "{\"photo\":\"\(photo)\",\"prompt\":\"\(prompt)\",\"model\":\"\(model)\",\"seconds\":\(String(format: "%.3f", seconds)),\"note\":\"\(note)\"}\n"
    let h = try! FileHandle(forWritingTo: timings); h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
}

func time<T>(_ f: () throws -> T) rethrows -> (T, Double) {
    let t = Date(); let r = try f(); return (r, Date().timeIntervalSince(t))
}

/// a 0...1 mask, w × h, as an 8-bit grey PNG
func save(_ mask: [Float], _ w: Int, _ h: Int, to url: URL) {
    var bytes = mask.map { UInt8(max(0, min(255, $0 * 255))) }
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

/// bilinear resample of a mask from (sw, sh) to (dw, dh), stretching
func resample(_ src: [Float], _ sw: Int, _ sh: Int, _ dw: Int, _ dh: Int) -> [Float] {
    var out = [Float](repeating: 0, count: dw * dh)
    for y in 0..<dh {
        let fy = max(0, (Float(y) + 0.5) * Float(sh) / Float(dh) - 0.5)
        let y0 = min(Int(fy), sh - 1), y1 = min(y0 + 1, sh - 1), ty = fy - Float(y0)
        for x in 0..<dw {
            let fx = max(0, (Float(x) + 0.5) * Float(sw) / Float(dw) - 0.5)
            let x0 = min(Int(fx), sw - 1), x1 = min(x0 + 1, sw - 1), tx = fx - Float(x0)
            let a = src[y0 * sw + x0], b = src[y0 * sw + x1], c = src[y1 * sw + x0], d = src[y1 * sw + x1]
            out[y * dw + x] = (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
        }
    }
    return out
}

func floats(_ a: MLMultiArray) -> [Float] {
    let n = a.count
    var out = [Float](repeating: 0, count: n)
    if a.dataType == .float16 {
        a.withUnsafeBufferPointer(ofType: Float16.self) { p in for i in 0..<n { out[i] = Float(p[i]) } }
    } else {
        a.withUnsafeBufferPointer(ofType: Float.self) { p in for i in 0..<n { out[i] = p[i] } }
    }
    return out
}

// MARK: Apple's Core ML SAM 2.1

struct AppleSAM {
    let encoder: MLModel, promptEncoder: MLModel, decoder: MLModel
    init(folder: URL) throws {
        func load(_ suffix: String) throws -> MLModel {
            let pkg = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.contains(suffix) && $0.pathExtension == "mlpackage" }!
            let config = MLModelConfiguration(); config.computeUnits = .all
            return try MLModel(contentsOf: try MLModel.compileModel(at: pkg), configuration: config)
        }
        encoder = try load("ImageEncoder"); promptEncoder = try load("PromptEncoder"); decoder = try load("MaskDecoder")
    }

    /// the image squeezed to 1024 × 1024, as Apple's own SAM 2 demo feeds it
    func encode(_ image: CGImage) throws -> MLFeatureProvider {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1024, 1024, kCVPixelFormatType_32BGRA, nil, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: 1024, height: 1024, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        return try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pb!)]))
    }

    /// the mask for one click (x, y in the photo's pixels), as 0/1 at w × h
    func mask(_ enc: MLFeatureProvider, x: Double, y: Double, w: Int, h: Int) throws -> [Float] {
        let points = try MLMultiArray(shape: [1, 1, 2], dataType: .float32)
        points[0] = NSNumber(value: x * 1024 / Double(w)); points[1] = NSNumber(value: y * 1024 / Double(h))
        let labels = try MLMultiArray(shape: [1, 1], dataType: .float32); labels[0] = 1
        let p = try promptEncoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["points": points, "labels": labels]))
        let d = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "image_embedding": enc.featureValue(for: "image_embedding")!,
            "feats_s0": enc.featureValue(for: "feats_s0")!,
            "feats_s1": enc.featureValue(for: "feats_s1")!,
            "sparse_embedding": p.featureValue(for: "sparse_embeddings")!,
            "dense_embedding": p.featureValue(for: "dense_embeddings")!,
        ]))
        let scores = floats(d.featureValue(for: "scores")!.multiArrayValue!)
        let best = scores.indices.max { scores[$0] < scores[$1] }!
        let all = floats(d.featureValue(for: "low_res_masks")!.multiArrayValue!)
        let logits = Array(all[(best * 256 * 256)..<((best + 1) * 256 * 256)])
        return resample(logits, 256, 256, w, h).map { $0 > 0 ? 1 : 0 }
    }
}

// MARK: run

let sams: [(String, AppleSAM)] = ["small", "baseplus"].compactMap { size in
    let folder = modelsDir.appendingPathComponent("apple-sam21-\(size)")
    guard FileManager.default.fileExists(atPath: folder.path), let s = try? AppleSAM(folder: folder) else { return nil }
    return ("apple-sam-\(size)", s)
}

for photo in prompts.keys.sorted() {
    let url = imagesDir.appendingPathComponent(photo)
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let w = image.width, h = image.height
    let base = (photo as NSString).deletingPathExtension

    // Vision: subject instances, and people
    let handler = VNImageRequestHandler(cgImage: image)
    let subject = VNGenerateForegroundInstanceMaskRequest()
    let (_, subjectTime) = time { try? handler.perform([subject]) }
    let person = VNGeneratePersonSegmentationRequest(); person.qualityLevel = .accurate
    person.outputPixelFormat = kCVPixelFormatType_OneComponent32Float
    let (_, personTime) = time { try? handler.perform([person]) }

    var encodings: [String: (MLFeatureProvider, Double)] = [:]
    for (name, sam) in sams {
        let (enc, t) = try time { try sam.encode(image) }
        encodings[name] = (enc, t)
        log(base, "-", name + "-encode", t)
    }

    for prompt in prompts[photo] ?? [] {
        // the subject instance under the click
        var subjectMask = [Float](repeating: 0, count: w * h)
        var note = "no subject found"
        if let obs = subject.results?.first {
            let im = obs.instanceMask
            CVPixelBufferLockBaseAddress(im, .readOnly)
            let mw = CVPixelBufferGetWidth(im), mh = CVPixelBufferGetHeight(im), row = CVPixelBufferGetBytesPerRow(im)
            let p = CVPixelBufferGetBaseAddress(im)!.assumingMemoryBound(to: UInt8.self)
            let label = Int(p[Int(prompt.y / Double(h) * Double(mh)) * row + Int(prompt.x / Double(w) * Double(mw))])
            CVPixelBufferUnlockBaseAddress(im, .readOnly)
            if label > 0, let scaled = try? obs.generateScaledMaskForImage(forInstances: IndexSet(integer: label), from: handler) {
                CVPixelBufferLockBaseAddress(scaled, .readOnly)
                let sw = CVPixelBufferGetWidth(scaled), sh = CVPixelBufferGetHeight(scaled), srow = CVPixelBufferGetBytesPerRow(scaled) / 4
                let f = CVPixelBufferGetBaseAddress(scaled)!.assumingMemoryBound(to: Float.self)
                var m = [Float](repeating: 0, count: sw * sh)
                for y in 0..<sh { for x in 0..<sw { m[y * sw + x] = f[y * srow + x] } }
                CVPixelBufferUnlockBaseAddress(scaled, .readOnly)
                subjectMask = (sw == w && sh == h) ? m : resample(m, sw, sh, w, h)
                note = "instance \(label) of \(obs.allInstances.count)"
            } else if label == 0 {
                note = "click not on a subject (\(obs.allInstances.count) found)"
            }
        }
        save(subjectMask, w, h, to: outDir.appendingPathComponent("\(base)__\(prompt.name)__vision-subject.png"))
        log(base, prompt.name, "vision-subject", subjectTime, note)

        // people, whatever was clicked
        var personMask = [Float](repeating: 0, count: w * h)
        if let pb = person.results?.first?.pixelBuffer {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let pw = CVPixelBufferGetWidth(pb), ph = CVPixelBufferGetHeight(pb), prow = CVPixelBufferGetBytesPerRow(pb) / 4
            let f = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: Float.self)
            var m = [Float](repeating: 0, count: pw * ph)
            for y in 0..<ph { for x in 0..<pw { m[y * pw + x] = f[y * prow + x] } }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            personMask = resample(m, pw, ph, w, h)
        }
        save(personMask, w, h, to: outDir.appendingPathComponent("\(base)__\(prompt.name)__vision-person.png"))
        log(base, prompt.name, "vision-person", personTime)

        for (name, sam) in sams {
            let (m, t) = try time { try sam.mask(encodings[name]!.0, x: prompt.x, y: prompt.y, w: w, h: h) }
            save(m, w, h, to: outDir.appendingPathComponent("\(base)__\(prompt.name)__\(name).png"))
            log(base, prompt.name, name, t)
        }
    }
    print("done", photo)
}
