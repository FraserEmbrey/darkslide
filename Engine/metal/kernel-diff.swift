// Runs one darktable kernel through Apple's OpenCL (the original .cl) and
// through Metal (the cl2metal.py translation) on identical inputs, and
// compares every output value.
//
// usage: kernel-diff CL_DIR METAL_DIR SPEC.json
// SPEC: {"file": "basic", "kernel": "exposure", "global": [w, h], "local": [16, 16],
//        "args": [{"image": "in", "size": [w, h]}, {"image": "out", "size": [w, h]},
//                 {"int": 5}, {"float": 1.5}, {"float4": [1,2,3,4]},
//                 {"buffer": "in" | "out", "floats": N}, {"local": BYTES}, ...]}
import Foundation
import Metal
import OpenCL

struct Arg {
    enum Kind { case imageIn, imageOut, bufferIn, bufferOut, local, scalar }
    let kind: Kind
    var size = (0, 0)
    var floats = 0
    var localBytes = 0
    var bytes: [UInt8] = []      // scalar value
    var align = 4
    var hostData: [Float] = []   // inputs (random) or outputs (read back)
}

func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

let a = CommandLine.arguments
guard a.count == 4 else { die("usage: kernel-diff CL_DIR METAL_DIR SPEC.json") }
let clDir = a[1], metalDir = a[2]
let spec = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: a[3]))) as! [String: Any]
let file = spec["file"] as! String, kernelName = spec["kernel"] as! String
let global = (spec["global"] as! [Int]), local = (spec["local"] as? [Int]) ?? [16, 16]

// deterministic pseudo-random inputs, roughly scene-referred values
var seed: UInt64 = 0x9E3779B97F4A7C15
func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) * 1.2 }

func scalarBytes<T>(_ v: [T]) -> [UInt8] { v.withUnsafeBytes { Array($0) } }

var args: [Arg] = (spec["args"] as! [[String: Any]]).map { d in
    if let img = d["image"] as? String {
        let s = d["size"] as! [Int]
        var arg = Arg(kind: img == "in" ? .imageIn : .imageOut, size: (s[0], s[1]))
        if img == "in" { arg.hostData = (0..<(s[0] * s[1] * 4)).map { _ in rnd() } }
        return arg
    }
    if let buf = d["buffer"] as? String {
        let n = d["floats"] as! Int
        var arg = Arg(kind: buf == "in" ? .bufferIn : .bufferOut, floats: n)
        arg.hostData = buf == "in" ? (0..<n).map { _ in rnd() } : [Float](repeating: 0, count: n)
        return arg
    }
    if let n = d["local"] as? Int { return Arg(kind: .local, localBytes: n) }
    // scalars and vectors; alignment as Metal lays out struct members
    if let v = d["int"] as? Int { return Arg(kind: .scalar, bytes: scalarBytes([Int32(v)]), align: 4) }
    if let v = d["uint"] as? Int { return Arg(kind: .scalar, bytes: scalarBytes([UInt32(v)]), align: 4) }
    if let v = d["float"] as? Double { return Arg(kind: .scalar, bytes: scalarBytes([Float(v)]), align: 4) }
    if let v = d["int2"] as? [Int] { return Arg(kind: .scalar, bytes: scalarBytes(v.map(Int32.init)), align: 8) }
    if let v = d["float2"] as? [Double] { return Arg(kind: .scalar, bytes: scalarBytes(v.map(Float.init)), align: 8) }
    if let v = d["float4"] as? [Double] { return Arg(kind: .scalar, bytes: scalarBytes(v.map(Float.init)), align: 16) }
    die("unknown arg \(d)")
}

// ---------------------------------------------------------------- OpenCL
func check(_ e: cl_int, _ what: String) { if e != CL_SUCCESS { die("OpenCL \(what): \(e)") } }

func runOpenCL() -> (outputs: [[Float]], ms: Double) {
    var platform: cl_platform_id?; check(clGetPlatformIDs(1, &platform, nil), "platform")
    var device: cl_device_id?; check(clGetDeviceIDs(platform, cl_device_type(CL_DEVICE_TYPE_GPU), 1, &device, nil), "device")
    var err: cl_int = 0
    let ctx = clCreateContext(nil, 1, &device, nil, nil, &err); check(err, "context")
    let queue = clCreateCommandQueue(ctx, device, 0, &err); check(err, "queue")
    let src = try! String(contentsOfFile: "\(clDir)/\(file).cl", encoding: .utf8)
    let prog = src.withCString { p -> cl_program? in
        var ptr: UnsafePointer<CChar>? = p
        return clCreateProgramWithSource(ctx, 1, &ptr, nil, &err)
    }
    check(err, "program")
    // darktable's own options for Apple GPUs
    let opts = "-w -cl-fast-relaxed-math -DAPPLE=1 -I\(clDir)"
    if clBuildProgram(prog, 1, &device, opts, nil, nil) != CL_SUCCESS {
        var len = 0; clGetProgramBuildInfo(prog, device, cl_program_build_info(CL_PROGRAM_BUILD_LOG), 0, nil, &len)
        var log = [CChar](repeating: 0, count: len + 1)
        clGetProgramBuildInfo(prog, device, cl_program_build_info(CL_PROGRAM_BUILD_LOG), len, &log, nil)
        die("OpenCL build failed:\n" + String(cString: log))
    }
    let kernel = clCreateKernel(prog, kernelName, &err); check(err, "kernel \(kernelName)")
    var mems: [cl_mem?] = []
    var format = cl_image_format(image_channel_order: cl_channel_order(CL_RGBA), image_channel_data_type: cl_channel_type(CL_FLOAT))
    for (i, arg) in args.enumerated() {
        switch arg.kind {
        case .imageIn, .imageOut:
            var desc = cl_image_desc(); desc.image_type = cl_mem_object_type(CL_MEM_OBJECT_IMAGE2D)
            desc.image_width = arg.size.0; desc.image_height = arg.size.1
            var data = arg.hostData
            let flags = arg.kind == .imageIn ? cl_mem_flags(CL_MEM_READ_ONLY | CL_MEM_COPY_HOST_PTR) : cl_mem_flags(CL_MEM_WRITE_ONLY)
            let m = data.isEmpty ? clCreateImage(ctx, flags, &format, &desc, nil, &err)
                                 : clCreateImage(ctx, flags, &format, &desc, &data, &err)
            check(err, "image"); mems.append(m)
            var mm = m; check(clSetKernelArg(kernel, cl_uint(i), MemoryLayout<cl_mem>.size, &mm), "arg \(i)")
        case .bufferIn, .bufferOut:
            var data = arg.hostData
            let m = clCreateBuffer(ctx, cl_mem_flags(CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR), arg.floats * 4, &data, &err)
            check(err, "buffer"); mems.append(m)
            var mm = m; check(clSetKernelArg(kernel, cl_uint(i), MemoryLayout<cl_mem>.size, &mm), "arg \(i)")
        case .local:
            mems.append(nil); check(clSetKernelArg(kernel, cl_uint(i), arg.localBytes, nil), "local arg \(i)")
        case .scalar:
            mems.append(nil)
            var b = arg.bytes; check(clSetKernelArg(kernel, cl_uint(i), b.count, &b), "scalar arg \(i)")
        }
    }
    let dims = global.count
    var gsz = (0..<dims).map { d in (global[d] + local[d] - 1) / local[d] * local[d] }
    var lsz = Array(local.prefix(dims))
    let t0 = Date()
    check(clEnqueueNDRangeKernel(queue, kernel, cl_uint(dims), nil, &gsz, &lsz, 0, nil, nil), "enqueue")
    clFinish(queue)
    let ms = Date().timeIntervalSince(t0) * 1000
    var outs: [[Float]] = []
    for (i, arg) in args.enumerated() where arg.kind == .imageOut || arg.kind == .bufferOut || arg.kind == .bufferIn {
        if arg.kind == .imageOut {
            var o = [Float](repeating: 0, count: arg.size.0 * arg.size.1 * 4)
            var origin = [0, 0, 0], region = [arg.size.0, arg.size.1, 1]
            check(clEnqueueReadImage(queue, mems[i], cl_bool(CL_TRUE), &origin, &region, 0, 0, &o, 0, nil, nil), "read image")
            outs.append(o)
        } else if arg.kind == .bufferOut {
            var o = [Float](repeating: 0, count: arg.floats)
            check(clEnqueueReadBuffer(queue, mems[i], cl_bool(CL_TRUE), 0, arg.floats * 4, &o, 0, nil, nil), "read buffer")
            outs.append(o)
        }
    }
    return (outs, ms)
}

// ----------------------------------------------------------------- Metal
func runMetal() -> (outputs: [[Float]], ms: Double) {
    let device = MTLCreateSystemDefaultDevice()!
    let src = try! String(contentsOfFile: "\(metalDir)/\(file).metal", encoding: .utf8)
    let opts = MTLCompileOptions(); opts.mathMode = .fast
    let lib = try! device.makeLibrary(source: src, options: opts)
    guard let fn = lib.makeFunction(name: kernelName) else { die("no Metal function \(kernelName)") }
    let pipeline = try! device.makeComputePipelineState(function: fn)
    let map = (try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(metalDir)/\(file).json"))) as! [String: Any])[kernelName] as! [[String: Any]]
    let queue = device.makeCommandQueue()!, cmd = queue.makeCommandBuffer()!, enc = cmd.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pipeline)

    // scalars go into one struct, laid out with Metal's alignment rules
    var argStruct: [UInt8] = [], maxAlign = 4
    var textures: [Int: MTLTexture] = [:], buffers: [Int: MTLBuffer] = [:]
    for (i, arg) in args.enumerated() {
        let m = map[i]
        switch arg.kind {
        case .imageIn, .imageOut:
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: arg.size.0, height: arg.size.1, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
            let t = device.makeTexture(descriptor: d)!
            if arg.kind == .imageIn {
                arg.hostData.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, arg.size.0, arg.size.1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: arg.size.0 * 16) }
            }
            textures[i] = t; enc.setTexture(t, index: m["slot"] as! Int)
        case .bufferIn, .bufferOut:
            let b = arg.hostData.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: arg.floats * 4, options: .storageModeShared)! }
            buffers[i] = b; enc.setBuffer(b, offset: 0, index: m["slot"] as! Int)
        case .local:
            enc.setThreadgroupMemoryLength((arg.localBytes + 15) / 16 * 16, index: m["slot"] as! Int)
        case .scalar:
            while argStruct.count % arg.align != 0 { argStruct.append(0) }
            argStruct += arg.bytes; maxAlign = max(maxAlign, arg.align)
        }
    }
    if !argStruct.isEmpty {
        while argStruct.count % maxAlign != 0 { argStruct.append(0) }
        enc.setBytes(argStruct, length: argStruct.count, index: 0)
    }
    // whole threadgroups, as OpenCL runs with the global size rounded up
    let groups = MTLSize(width: (global[0] + local[0] - 1) / local[0],
                         height: global.count > 1 ? (global[1] + local[1] - 1) / local[1] : 1, depth: 1)
    enc.dispatchThreadgroups(groups, threadsPerThreadgroup: MTLSize(width: local[0], height: global.count > 1 ? local[1] : 1, depth: 1))
    enc.endEncoding()
    let t0 = Date(); cmd.commit(); cmd.waitUntilCompleted()
    let ms = Date().timeIntervalSince(t0) * 1000
    if let e = cmd.error { die("Metal: \(e)") }
    var outs: [[Float]] = []
    for (i, arg) in args.enumerated() {
        if arg.kind == .imageOut {
            var o = [Float](repeating: 0, count: arg.size.0 * arg.size.1 * 4)
            o.withUnsafeMutableBytes { textures[i]!.getBytes($0.baseAddress!, bytesPerRow: arg.size.0 * 16, from: MTLRegionMake2D(0, 0, arg.size.0, arg.size.1), mipmapLevel: 0) }
            outs.append(o)
        } else if arg.kind == .bufferOut {
            let p = buffers[i]!.contents().bindMemory(to: Float.self, capacity: arg.floats)
            outs.append(Array(UnsafeBufferPointer(start: p, count: arg.floats)))
        }
    }
    return (outs, ms)
}

let cl = runOpenCL(), mt = runMetal()
var worst = 0.0
for (k, (o1, o2)) in zip(cl.outputs, mt.outputs).enumerated() {
    var maxAbs: Float = 0, sum: Double = 0, bad = 0, nan1 = 0, nan2 = 0
    for (x, y) in zip(o1, o2) {
        if x.isNaN { nan1 += 1 }; if y.isNaN { nan2 += 1 }
        if x.isNaN || y.isNaN { continue }
        let d = abs(x - y); maxAbs = max(maxAbs, d); sum += Double(d)
        if d > 1e-3 * max(1, abs(x)) { bad += 1 }
    }
    let mean = sum / Double(o1.count)
    worst = max(worst, Double(bad) / Double(o1.count))
    print(String(format: "%@ output %d: %d values, mean |diff| %.2e, max |diff| %.2e, %d differ by >0.1%% (NaN: OpenCL %d, Metal %d)",
                 kernelName, k, o1.count, mean, maxAbs, bad, nan1, nan2))
}
print(String(format: "%@: OpenCL %.2f ms, Metal %.2f ms (single run, includes first-use overhead)", kernelName, cl.ms, mt.ms))
exit(worst < 0.001 ? 0 : 2)
