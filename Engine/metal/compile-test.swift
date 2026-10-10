// Compiles every translated .metal file with the Metal framework's runtime
// compiler (no Metal toolchain needed) and reports kernels that compile.
// usage: swift compile-test.swift DIR [--errors N]
import Foundation
import Metal

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let showErrors = CommandLine.arguments.firstIndex(of: "--errors").map { Int(CommandLine.arguments[$0 + 1])! } ?? 0
let jsonOut = CommandLine.arguments.firstIndex(of: "--json").map { CommandLine.arguments[$0 + 1] }
var allErrors: [[String: Any]] = []
let device = MTLCreateSystemDefaultDevice()!
let files = try! FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "metal" }.sorted { $0.path < $1.path }
var okFiles = 0, okKernels = 0, totalKernels = 0
var failures: [(String, String)] = []
for f in files {
    let src = try! String(contentsOf: f, encoding: .utf8)
    let json = f.deletingPathExtension().appendingPathExtension("json")
    let kernels = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: json))) as? [String: Any])?.keys.count ?? 0
    totalKernels += kernels
    let opts = MTLCompileOptions()
    opts.mathMode = .fast
    do {
        let lib = try device.makeLibrary(source: src, options: opts)
        okFiles += 1; okKernels += lib.functionNames.count
    } catch {
        failures.append((f.lastPathComponent, "\(error)"))
        // "program_source:LINE:COL: error: message"
        for line in "\(error)".components(separatedBy: "\n") where line.contains(": error: ") {
            let parts = line.components(separatedBy: ":")
            if parts.count > 3, let l = Int(parts[1]), let c = Int(parts[2]) {
                allErrors.append(["file": f.lastPathComponent, "line": l, "col": c,
                                  "message": line.components(separatedBy: ": error: ").last ?? ""])
            }
        }
    }
}
if let jsonOut {
    try! JSONSerialization.data(withJSONObject: allErrors).write(to: URL(fileURLWithPath: jsonOut))
}
print("files: \(okFiles)/\(files.count) compile; kernels in compiled files: \(okKernels)/\(totalKernels)")
for (name, err) in failures {
    let errs = err.components(separatedBy: "\n").filter { $0.contains("error:") }
    print("✗ \(name): \(errs.count) errors")
    for e in errs.prefix(showErrors) { print("    " + (e.components(separatedBy: "error: ").last ?? e).prefix(160)) }
}
