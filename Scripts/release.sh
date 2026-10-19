#!/bin/bash
# Builds a release of Darkslide from a tag and puts it on GitHub as a draft:
# the app without the models (downloaded when first used, see ModelStore),
# signed with a Developer ID, notarised by Apple and stapled, so it opens on
# any Mac without Gatekeeper's warning. Check the draft, then publish it on
# GitHub.
#
# Needs, once:
#   - a "Developer ID Application" certificate in the keychain (Xcode ›
#     Settings › Accounts › Manage Certificates › +)
#   - notarytool's credentials in the keychain, under the profile name
#     DARKSLIDE_NOTARY_PROFILE (default "darkslide"):
#       xcrun notarytool store-credentials darkslide --apple-id <Apple ID> --team-id <team ID>
#     with an app-specific password from account.apple.com
#   - the models published (Scripts/publish-models.sh) and their manifest committed
#   - gh signed in
#
# Usage: release.sh <version>      e.g. 0.2; tags HEAD v0.2 unless it's tagged
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: release.sh <version>}"
TAG="v$VERSION"
IDENTITY="${DARKSLIDE_RELEASE_IDENTITY:-Developer ID Application}"
PROFILE="${DARKSLIDE_NOTARY_PROFILE:-darkslide}"
APP="$ROOT/build/Darkslide.app"
OUT="$ROOT/build/release"
ZIP="$OUT/Darkslide-$VERSION.zip"
cd "$ROOT"

# the source of a release is its tag, so build only what's committed
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "commit or stash your changes first: a release is built from its tag" >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "no \"$IDENTITY\" certificate in the keychain (see the top of this script)" >&2
  exit 1
fi
MODELS=$(sed -n 's/.*static let release = "\(.*\)".*/\1/p' App/Sources/Editor/ModelManifest.swift)
if [ -z "$MODELS" ] || ! gh release view "$MODELS" > /dev/null 2>&1; then
  echo "the models aren't published (Scripts/publish-models.sh), so the release couldn't download them" >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
  if [ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
    echo "$TAG is another commit; check out $TAG to build it" >&2
    exit 1
  fi
else
  git tag -a "$TAG" -m "Darkslide $VERSION"
fi

DARKSLIDE_NO_MODELS=1 DARKSLIDE_SIGN_IDENTITY="$IDENTITY" "$ROOT/Scripts/build-app.sh"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$APP/Contents/Info.plist"

# signed from the inside out, each binary with the hardened runtime and a
# secure timestamp, as notarisation requires
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
find "$APP/Contents/Resources" -type f -print0 | while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q "Mach-O"; then sign "$f"; fi
done
sign --entitlements "$ROOT/App/Darkslide.entitlements" "$APP"
codesign --verify --strict --deep "$APP"

if [ -e "$OUT" ]; then trash "$OUT"; fi
mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute "$APP"
# zipped again, with the ticket stapled in, so it opens offline too
trash "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

git push origin "$TAG"
cat > "$OUT/notes.md" <<EOF
darktable's raw engine in a Mac-assed Mac app. I wanted something that works like Aperture 3 did, with darktable doing the processing.

## Install

Download **Darkslide-$VERSION.zip** below, unzip it and drag Darkslide to Applications. It's notarised, so it opens without a warning. The [README](https://github.com/FraserEmbrey/darkroom-native#getting-started) has a short getting started guide.

It needs an Apple silicon Mac and macOS 26. I've built it around Metal, Core ML and macOS 26's HDR and toolbar APIs, and the engine is built for arm64 only.

## Good to know

- It's version $VERSION, so expect rough edges. darktable does the processing, so the results should be solid. Issues are welcome.
- Edits are saved as darktable XMP sidecars next to your photos, so you can open them in darktable.
- Denoise and Rescue Focus ask before downloading their models (30 to 50 MB each) the first time you use them. That's why the download is only 16 MB.

Darkslide is free software under the GNU GPL, version 3 or later, built on darktable 5.6.2. Its source is this tag. Help › Acknowledgements in the app lists everything else inside it, with their licences.
EOF
gh release create "$TAG" "$ZIP" --draft --verify-tag --title "Darkslide $VERSION" --notes-file "$OUT/notes.md"
echo "drafted $TAG: check it on GitHub, then publish it"
