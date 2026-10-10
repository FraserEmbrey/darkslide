#!/usr/bin/env python3
"""Mask lab: one contact sheet of every model's mask for every click.

A row per photo and click: the photo with the click marked, then each model's
mask tinted over it, with the time it took (and, for SAM, the one-off
encoding time of the photo).

Usage: sheet.py <images dir> <prompts.json> <out dir> <sheet.jpg>
"""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

images_dir, prompts_file, out_dir, sheet_path = sys.argv[1:5]
prompts = json.load(open(prompts_file))
MODELS = ["vision-subject", "vision-person", "apple-sam-small", "apple-sam-baseplus", "dt-sam-small", "dt-segnext"]
times = {}
for line in open(os.path.join(out_dir, "timings.jsonl")):
    t = json.loads(line)
    times[(t["photo"], t["prompt"], t["model"])] = t

TILE = 300
rows = []
for photo in sorted(prompts):
    base = os.path.splitext(photo)[0]
    img = Image.open(os.path.join(images_dir, photo)).convert("RGB")
    for p in prompts[photo]:
        tiles = []
        first = img.copy()
        d = ImageDraw.Draw(first)
        r = max(img.size) / 80
        d.ellipse([p["x"] - r, p["y"] - r, p["x"] + r, p["y"] + r], outline="yellow", width=max(2, int(r / 3)))
        tiles.append((first, f"{base[-8:]} · {p['name']}"))
        for m in MODELS:
            path = os.path.join(out_dir, f"{base}__{p['name']}__{m}.png")
            if not os.path.exists(path):
                tiles.append((Image.new("RGB", img.size, "grey"), f"{m}: none"))
                continue
            mask = Image.open(path).convert("L")
            a = np.asarray(mask, dtype=np.float32) / 255
            base_px = np.asarray(img, dtype=np.float32)
            tint = base_px * (1 - 0.55 * a[..., None]) + np.array([255, 40, 40]) * 0.55 * a[..., None]
            out = Image.fromarray(tint.clip(0, 255).astype(np.uint8))
            edge = mask.filter(ImageFilter.FIND_EDGES).point(lambda v: 255 if v > 40 else 0)
            out.paste(Image.new("RGB", img.size, (255, 255, 0)), mask=edge)
            t = times.get((base, p["name"], m))
            enc = times.get((base, "-", m + "-encode"))
            label = m
            if t:
                label += f"  {t['seconds'] * 1000:.0f} ms"
                if enc:
                    label += f" (+{enc['seconds']:.2f} s once)"
                if t.get("note") and "instance" not in t["note"]:
                    label += f"  {t['note']}"
            tiles.append((out, label))
        rows.append(tiles)

cols = len(MODELS) + 1
sheet = Image.new("RGB", (cols * TILE, len(rows) * (TILE + 30)), "white")
draw = ImageDraw.Draw(sheet)
for ri, tiles in enumerate(rows):
    for ci, (im, label) in enumerate(tiles):
        im = im.copy()
        im.thumbnail((TILE - 6, TILE - 6))
        x, y = ci * TILE + 3, ri * (TILE + 30) + 3
        sheet.paste(im, (x, y))
        draw.text((x, y + TILE - 2), label, fill="black")
sheet.save(sheet_path, quality=88)
print(sheet_path, sheet.size)
