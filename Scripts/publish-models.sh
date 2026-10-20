#!/bin/bash
# Publishes the Core ML models for download (ModelStore): compiles each
# model in Models/ (Scripts/fetch-models.sh), zips it, writes each zip's
# size and SHA-256 into App/Sources/Editor/ModelManifest.swift, and uploads
# the zips to a new GitHub release named by the tag. Commit the manifest
# afterwards; releases built from then on download from that tag.
#
# A published tag is never replaced, since apps already out there check
# downloads against its checksums: new models get a new tag (models-2, ...).
#
# Usage: publish-models.sh <tag>            e.g. models-1
#        publish-models.sh <tag> --local    zips and manifest only, in build/models
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:?usage: publish-models.sh <tag> [--local]}"
LOCAL="${2:-}"
OUT="$ROOT/build/models"
MANIFEST="$ROOT/App/Sources/Editor/ModelManifest.swift"

if [ -z "$LOCAL" ] && gh release view "$TAG" > /dev/null 2>&1; then
  echo "release $TAG exists already; publish new models under a new tag" >&2
  exit 1
fi

if [ -e "$OUT" ]; then trash "$OUT"; fi
mkdir -p "$OUT/compiled"
entries=""
for model in RawDenoise RescueFocus RescueMotion RemoveObjects; do
  if [ ! -d "$ROOT/Models/$model.mlpackage" ]; then
    echo "Models/$model.mlpackage is missing: run Scripts/fetch-models.sh" >&2
    exit 1
  fi
  xcrun coremlcompiler compile "$ROOT/Models/$model.mlpackage" "$OUT/compiled" > /dev/null
  (cd "$OUT/compiled" && ditto -c -k --keepParent "$model.mlmodelc" "$OUT/$model.mlmodelc.zip")
  size=$(stat -f %z "$OUT/$model.mlmodelc.zip")
  sum=$(shasum -a 256 "$OUT/$model.mlmodelc.zip" | cut -d' ' -f1)
  entries="$entries        \"$model\": (bytes: $size, sha256: \"$sum\"),
"
done

cat > "$MANIFEST" <<EOF
// Written by Scripts/publish-models.sh: the models published for download
// (ModelStore), as zipped compiled models on the GitHub release \`release\`.
enum ModelManifest {
    static let release = "$TAG"
    static let models: [String: (bytes: Int, sha256: String)] = [
$entries    ]
}
EOF
echo "wrote $MANIFEST"

if [ -z "$LOCAL" ]; then
  gh release create "$TAG" "$OUT"/*.mlmodelc.zip --latest=false --title "Models ($TAG)" \
    --notes "Core ML models that Darkslide downloads the first time Denoise or Rescue Focus is used. Not an app release.

- RawDenoise: darktable-ai's rawdenoise-nind (RawNIND), GPL-3.0
- RescueFocus, RescueMotion: Restormer's defocus and motion deblurring (Zamir et al., CVPR 2022), MIT"
  echo "published $TAG; commit $MANIFEST"
fi
