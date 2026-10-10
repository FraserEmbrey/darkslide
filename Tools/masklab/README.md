# Mask lab

Compares subject and object masks on the same photos and clicks: Apple Vision
(subject and person masks), Apple's Core ML SAM 2.1 (small, base+), and
darktable 5.6's ONNX models (SAM 2.1 small, SegNext ViT-B HQ). Makes a contact
sheet with each model's mask and its time.

Models aren't kept in the repo. Put them in a models folder:
- `apple-sam21-small`, `apple-sam21-baseplus`: `huggingface_hub.snapshot_download("apple/coreml-sam2.1-<size>")`
- `mask-object-sam21-small`, `mask-object-segnext-b2hq`: unzip the `.dtmodel` files from
  `gh release download nightly-5.7.0 -R darktable-org/darktable-ai`

Then, with a Python environment holding onnxruntime, numpy and pillow:

    swiftc -O Tools/masklab/AppleRunner.swift -o apple-runner
    ./apple-runner <images> prompts.json <models> <out>
    python3 Tools/masklab/onnx_runner.py <images> prompts.json <models> <out>
    python3 Tools/masklab/sheet.py <images> prompts.json <out> sheet.jpg

`prompts.json` maps each photo to its clicks: `{"photo.jpg": [{"name": "sky", "x": 800, "y": 80}]}`,
in the photo's pixels.
