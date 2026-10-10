# Patches to darktable 5.6.2

Applied in order by `Engine/fetch-engine.sh` to a fresh source tree.

| Patch | What | Status |
| --- | --- | --- |
| `0001-screen-pipe-float-backbuf.patch` | Lets the darkroom pipe return float output, so the HDR preview gets full precision instead of 8 bits. | Ours. Could be offered upstream. |
| `0002-laplacian-opencl-clips.patch` | Guided laplacians highlight reconstruction on the GPU uploaded `&clips`, the address of a pointer parameter, as its clip thresholds (`src/iop/hlreconstruct/laplacian.c`), so the thresholds were stack contents and results varied between runs. Found while validating MetalCL. | Fixed upstream on 2026-10-09 in [ac9c9ac](https://github.com/darktable-org/darktable/commit/ac9c9ac19905cbef8a77d180285d4a9421fbdaad), with five related fixes that need code added after 5.6.2. Only the one-line clip fix is backported. Drop when moving to a release that includes ac9c9ac. |
| `0003-headless-input-cache-hint.patch` | On the GPU, a module's output stays in GPU memory and is only copied into the pipe cache for the module focused in darktable's interface (`important_cl_input`, which needs `gui_attached`). Headless, nothing was cached, so every edit reran the whole pipe from the raw. Adds `input_hint` to the pipe: the helper sets it to the module being edited, and its input is cached and kept, as darktable does for the focused module. | Ours. Only matters headless. |
