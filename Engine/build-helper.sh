#!/bin/bash
# Builds darkroom-helper with exactly the flags darktable-cli was built with,
# so struct layouts match the libdarktable it links against.
# Output: vendor/dt-install/bin/darkroom-helper (next to darktable-cli, so the
# engine finds its modules and data via the same relative paths).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# DT_BUILD / DT_INSTALL point at another engine build (e.g. an OpenCL one)
BUILD="${DT_BUILD:-$ROOT/vendor/dt-build}"
INSTALL="${DT_INSTALL:-$ROOT/vendor/dt-install}"
SRC="$ROOT/Engine/helper.c"
OBJ="$BUILD/darkroom-helper.o"
OUT="$INSTALL/bin/darkroom-helper"

cmds="$(ninja -C "$BUILD" -t commands darktable-cli)"
compile="$(grep -F 'cli/main.c' <<<"$cmds" | tail -1)"
link="$(grep -F -- '-o bin/darktable-cli' <<<"$cmds" | tail -1)"

# compile: swap darktable-cli's source and object for ours
compile="${compile//-o bin\/cli\/CMakeFiles\/darktable-cli.dir\/main.c.o/-o $OBJ}"
compile="${compile//-c $ROOT\/vendor\/darktable-5.6.2\/src\/cli\/main.c/-c $SRC}"
compile="${compile//-MF bin\/cli\/CMakeFiles\/darktable-cli.dir\/main.c.o.d/}"
compile="${compile//-MD -MT bin\/cli\/CMakeFiles\/darktable-cli.dir\/main.c.o/}"

# link: our object, our output, and an install-relative rpath for libdarktable
link="${link//bin\/cli\/CMakeFiles\/darktable-cli.dir\/main.c.o/$OBJ}"
link="${link//-o bin\/darktable-cli/-o $OUT}"
link="${link//-Wl,-rpath,$BUILD\/bin/-Wl,-rpath,@loader_path\/..\/lib\/darktable}"

# Lensfun, for the lens picker (libdarktable links the same library)
LENSFUN="$(brew --prefix lensfun)"
compile="$compile -I$LENSFUN/include/lensfun"
link="$link -L$LENSFUN/lib -llensfun"

(cd "$BUILD" && eval "$compile" && eval "$link")
echo "built $OUT"
