import sys, time, torch, numpy as np, coremltools as ct, spandrel, spandrel_extra_arches
spandrel_extra_arches.install()
src, out, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
m = spandrel.ModelLoader().load_from_file(src).model.eval()
img = torch.rand(1, 3, size, size); mask = (torch.rand(1, 1, size, size) > 0.8).float()
with torch.no_grad():
    t = time.time(); ref = m(img, mask); print("torch", ref.shape, round(time.time() - t, 2), "s")
    traced = torch.jit.trace(m, (img, mask))
ml = ct.convert(traced, inputs=[ct.TensorType(name="image", shape=img.shape), ct.TensorType(name="mask", shape=mask.shape)],
                outputs=[ct.TensorType(name="output")], minimum_deployment_target=ct.target.macOS15,
                compute_precision=ct.precision.FLOAT16)
ml.save(out)
pred = ml.predict({"image": img.numpy(), "mask": mask.numpy()})["output"]
print("max diff vs torch", float(np.abs(pred - ref.numpy()).max()), "mean", float(np.abs(pred - ref.numpy()).mean()))
