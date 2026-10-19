#!/bin/bash
# Builds Darkslide.app: the Swift app plus the darktable engine in
# Contents/Resources/engine, signed with the local Apple Development identity.
#
# The engine's libraries are copied in from Homebrew (Scripts/bundle-libs.py),
# so the built app runs on a Mac without Homebrew; building it still needs them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Darkslide.app"
ENGINE_SRC="$ROOT/vendor/dt-install"
IDENTITY="${DARKSLIDE_SIGN_IDENTITY:-Apple Development}"

"$ROOT/Engine/build-helper.sh"
swift build --package-path "$ROOT" -c "$CONFIG"

if [ -e "$APP" ]; then trash "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine/bin" "$APP/Contents/Resources/engine/share"
cp "$ROOT/.build/$CONFIG/Darkslide" "$APP/Contents/MacOS/Darkslide"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"

# app icon: Design/AppIcon.icon (Icon Composer layers, made by Design/make-icon.py)
# compiled to Assets.car for Liquid Glass, plus an .icns fallback
xcrun actool "$ROOT/Design/AppIcon.icon" --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon --target-device mac \
  --output-partial-info-plist "$ROOT/.build/icon-partial.plist" > /dev/null

# Core ML models, when Scripts/fetch-models.sh has made them: raw denoise
# and Rescue Focus (defocus and motion)
for model in RawDenoise RescueFocus RescueMotion; do
  if [ -d "$ROOT/Models/$model.mlpackage" ]; then
    mkdir -p "$APP/Contents/Resources/Models"
    xcrun coremlcompiler compile "$ROOT/Models/$model.mlpackage" "$APP/Contents/Resources/Models" > /dev/null
  fi
done

# engine layout mirrors the install prefix so darktable finds its
# modules (lib/darktable) and data (share/darktable) relative to the binary
cp "$ENGINE_SRC/bin/darkroom-helper" "$APP/Contents/Resources/engine/bin/"
# without darktable's interface parts: lighttable and view modules
rsync -a --exclude 'plugins/lighttable' --exclude 'views' "$ENGINE_SRC/lib" "$APP/Contents/Resources/engine/"
# MetalCL: darktable's GPU code on Metal (Engine/metalcl); kernels are in share/darktable/metal-kernels
"$ROOT/Engine/metalcl/build.sh" > /dev/null
cp "$ROOT/vendor/metalcl/libMetalCL.dylib" "$APP/Contents/Resources/engine/lib/"
# and without its interface art (pixmaps, themes, the slideshow) or its LaTeX and tools
rsync -a --exclude 'pixmaps' --exclude 'themes' --exclude 'pswp' --exclude 'latex' --exclude 'tools' \
  "$ENGINE_SRC/share/darktable" "$APP/Contents/Resources/engine/share/"

# darktable's interface libraries (GTK and those under it) are never run:
# point the engine at stand-ins, so they aren't loaded (Scripts/stub-gui-libs.py)
python3 "$ROOT/Scripts/stub-gui-libs.py" "$APP/Contents/Resources/engine"
# and the libraries it does use go into the app, so it runs without Homebrew
python3 "$ROOT/Scripts/bundle-libs.py" "$APP/Contents/Resources/engine"
# and every part that isn't Darkslide's own, with its licence (Help › Acknowledgements, and the About panel)
python3 "$ROOT/Scripts/notices.py" "$APP"

# the app and MetalCL keep a debug map naming their build paths; drop it
strip -S "$APP/Contents/MacOS/Darkslide" "$APP/Contents/Resources/engine/lib/libMetalCL.dylib"
if grep -rlqa "$HOME" "$APP"; then
  echo "these files contain $HOME:" >&2; grep -rla "$HOME" "$APP" >&2; exit 1
fi

codesign --force --deep --sign "$IDENTITY" "$APP"
echo "built $APP"
