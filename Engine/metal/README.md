# Metal backend: scoping

Goal: run darktable's GPU code on Metal instead of Apple's deprecated OpenCL, without changing darktable's modules.

## Why it's tractable

- **One narrow interface.** Modules reach the GPU only through darktable's own `dt_opencl_*` functions in `src/common/opencl.c` (4,300 lines, 85 functions, about 45 used much). No module calls OpenCL directly. A Metal implementation of that interface leaves all 73 GPU-capable modules untouched.
- **Kernels translate automatically.** `cl2metal.py` turns all 42 kernel files (328 kernels) into Metal Shading Language, and every one compiles with the Metal framework's runtime compiler. darktable's sources need no hand edits.

## What the translator does

- Rewrites OpenCL vector literals and casts, `(float4)(a, b, c, d)`, to Metal constructors.
- Rewrites kernel signatures to Metal arguments: images become textures, buffers become `device` pointers, local memory becomes `threadgroup`. Scalars are packed into one argument struct per kernel, which is a single `setBytes` and avoids Metal's 31-buffer limit. Pointer-to-array arguments, like the X-Trans pattern, are rebuilt in the kernel body.
- Makes OpenCL's implicit private pointers explicit (`thread`), and turns enum typedefs into `int`, because C++ won't convert int to enum.
- Inlines the shared headers.
- Provides OpenCL built-ins in `cl_compat.h`: samplers, image reads and writes, `native_*` maths, conversions, `vload`/`vstore`, and 32-bit atomics.
- Makes compiler-guided fix-ups. Where the fix depends on expression types (vector `?:` to `select()`, missing address spaces, address-space casts, narrowing), it compiles, reads the errors' line and column, and rewrites exactly there. One round fixes about 150 sites.
- Writes a JSON argument map per kernel, which the host side needs because Metal binds textures, buffers and threadgroup memory in separate slot spaces.

## Validation so far

`kernel-diff.swift` runs one kernel through Apple's OpenCL (original source, darktable's compile options) and through Metal (the translation) on identical inputs, and compares every value.

| Kernel | Exercises | Result |
| --- | --- | --- |
| `exposure` | per-pixel image maths, scalar arguments | identical |
| `gaussian_column_4c` | buffers, unsigned arguments, recursive filter | max difference 6e-8 |
| `splat` (bilateral) | local memory, barriers, atomics | max difference 2e-6 (atomic order) |
| `clip_rotate_bilinear` | bilinear sampling, mixed int2, float2 and float4 arguments | mean 8e-6, max 5e-3 |

The rotate residual comes from hardware texture filtering. darktable's OpenCL path on Apple GPUs uses the hardware filter too, and an exact software blend moved further from it, not closer. It's kept on hardware filtering; `read_imagef_linear` in `cl_compat.h` is there if exactness against the CPU path matters more.

## Plan

1. **Host interface.** Implement the `dt_opencl_*` functions on Metal in a new `metal.m`, selected at build time:
   - images become `MTLTexture`
   - buffers become shared-storage `MTLBuffer` (unified memory makes host copies cheap)
   - kernels are looked up through `programs.conf` in libraries compiled at first launch and cached with `MTLBinaryArchive`
   - arguments are bound through the argument maps, recognising memory objects by handle
   - finish and events map to command buffer commit and wait

   darktable's tiling code and memory heuristics stay as they are. This is the bulk of the work: a few weeks for the 45 commonly used functions.
2. **Translator at build time.** Run `cl2metal.py` in `fetch-engine.sh` and bundle the `.metal` and `.json` files, or precompiled `.metallib` once the Metal toolchain is installed (`xcodebuild -downloadComponent MetalToolchain`).
3. **Module-level validation.** Extend the comparison from single kernels to whole modules: render the same edit with the OpenCL and Metal backends and diff the pipeline output, module by module. Kernels with float atomics (such as the histogram ones) need checking for ordering effects.
4. **Upstream.** The interface boundary is clean enough that this could be offered to darktable as an optional macOS backend.

## MetalCL: darktable's OpenCL path on Metal

`Engine/metalcl/metalcl.m` builds `libMetalCL.dylib`, which implements the 40 OpenCL 1.2 functions darktable loads with `dlopen` (`src/common/dlopencl.c`) on top of Metal. darktable is pointed at it with its `opencl_library` conf key and runs its GPU path unchanged: no darktable source is modified. This replaces step 1 of the plan above with a shim one level lower, below `dt_opencl_*` instead of in place of it.

How it works:

- It reports one GPU device, "<GPU name> (Metal)", on a platform called "Apple" (so darktable's `clplatform_apple` switch applies), OpenCL 1.2, vendor id Apple, so darktable compiles with `-DAPPLE=1`. Memory sizes come from `recommendedMaxWorkingSetSize` and `maxBufferLength`, images go up to 16384 square, local memory is 32 KiB and the work-group limit is the device's.
- Programs: the source darktable passes is matched byte for byte against the `.cl` files in the `-I` directory of its build options. The translation of that file is loaded from `$DT_METALCL_KERNELS`, else `<kerneldir>/../metal-kernels`, and compiled in the background as soon as darktable builds the program, so start-up doesn't wait for 42 compiles. darktable's binary cache stores a tiny "binary", `metalcl1:<name>`, which is accepted back.
- Kernels: one compute pipeline per kernel name. The scalar struct layout comes from Metal's reflection of buffer 0, so it is exact for every type, including structs and enums. `clSetKernelArg` checks each argument against the argument map and returns OpenCL's errors. NULL buffers and images are bound to small dummies.
- Memory: buffers are shared-storage `MTLBuffer`s, so maps return their own memory. Images are private `MTLTexture`s (R, RG, RGBA in float, half, 8-, 16- and 32-bit unsigned, 8- and 16-bit unorm); all host transfers go through staging buffers and blits, so writes never block.
- Queue: in order. Commands are encoded into one open command buffer, one compute encoder for runs of kernels, and committed at once when the GPU has run dry, after 4 commands at most, and whenever the host waits (blocking reads, maps, `clFinish`, `clWaitForEvents`). Kernels with a local size use `dispatchThreadgroups` with the global size rounded up, as OpenCL does; without one, `dispatchThreads` with 16x16 (2D) or 256 (1D) threadgroups.
- Events are real objects tied to their command buffer; with darktable's `-d perf` (profiling queue) every command gets its own command buffer and events carry its GPU start and end times.
- Maths: Metal's relaxed mode with precise functions, which honours NaN and infinity like OpenCL without `-cl-fast-relaxed-math` (darktable's default); fast maths when darktable asks for it. Rendering time is the same either way.
- One lock guards shared state; waits for the GPU happen outside it. Every handle given out is registered, so a stale handle gets an OpenCL error rather than a crash.

Build and select:

```
Engine/metal/translate.sh        # only after changing the translator or cl_compat.h
Engine/metalcl/build.sh          # vendor/metalcl/libMetalCL.dylib, and copies the kernels to
                                 # vendor/dt-install/share/darktable/metal-kernels
darkroom-helper ... -- --conf opencl=TRUE \
  --conf opencl_library=$PWD/vendor/metalcl/libMetalCL.dylib
```

Environment: `DT_METALCL_KERNELS` (translation directory), `DT_METALCL_MATH=fast|relaxed|safe`, `DT_METALCL_BATCH=N` (commands per command buffer at most), `DT_METALCL_DEBUG=1` (logs builds and compile times).

### Fixes found on the way

- Translator: `(const float4)(a, b, c, d)` was left as a C++ cast, so the comma operator broadcast `d`. It broke `colorin` (every pixel NaN) and `rawprepare_4f`. The vector-literal rewrite now drops the `const`.
- `cl_compat.h`: image writes outside the image are now skipped. OpenCL drops them; on Metal they're undefined.
- MetalCL itself: kernels must not retain their arguments (it kept every kernel's last images alive and pushed full-size renders into swap).

### Validation

MacBook Pro, M3 Pro. Sample `_DSC0009.ARW` (Sony A7 III), rendered by `darkroom-helper` at 1400 px, three ways: CPU, Apple's OpenCL and MetalCL. "Heavy" adds denoise (profiled, wavelets), local contrast and the diffuse or sharpen module at 8 iterations. Times are the helper's render ms: the first render, then the minimum and median of six full re-renders in the same session (an HDR toggle flushes the pipe cache in between).

| Edit | Backend | First | Warm min | Warm median |
| --- | --- | --- | --- | --- |
| default | CPU | 216 | 171 | 176 |
| default | Apple OpenCL | 172 | 158 | 161 |
| default | MetalCL | 144 | 135 | 136 |
| heavy | CPU | 865 | 700 | 781 |
| heavy | Apple OpenCL | 453 | 271 | 304 |
| heavy | MetalCL | 237 | 212 | 223 |
| heavy, full size 6048x4024 | Apple OpenCL | 4992 | 4549 | |
| heavy, full size 6048x4024 | MetalCL | 3175 | 3529 | |

Final 8-bit frames, mean and max absolute difference in levels, and the share of samples more than 2 levels apart:

| Comparison | Default | Heavy |
| --- | --- | --- |
| MetalCL vs Apple OpenCL | 0.00005, max 1, 0% | 0.00008, max 1, 0% |
| MetalCL vs CPU | 0.00004, max 1, 0% | 0.039, max 26, 0.087% |
| Apple OpenCL vs CPU | 0.00004, max 1, 0% | 0.039, max 26, 0.087% |

The heavy CPU difference is the same for both GPU backends: it's diffuse and local contrast behaving differently on GPU and CPU, not MetalCL. Full size: MetalCL vs Apple mean 0.0001, max 3.

`-d opencl -d pipe` shows darktable initialising the MetalCL device and every GPU-capable module in these edits running on it (`CL0`), with no CPU fallbacks and no MetalCL errors. Kernel loading at start-up takes 0.02 s against Apple's 1.8 s (compiles run in the background; the first render waits only for the programs it uses).

Module by module (darktable's `--dump-pipe`, float output of each module, MetalCL vs Apple OpenCL) over five edits covering about 60 modules: rawprepare, temperature, highlights (opposed, clip, LCh), demosaic (RCD, PPG with green equilibration, colour smoothing and median, VNG4), denoiseprofile (wavelets, non-local means, auto), exposure, colorin, channelmixerrgb, sigmoid, filmic, filmicrgb, agx, basecurve, rgbcurve, rgblevels, tonecurve, levels, colorbalance, colorbalancergb, colorequal, colorharmonizer, colorzones, colorcorrection, colorcontrast, colorize, colorchecker, colorreconstruct, vibrance, velvia, splittoning, monochrome, lowlight, basicadj, colisa, globaltonemap, shadhi, bilat (local contrast), atrous, nlmeans, highpass, lowpass, sharpen, blurs, soften, bloom, vignette, graduatednd, hazeremoval, diffuse, lens, ashift, flip, crop, primaries, zonesystem, invert, borders, channelmixer. All agree to float rounding: mean differences of 1e-9 to 1e-6 relative to the signal, maxima at single pixels where hardware bilinear filtering or relaxed maths differ by a few 1e-4.

One mismatch is darktable's: highlights "guided laplacians" copies `&clips` where `clips` is a pointer parameter (`src/iop/hlreconstruct/laplacian.c`), so the GPU clip thresholds are stack garbage. Its output differs from run to run on Apple's OpenCL too.

Kernel by kernel, every one of the 328 kernels without local memory or integer images (275) was run through both libraries with generated inputs: 269 agree, the other 6 only differ where the generated inputs are meaningless (garbage profile structs, random LUTs, a 1D kernel run in 2D) and agree with realistic inputs. Of the 53 skipped, all but the X-Trans demosaic, raw overexposure indicators, inpainting masks and gain-map raw preparation ran in the darktable renders above.

Not covered yet: X-Trans files (Markesteijn), blending in a real edit (the helper can't set blend modes or masks; the blendop kernels themselves pass the kernel comparison), and `MTLBinaryArchive` caching of compiled pipelines across launches (Metal's own shader cache makes later launches fast; the very first one compiles everything, about 4 s).

## Tools

- `cl2metal.py KERNEL_DIR OUT_DIR` translates; `cl2metal.py --fixup OUT_DIR errors.json` applies fix-ups.
- `compile-test.swift DIR [--errors N] [--json FILE]` compiles every translated file through Metal.
- `kernel-diff.swift CL_DIR METAL_DIR SPEC.json` compares one kernel between OpenCL and Metal.
