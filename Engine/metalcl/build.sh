#!/bin/bash
# Builds MetalCL, the OpenCL-on-Metal shim darktable can load in place of
# Apple's OpenCL, and installs the Metal kernel translations where it looks
# for them: next to darktable's kernels directory.
# Output: vendor/metalcl/libMetalCL.dylib
#         vendor/dt-install/share/darktable/metal-kernels/
# Select it with darktable's conf key: --conf opencl_library=<abs path to the dylib>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/vendor/metalcl"
KERNELS="$ROOT/vendor/metal-kernels"
INSTALL="${DT_INSTALL:-$ROOT/vendor/dt-install}"

mkdir -p "$OUT"
# OpenCL headers from the SDK for types and constants only; nothing links OpenCL
clang -O2 -g -Wall -Wno-unused-parameter -dynamiclib -fobjc-arc \
  -install_name @rpath/libMetalCL.dylib \
  -framework Metal -framework Foundation \
  -o "$OUT/libMetalCL.dylib" "$ROOT/Engine/metalcl/metalcl.m"
echo "built $OUT/libMetalCL.dylib"

if [ ! -e "$KERNELS/basic.metal" ]; then
  echo "no translated kernels in $KERNELS: run Engine/metal/translate.sh first" >&2
  exit 1
fi
if [ -d "$INSTALL/share/darktable" ]; then
  DEST="$INSTALL/share/darktable/metal-kernels"
  if [ -e "$DEST" ]; then trash "$DEST"; fi
  mkdir -p "$DEST"
  cp "$KERNELS"/*.metal "$KERNELS"/*.json "$DEST/"
  echo "installed $(ls "$DEST"/*.metal | wc -l | tr -d ' ') kernel files in $DEST"
fi
