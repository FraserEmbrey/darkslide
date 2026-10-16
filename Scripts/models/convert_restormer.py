"""Convert a Restormer deblurring model (Zamir et al., CVPR 2022; MIT
licence), defocus or motion, to Core ML, for Rescue Focus: 512 px tiles, half
precision, on the GPU. Core ML's converter can't follow the einops reshapes
in spandrel's copy of the architecture, so the layer norm and attention are
redone with plain tensor ops (the same maths; checked against the original)
and each attention's input size is fixed at the tile's."""
import sys, numpy as np, torch, coremltools as ct, spandrel, spandrel_extra_arches

spandrel_extra_arches.install(ignore_duplicates=True)
from spandrel_extra_arches.architectures.Restormer.__arch import restormer_arch as R

src, dst, kind = sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "single-image defocus"
TILE = 512


def norm_forward(self, x):
    # over the channels, without reshaping
    b = self.body
    mu = x.mean(1, keepdim=True)
    var = (x - mu).pow(2).mean(1, keepdim=True)
    w = b.weight.view(1, -1, 1, 1)
    if isinstance(b, R.BiasFree_LayerNorm):
        return x / torch.sqrt(var + 1e-5) * w
    return (x - mu) / torch.sqrt(var + 1e-5) * w + b.bias.view(1, -1, 1, 1)


def attn_forward(self, x):
    heads = self.num_heads
    per = self.project_out.in_channels // heads
    q, k, v = self.qkv_dwconv(self.qkv(x)).chunk(3, dim=1)
    q = torch.nn.functional.normalize(q.reshape(1, heads, per, -1), dim=-1)
    k = torch.nn.functional.normalize(k.reshape(1, heads, per, -1), dim=-1)
    v = v.reshape(1, heads, per, -1)
    attn = ((q @ k.transpose(-2, -1)) * self.temperature).softmax(dim=-1)
    return self.project_out((attn @ v).reshape(getattr(self, "fixed_shape", x.shape)))


original = spandrel.ModelLoader().load_from_file(src).model.eval()
x = torch.rand(1, 3, TILE, TILE)
with torch.no_grad():
    ref = original(x).numpy()
R.LayerNorm.forward = norm_forward
R.Attention.forward = attn_forward
net = spandrel.ModelLoader().load_from_file(src).model.eval()


def record(m, args):
    m.fixed_shape = tuple(int(d) for d in args[0].shape)


hooks = [m.register_forward_pre_hook(record) for m in net.modules() if isinstance(m, R.Attention)]
with torch.no_grad():
    patched = net(x).numpy()
    for h in hooks:
        h.remove()
    traced = torch.jit.trace(net, x)
assert np.abs(patched - ref).max() < 1e-4, "the rewritten layers differ from the original"

model = ct.convert(traced, inputs=[ct.TensorType(name="input", shape=x.shape)], outputs=[ct.TensorType(name="output")],
                   convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
                   minimum_deployment_target=ct.target.macOS15)
model.short_description = f"Restormer {kind} deblurring (Zamir et al., CVPR 2022, MIT licence)"
model.save(dst)
out = model.predict({"input": x.numpy()})["output"]
print(f"converted {dst}: max difference from PyTorch {float(np.abs(out - ref).max()):.4f}")
