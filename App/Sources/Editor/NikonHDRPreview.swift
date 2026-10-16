import CoreImage
import CoreMedia
import Foundation
import VideoToolbox

/// The HDR preview inside a NEF shot in the HLG tone mode (Z6III, Z8, Z9,
/// Zf and others). Those NEFs carry no JPEG preview, only a 160 px
/// thumbnail macOS can read; their previews (1620 × 1080 and 320 × 212) are
/// single HEVC Main 10 frames, HLG with Rec.2020 primaries, in SubIFDs
/// marked "Nikon NEF Compressed". This finds the largest by walking the
/// TIFF structure, reading only the bytes it needs (the file may be on a
/// network share), and decodes it with VideoToolbox, as NX Studio shows it.
/// Its presence is also how an HLG NEF is told apart: the raw data is the
/// same in either tone mode.
enum NikonHDRPreview {
    private struct Entry { let tag: UInt16, type: UInt16, count: UInt32, value: UInt32 }

    /// a NEF's HEVC preview stream, or nil when it has none (an SDR NEF, or not a NEF)
    static func stream(in url: URL) -> Data? {
        guard url.pathExtension.lowercased() == "nef", let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        func read(_ offset: UInt64, _ length: Int) -> [UInt8]? {
            guard (try? file.seek(toOffset: offset)) != nil, let d = try? file.read(upToCount: length), d.count == length else { return nil }
            return [UInt8](d)
        }
        guard let header = read(0, 8) else { return nil }
        let big = header[0] == 0x4D
        guard big || header[0] == 0x49 else { return nil }
        func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
            big ? UInt16(b[i]) << 8 | UInt16(b[i + 1]) : UInt16(b[i + 1]) << 8 | UInt16(b[i])
        }
        func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
            big ? UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
                : UInt32(b[i + 3]) << 24 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i])
        }
        func entries(at offset: UInt32) -> [Entry]? {
            guard let n = read(UInt64(offset), 2).map({ Int(u16($0, 0)) }), n > 0, n < 1000,
                  let b = read(UInt64(offset) + 2, n * 12) else { return nil }
            return (0..<n).map { k in
                let i = k * 12
                // a SHORT value sits in the first two bytes of the value field
                let type = u16(b, i + 2), count = u32(b, i + 4)
                let value = type == 3 && count == 1 ? UInt32(u16(b, i + 8)) : u32(b, i + 8)
                return Entry(tag: u16(b, i), type: type, count: count, value: value)
            }
        }
        guard let ifd0 = entries(at: u32(header, 4)),
              let sub = ifd0.first(where: { $0.tag == 0x014A }), sub.count > 0, sub.count < 32 else { return nil }
        let offsets: [UInt32] = sub.count == 1 ? [sub.value]
            : (read(UInt64(sub.value), Int(sub.count) * 4).map { b in (0..<Int(sub.count)).map { u32(b, $0 * 4) } } ?? [])

        // the largest 10-bit RGB image in Nikon's compression: the HEVC previews
        var best: (width: UInt32, offset: UInt32, length: UInt32)?
        for o in offsets {
            guard let e = entries(at: o) else { continue }
            func value(_ tag: UInt16) -> Entry? { e.first { $0.tag == tag } }
            guard value(259)?.value == 34713, let bps = value(258), bps.count == 3,
                  let bits = read(UInt64(bps.value), 2).map({ u16($0, 0) }), bits == 10,
                  let width = value(256)?.value, let start = value(273), let length = value(279),
                  start.count == 1, length.count == 1 else { continue }
            if width > best?.width ?? 0 { best = (width, start.value, length.value) }
        }
        guard let best, best.length > 16, best.length < 20_000_000,
              let bytes = read(UInt64(best.offset), Int(best.length)),
              bytes.starts(with: [0, 0, 0, 1, 0x40, 0x01])     // an HEVC parameter set first
        else { return nil }
        return Data(bytes)
    }

    /// whether a NEF was shot in the HLG tone mode
    static func isHLG(_ url: URL) -> Bool { stream(in: url) != nil }

    /// the decoded preview, HLG (its colour space says so), or nil
    static func image(in url: URL) -> CIImage? {
        stream(in: url).flatMap(decode)
    }

    /// One HEVC frame in Annex B form (start codes) through the hardware decoder.
    static func decode(_ stream: Data) -> CIImage? {
        let b = [UInt8](stream)
        var starts: [Int] = []
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 { starts.append(i + 3); i += 3 } else { i += 1 }
        }
        var units: [[UInt8]] = []
        for (k, s) in starts.enumerated() {
            var e = k + 1 < starts.count ? starts[k + 1] - 3 : b.count
            while e > s, b[e - 1] == 0 { e -= 1 }
            if e > s { units.append(Array(b[s..<e])) }
        }
        func kind(_ u: [UInt8]) -> UInt8 { (u[0] >> 1) & 0x3F }
        // VPS, SPS and PPS describe the format; the rest (bar SEI) is the picture
        let parameters = units.filter { [32, 33, 34].contains(kind($0)) }
        let picture = units.filter { kind($0) < 32 }
        guard parameters.count == 3, !picture.isEmpty else { return nil }

        var format: CMFormatDescription?
        let status: OSStatus = parameters[0].withUnsafeBufferPointer { p0 in
            parameters[1].withUnsafeBufferPointer { p1 in
                parameters[2].withUnsafeBufferPointer { p2 in
                    let pointers = [p0.baseAddress!, p1.baseAddress!, p2.baseAddress!]
                    let sizes = parameters.map(\.count)
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: nil, parameterSetCount: 3, parameterSetPointers: pointers,
                        parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
                }
            }
        }
        guard status == noErr, let format else { return nil }

        // the picture's units, each led by its length
        var sample = Data()
        for u in picture {
            var length = UInt32(u.count).bigEndian
            sample.append(Data(bytes: &length, count: 4))
            sample.append(contentsOf: u)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: sample.count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: sample.count, flags: 0, blockBufferOut: &block) == noErr,
              let block,
              sample.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                      offsetIntoDestination: 0, dataLength: sample.count) }) == noErr
        else { return nil }
        var size = sample.count
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr, let buffer else { return nil }

        var session: VTDecompressionSession?
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_64RGBAHalf]
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr, let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }
        nonisolated(unsafe) var decoded: CVPixelBuffer?
        let started = VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer, flags: [], infoFlagsOut: nil) { s, _, image, _, _ in
            if s == noErr { decoded = image }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard started == noErr, let decoded else { return nil }
        // tagged HLG and Rec.2020 from the stream's own colour description
        return CIImage(cvPixelBuffer: decoded)
    }

    /// the preview as an SDR picture for thumbnails, its highlights tone mapped
    static func sdrPicture(in url: URL, maxPixels: Int) -> CGImage? {
        guard var image = image(in: url) else { return nil }
        let e = image.extent
        let scale = min(1, Double(maxPixels) / Double(max(e.width, e.height)))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // HLG's peak, as macOS shows it, is about 4.9 × SDR white
        let headroom = image.contentHeadroom > 1 ? image.contentHeadroom : 4.93
        image = image.applyingFilter("CIToneMapHeadroom", parameters: [
            "inputSourceHeadroom": headroom, "inputTargetHeadroom": 1,
        ])
        return CIContext().createCGImage(image, from: image.extent.integral, format: .RGBA8,
                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
