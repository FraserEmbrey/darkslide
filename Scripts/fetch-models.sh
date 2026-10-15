#!/bin/bash
# Fetches darktable's raw denoise model (RawNIND, GPL-3.0) from its
# darktable-ai release and converts it to Core ML in Models/, which
# build-app.sh compiles into the app. Without it, Denoise isn't offered.
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
