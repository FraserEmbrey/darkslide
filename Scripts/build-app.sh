#!/bin/bash
# Builds Develop.app: the Swift app plus the darktable engine in
# Contents/Resources/engine, signed with the local Apple Development identity.
#
# Proof-of-concept limits: the engine still links Homebrew's dylibs in
# /opt/homebrew, so the app only runs on a Mac with those formulae installed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Develop.app"
ENGINE_SRC="$ROOT/vendor/dt-install"
IDENTITY="${DEVELOP_SIGN_IDENTITY:-Apple Development}"

"$ROOT/Engine/build-helper.sh"
swift build --package-path "$ROOT" -c "$CONFIG"

if [ -e "$APP" ]; then trash "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine/bin" "$APP/Contents/Resources/engine/share"
cp "$ROOT/.build/$CONFIG/Develop" "$APP/Contents/MacOS/Develop"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"

# app icon: Design/AppIcon.icon (Icon Composer layers, made by Design/make-icon.py)
# compiled to Assets.car for Liquid Glass, plus an .icns fallback
xcrun actool "$ROOT/Design/AppIcon.icon" --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon --target-device mac \
  --output-partial-info-plist "$ROOT/.build/icon-partial.plist" > /dev/null

# engine layout mirrors the install prefix so darktable finds its
# modules (lib/darktable) and data (share/darktable) relative to the binary
cp "$ENGINE_SRC/bin/darkroom-helper" "$APP/Contents/Resources/engine/bin/"
cp -R "$ENGINE_SRC/lib" "$APP/Contents/Resources/engine/"
# MetalCL: darktable's GPU code on Metal (Engine/metalcl); kernels are in share/darktable/metal-kernels
"$ROOT/Engine/metalcl/build.sh" > /dev/null
cp "$ROOT/vendor/metalcl/libMetalCL.dylib" "$APP/Contents/Resources/engine/lib/"
cp -R "$ENGINE_SRC/share/darktable" "$APP/Contents/Resources/engine/share/"

# darktable's interface libraries (GTK and those under it) are never run:
# point the engine at stand-ins, so they aren't loaded (Scripts/stub-gui-libs.py)
python3 "$ROOT/Scripts/stub-gui-libs.py" "$APP/Contents/Resources/engine"

codesign --force --deep --sign "$IDENTITY" "$APP"
echo "built $APP"
