#!/bin/bash
# Fetches darktable's raw denoise model (RawNIND, GPL-3.0) from its
# darktable-ai release, and Restormer's defocus and motion deblurring models
# (MIT) from its GitHub release, and converts them to Core ML in Models/,
# which build-app.sh compiles into the app. Without them, Denoise and Rescue
# Focus aren't offered.
# Needs uv; the conversion tools go in .build/model-venv.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="release-5.6.0"
MODEL="rawdenoise-nind"
SHA256="d71b5f1e727c85a359e6f74dca9e2016c9d8fc3e2f7ac3e9b347d80ceca969af"
VENV="$ROOT/.build/model-venv"
WORK="$ROOT/.build/models"

if [ ! -x "$VENV/bin/python" ]; then
  uv venv -q --python 3.12 "$VENV"
  uv pip install -q --python "$VENV/bin/python" coremltools==9.0 torch==2.7.0 onnx onnx2torch onnxruntime
fi
# Restormer's architecture, for its conversion
"$VENV/bin/python" -c "import spandrel_extra_arches" 2> /dev/null \
  || uv pip install -q --python "$VENV/bin/python" spandrel==0.4.2 spandrel_extra_arches==0.2.0 einops

mkdir -p "$WORK" "$ROOT/Models"
archive="$WORK/$MODEL.dtmodel"
if [ ! -f "$archive" ]; then
  curl -fsSL -o "$archive" "https://github.com/darktable-org/darktable-ai/releases/download/$RELEASE/$MODEL.dtmodel"
fi
echo "$SHA256  $archive" | shasum -a 256 -c - > /dev/null
unzip -oq "$archive" -d "$WORK"

# full precision: the model's raw output runs past half precision's range
out="$ROOT/Models/RawDenoise.mlpackage"
if [ -e "$out" ]; then trash "$out"; fi
"$VENV/bin/python" -I "$ROOT/Scripts/models/convert.py" "$WORK/$MODEL/model_bayer.onnx" "$out" fp32
cp "$WORK/$MODEL/config.json" "$ROOT/Models/RawDenoise-config.json"
echo "converted $out"

# Rescue Focus: Restormer, single-image defocus deblurring
RESTORMER="$WORK/restormer_defocus.pth"
if [ ! -f "$RESTORMER" ]; then
  curl -fsSL -o "$RESTORMER" "https://github.com/swz30/Restormer/releases/download/v1.0/single_image_defocus_deblurring.pth"
fi
echo "7dce451f33f8f5e0faf7c4e3996e5dcc1bd425ecd1ada99b0f9750e490fd4c9e  $RESTORMER" | shasum -a 256 -c - > /dev/null
out="$ROOT/Models/RescueFocus.mlpackage"
if [ -e "$out" ]; then trash "$out"; fi
"$VENV/bin/python" -I "$ROOT/Scripts/models/convert_restormer.py" "$RESTORMER" "$out"

# Rescue Focus for camera shake: Restormer, motion deblurring (trained on GoPro)
MOTION="$WORK/restormer_motion.pth"
if [ ! -f "$MOTION" ]; then
  curl -fsSL -o "$MOTION" "https://github.com/swz30/Restormer/releases/download/v1.0/motion_deblurring.pth"
fi
echo "194e38fb5b607c9dc5a5b3e08e65b2e79ee2bf0ef5048e0612f6b2ff2f79da31  $MOTION" | shasum -a 256 -c - > /dev/null
out="$ROOT/Models/RescueMotion.mlpackage"
if [ -e "$out" ]; then trash "$out"; fi
"$VENV/bin/python" -I "$ROOT/Scripts/models/convert_restormer.py" "$MOTION" "$out" motion
