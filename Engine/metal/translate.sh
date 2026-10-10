#!/bin/bash
# Translates darktable's OpenCL kernels to Metal and applies compiler-guided
# fix-ups until everything compiles (or nothing more can be fixed).
# usage: Engine/metal/translate.sh [OUT_DIR]   (default vendor/metal-kernels)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/vendor/metal-kernels}"
KERNELS="$ROOT/vendor/darktable-5.6.2/data/kernels"
CT="$ROOT/vendor/metal-compile-test"

swiftc -O "$ROOT/Engine/metal/compile-test.swift" -o "$CT" 2>/dev/null
if [ -e "$OUT" ]; then trash "$OUT"; fi
python3 -I "$ROOT/Engine/metal/cl2metal.py" "$KERNELS" "$OUT"
for round in 1 2 3 4; do
  "$CT" "$OUT" --json "$OUT/.errors.json" | head -1
  fixed=$(python3 -I "$ROOT/Engine/metal/cl2metal.py" --fixup "$OUT" "$OUT/.errors.json" | cut -d' ' -f1)
  [ "$fixed" = "0" ] && break
done
"$CT" "$OUT" --errors 3
