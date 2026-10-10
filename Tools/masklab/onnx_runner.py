#!/usr/bin/env python3
"""Mask lab: darktable's AI mask models for each test photo and click.

    dt-sam-small   SAM 2.1 small, as darktable 5.6 runs it (ONNX)
    dt-segnext     SegNext ViT-B HQ, as darktable runs it (ONNX)

Preparation follows darktable's src/common/ai/segmentation.c: the photo
resized so its long side is 1024 and padded, ImageNet-normalised for SAM and
0..1 for SegNext; clicks in that scale, SAM with its (0, 0, -1) padding point;
SAM's best-scoring mask. darktable then upsamples with a joint bilateral
filter (edge-aware); this uses plain bilinear, as the Apple runner does.

Usage: onnx_runner.py <images dir> <prompts.json> <models dir> <out dir>
"""
import json
import os
import sys
import time

import numpy as np
import onnxruntime as ort
from PIL import Image

images_dir, prompts_file, models_dir, out_dir = sys.argv[1:5]
prompts = json.load(open(prompts_file))
os.makedirs(out_dir, exist_ok=True)
MEAN = np.array([123.675, 116.28, 103.53], dtype=np.float32)
STD = np.array([58.395, 57.12, 57.375], dtype=np.float32)


def log(photo, prompt, model, seconds, note=""):
    with open(os.path.join(out_dir, "timings.jsonl"), "a") as f:
        f.write(json.dumps({"photo": photo, "prompt": prompt, "model": model, "seconds": round(seconds, 3), "note": note}) + "\n")


def prepare(img, normalise):
    w, h = img.size
    scale = 1024 / max(w, h)
    nw, nh = min(round(w * scale), 1024), min(round(h * scale), 1024)
    small = np.asarray(img.resize((nw, nh), Image.BILINEAR), dtype=np.float32)
    x = (small - MEAN) / STD if normalise else small / 255
    out = np.zeros((1024, 1024, 3), dtype=np.float32)
    out[:nh, :nw] = x
    return out.transpose(2, 0, 1)[None], scale, nw, nh


def to_photo(mask_sq, scale, nw, nh, w, h):
    """a mask over the padded 1024 square (any resolution) back to the photo"""
    m = Image.fromarray(mask_sq.astype(np.float32))
    m = m.resize((1024, 1024), Image.BILINEAR)
    m = np.asarray(m)[:nh, :nw]
    return np.asarray(Image.fromarray(m).resize((w, h), Image.BILINEAR))


models = {
    "dt-sam-small": ("mask-object-sam21-small", True),
    "dt-segnext": ("mask-object-segnext-b2hq", False),
}
opts = ort.SessionOptions()
for name, (folder, is_sam) in models.items():
    path = os.path.join(models_dir, folder)
    if not os.path.isdir(path):
        continue
    enc = ort.InferenceSession(os.path.join(path, "encoder.onnx"), opts, providers=["CPUExecutionProvider"])
    dec = ort.InferenceSession(os.path.join(path, "decoder.onnx"), opts, providers=["CPUExecutionProvider"])
    for photo in sorted(prompts):
        img = Image.open(os.path.join(images_dir, photo)).convert("RGB")
        w, h = img.size
        base = os.path.splitext(photo)[0]
        x, scale, nw, nh = prepare(img, is_sam)
        t = time.time()
        feats = dict(zip([o.name for o in enc.get_outputs()], enc.run(None, {"image": x})))
        log(base, "-", name + "-encode", time.time() - t)
        for p in prompts[photo]:
            px, py = p["x"] * scale, p["y"] * scale
            t = time.time()
            if is_sam:
                out = dec.run(None, {
                    "image_embed": feats["image_embed"], "high_res_feats_0": feats["high_res_feats_0"],
                    "high_res_feats_1": feats["high_res_feats_1"],
                    "point_coords": np.array([[[px, py], [0, 0]]], dtype=np.float32),
                    "point_labels": np.array([[1, -1]], dtype=np.float32),
                    "mask_input": np.zeros((1, 1, 256, 256), dtype=np.float32),
                    "has_mask_input": np.zeros((1,), dtype=np.float32),
                })
                masks, scores = out[0][0], out[1][0]
                logits = masks[int(np.argmax(scores))]
            else:
                out = dec.run(None, {
                    "image_feats": feats["image_feats"],
                    "point_coords": np.array([[[px, py]]], dtype=np.float32),
                    "point_labels": np.array([[1]], dtype=np.float32),
                    "prev_mask": np.zeros((1, 1, 1024, 1024), dtype=np.float32),
                })
                logits = out[0][0][0]
            seconds = time.time() - t
            m = to_photo(logits, scale, nw, nh, w, h)
            # SAM gives logits (0 is the edge); SegNext a probability (0.5)
            edge = 0.0 if is_sam else (0.5 if logits.min() >= 0 and logits.max() <= 1 else 0.0)
            Image.fromarray(((m > edge) * 255).astype(np.uint8)).save(
                os.path.join(out_dir, f"{base}__{p['name']}__{name}.png"))
            log(base, p["name"], name, seconds)
        print("done", name, photo, flush=True)
