# Inpainting lab

A look at machine-learning object removal, beside darktable's retouch (Darkslide's spot removal). LaMa ("big-lama", Samsung, Apache-2.0), converted to Core ML, fills elliptical masks on a photo, as an object-removal tool would.

Get the weights and convert them (the model venv from `Scripts/fetch-models.sh` has spandrel, which loads LaMa):

    curl -fsSLo .build/models/big-lama.pt https://github.com/Sanster/models/releases/download/add_big_lama/big-lama.pt
    .build/model-venv/bin/python -I Tools/inpaintlab/convert_lama.py .build/models/big-lama.pt LaMa512.mlpackage 512

Then:

    swiftc -O Tools/inpaintlab/InpaintRunner.swift -o inpaint-runner
    ./inpaint-runner photo.jpg LaMa512.mlpackage out.jpg x,y,w,h [x,y,w,h …]

`INPAINT_CONTEXT` sets the square cut out around each mask as a multiple of its size (3 by default), `INPAINT_SIZE` the model's side, and `INPAINT_DEBUG=<folder>` writes each crop, mask and output.

## What it showed (October 2026, M3 Pro, a 24 MP Sony raw exported at full size)

- **It converts and runs.** Half precision at 512 × 512 matches PyTorch to a mean of 0.0003 and is 99 MB. A fill takes 0.25 to 0.6 s once the Neural Engine is warm; the first takes longer.
- **Medium objects are good.** Two plant pots on a roof, about 350 px across, came out convincingly: the roof's seams carried on through and the branches over them stayed. That's with a square three times the object's size, scaled to half to fit 512.
- **Large or long objects are soft.** LaMa needs that context, so the square for a 630 px lamp post was scaled to a quarter, and the fill was blocky and smeared. A tighter square kept more resolution but gave it too little to go on: worse for both objects.
- **1024 doesn't work in half precision.** The output overflows to black with coloured specks, and at 18 to 28 s a fill it wasn't running on the Neural Engine anyway. Full precision would mean the GPU and seconds per fill.

## How it could fit

darktable has no way to hold pixels from a model in an edit: the sidecar can only describe darktable's own modules. So a model's fill would be either:

1. **A clean-up layer kept by Darkslide**: the masks in the catalog (as AI denoise's amount is), the fill run again on each final render around the masks and laid over darktable's output, in the editor and in exports. darktable wouldn't see it. At half a second a mask it's fast enough for that, cached between renders.
2. **Baked into a new file**, as Denoise to New DNG does: a TIFF or DNG with the objects gone, edited from then on. Simple and permanent, but it isn't raw any more after the fill.

Either way it's for objects, with darktable's heal and clone kept for spots and dust, where they're sharper and stay a darktable edit. For large objects, the next things to try are LaMa's refinement pass (as IOPaint does it), MI-GAN (a lighter model built for phones), and MAT (larger holes; its licence needs checking before it's an option).
