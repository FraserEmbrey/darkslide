#!/bin/bash
# Fetches darktable's source, applies Develop's patches and builds a minimal
# engine (no GUI extras, no Lua; GPU via Apple OpenCL) into vendor/dt-install.
set -euo pipefail

VERSION="5.6.2"
SHA256="d2da92c670401d350b576431f21e58bee40348e1f5078201a8a1b8c270585834"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
mkdir -p "$VENDOR"
cd "$VENDOR"

if [ ! -d "darktable-$VERSION" ]; then
  gh release download "release-$VERSION" -R darktable-org/darktable -p "darktable-$VERSION.tar.xz" --clobber
  echo "$SHA256  darktable-$VERSION.tar.xz" | shasum -a 256 -c -
  tar xf "darktable-$VERSION.tar.xz"
  for p in "$ROOT"/Engine/patches/*.patch; do
    patch -d "darktable-$VERSION" -p1 < "$p"
  done
fi

# BINARY_PACKAGE_BUILD: generic arm64 code, not -march=native, so the app
# runs on any Apple silicon Mac rather than only this one's generation.
# The prefix map keeps this checkout's path (and so the home folder) out of
# the binaries: darktable builds with -g, and OpenMP and __FILE__ embed paths.
# GTK's headers include ATK's, which Homebrew has since moved into
# at-spi2-core (darktable's build still names the old atk path).
CFLAGS_EXTRA="-ffile-prefix-map=$ROOT/= -I$(brew --prefix at-spi2-core)/include/atk-1.0"
cmake -S "darktable-$VERSION" -B dt-build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$VENDOR/dt-install" \
  -DBINARY_PACKAGE_BUILD=ON -DCMAKE_C_FLAGS="$CFLAGS_EXTRA" -DCMAKE_CXX_FLAGS="$CFLAGS_EXTRA" \
  -DCMAKE_OBJC_FLAGS="$CFLAGS_EXTRA" -DCMAKE_OBJCXX_FLAGS="$CFLAGS_EXTRA" \
  -DUSE_LUA=OFF -DUSE_MAP=OFF -DUSE_COLORD=OFF -DUSE_KWALLET=OFF -DUSE_LIBSECRET=OFF \
  -DUSE_OPENCL=ON -DTESTBUILD_OPENCL_PROGRAMS=OFF -DUSE_GMIC=OFF -DUSE_GRAPHICSMAGICK=OFF \
  -DUSE_PORTMIDI=OFF -DUSE_SDL2=OFF -DUSE_CAMERA_SUPPORT=OFF -DBUILD_PRINT=OFF \
  -DUSE_MAC_INTEGRATION=OFF -DUSE_AVIF=OFF -DUSE_OPENJPEG=OFF -DUSE_XMLLINT=OFF \
  -DBUILD_CMSTEST=OFF -DBUILD_RS_IDENTIFY=OFF -DUSE_AI=OFF \
  -DUSE_XCF=OFF -DUSE_ICU=OFF \
  -DUSE_HEIF=OFF -DUSE_OPENEXR=OFF -DUSE_JXL=OFF -DUSE_WEBP=OFF \
  -DOpenMP_ROOT=/opt/homebrew/opt/libomp
cmake --build dt-build
cmake --install dt-build
