"""Converts a darktable-ai ONNX model to Core ML: ONNX, then PyTorch (onnx2torch), then coremltools.
Checks the result against ONNX Runtime on random input.
Usage: convert.py <model.onnx> <out.mlpackage> [fp32]"""
import sys, os, time, numpy as np, onnx, torch, coremltools as ct, onnxruntime as ort
from onnx2torch import convert
src, dst = sys.argv[1], sys.argv[2]
fp32 = len(sys.argv) > 3 and sys.argv[3] == "fp32"
m = onnx.load(src)
if m.opset_import[0].version > 17:
    from onnx import version_converter
    m = version_converter.convert_version(m, 17)
# onnx2torch has no Constant for opset 19+: turn them into initializers
for n in [n for n in m.graph.node if n.op_type == "Constant" and n.attribute[0].name == "value"]:
    t = n.attribute[0].t; t.name = n.output[0]
    m.graph.initializer.append(t); m.graph.node.remove(n)
shape = [d.dim_value for d in m.graph.input[0].type.tensor_type.shape.dim]
net = convert(m).eval()
x = torch.rand(*shape)
with torch.no_grad():
    traced = torch.jit.trace(net, x)
    tout = net(x).numpy()
    ref = ort.InferenceSession(src, providers=["CPUExecutionProvider"]).run(None, {"input": x.numpy()})[0]
mlm = ct.convert(traced, inputs=[ct.TensorType(name="input", shape=shape)], outputs=[ct.TensorType(name="output")],
                 convert_to="mlprogram", compute_precision=ct.precision.FLOAT32 if fp32 else ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS15)
mlm.save(dst)
t = time.time(); out = mlm.predict({"input": x.numpy()})["output"]; dt = time.time() - t
print(os.path.basename(dst), shape, "range", float(ref.min()), float(ref.max()), "torch diff", float(np.abs(tout - ref).max()), "max diff vs onnx", float(np.abs(out - ref).max()), "mean", float(np.abs(out - ref).mean()), f"{dt:.2f}s")
