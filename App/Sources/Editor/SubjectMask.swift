import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// The photo's subject as a mask, from Apple's Vision: the foreground
/// instance mask behind subject lifting in Photos and Preview. It runs on
/// the Neural Engine in a few tens of milliseconds and needs no download;
/// Apple improves it with macOS updates.
enum SubjectMask {
    struct Found {
        let file: URL           // one byte a pixel, 255 inside
        let width: Int, height: Int
    }

    /// every subject Vision finds, together; nil when there's none
    static func find(in image: CGImage) throws -> Found? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
        // at the size of the render, soft-edged (0 to 1)
        let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.size
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: Float.self) else { return nil }
        var bytes = Data(count: w * h)
        var inside = 0
        bytes.withUnsafeMutableBytes { out in
            let o = out.bindMemory(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w {
                    let v = min(max(base[y * stride + x], 0), 1)
                    o[y * w + x] = UInt8((v * 255).rounded())
                    if v > 0.5 { inside += 1 }
                }
            }
        }
        guard inside > 0 else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("develop-subject-\(UUID().uuidString).mask")
        try bytes.write(to: file)
        return Found(file: file, width: w, height: h)
    }
}
