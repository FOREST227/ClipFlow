#!/bin/zsh

set -euo pipefail

# ---------------------------------------------------------------------------
# build_release_dmg.sh — Build arm64, x86_64, and universal DMGs.
#
# Usage:
#   ./scripts/build_release_dmg.sh v0.0.8
#   ./scripts/build_release_dmg.sh            # uses CLIPFLOW_VERSION or v0.0.8
#
# Produces:
#   dist/release/ClipFlow-<tag>-arm64.dmg
#   dist/release/ClipFlow-<tag>-x86_64.dmg
#   dist/release/ClipFlow-<tag>-universal.dmg
#   + .sha256 for each
# ---------------------------------------------------------------------------

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_DIR="$DIST_DIR/release"
APP_NAME="ClipFlow"
PRODUCT_NAME="ClipFlowApp"

RAW_VERSION="${1:-${CLIPFLOW_VERSION:-v0.0.8}}"
TAG_NAME="${RAW_VERSION#refs/tags/}"
BUNDLE_VERSION="${TAG_NAME#v}"
BUILD_NUMBER="${CLIPFLOW_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"

if [[ -z "$TAG_NAME" ]]; then
  echo "Missing release version or tag name." >&2
  exit 1
fi

zsh "$ROOT_DIR/scripts/sign_app.sh" --check
mkdir -p "$RELEASE_DIR"

# ── Build arm64 and x86_64 ─────────────────────────────────────────────────

echo "=== Building arm64 ==="
CLIPFLOW_VERSION="$BUNDLE_VERSION" CLIPFLOW_BUILD_NUMBER="$BUILD_NUMBER" \
  "$ROOT_DIR/scripts/build_app.sh" arm64

echo ""
echo "=== Building x86_64 ==="
CLIPFLOW_VERSION="$BUNDLE_VERSION" CLIPFLOW_BUILD_NUMBER="$BUILD_NUMBER" \
  "$ROOT_DIR/scripts/build_app.sh" x86_64

# ── Build universal via lipo ───────────────────────────────────────────────

echo ""
echo "=== Building universal ==="

ARM64_APP="$DIST_DIR/$APP_NAME-arm64.app"
X86_64_APP="$DIST_DIR/$APP_NAME-x86_64.app"
UNIVERSAL_APP="$DIST_DIR/$APP_NAME-universal.app"

ARM64_BIN="$ARM64_APP/Contents/MacOS/$PRODUCT_NAME"
X86_64_BIN="$X86_64_APP/Contents/MacOS/$PRODUCT_NAME"

if [[ ! -f "$ARM64_BIN" || ! -f "$X86_64_BIN" ]]; then
  echo "Missing arch binaries for lipo." >&2
  exit 1
fi

rm -rf "$UNIVERSAL_APP"
cp -R "$ARM64_APP" "$UNIVERSAL_APP"

mkdir -p "$DIST_DIR/universal-lipo"
lipo "$ARM64_BIN" "$X86_64_BIN" -create -output "$DIST_DIR/universal-lipo/$PRODUCT_NAME"
cp "$DIST_DIR/universal-lipo/$PRODUCT_NAME" "$UNIVERSAL_APP/Contents/MacOS/$PRODUCT_NAME"
rm -rf "$DIST_DIR/universal-lipo"

# lipo changes the executable, so sign the completed universal bundle again.
zsh "$ROOT_DIR/scripts/sign_app.sh" "$UNIVERSAL_APP"

echo "Universal binary:"
lipo -info "$UNIVERSAL_APP/Contents/MacOS/$PRODUCT_NAME"
for RELEASE_ARCH in arm64 x86_64; do
  lipo "$UNIVERSAL_APP/Contents/MacOS/$PRODUCT_NAME" -verify_arch "$RELEASE_ARCH"
done

# ── Create DMGs ────────────────────────────────────────────────────────────

echo ""
echo "=== Creating DMGs ==="

for ARCH_SUFFIX in arm64 x86_64 universal; do
  DMG_NAME="$APP_NAME-$TAG_NAME-$ARCH_SUFFIX.dmg"
  DMG_PATH="$RELEASE_DIR/$DMG_NAME"
  SHA_PATH="$DMG_PATH.sha256"
  SRC_APP="$DIST_DIR/$APP_NAME-$ARCH_SUFFIX.app"

  DMG_TEMP_DIR="$RELEASE_DIR/dmg-$ARCH_SUFFIX"
  rm -rf "$DMG_TEMP_DIR"
  mkdir -p "$DMG_TEMP_DIR"
  cp -R "$SRC_APP" "$DMG_TEMP_DIR/$APP_NAME.app"
  ln -s /Applications "$DMG_TEMP_DIR/Applications"

  rm -f "$DMG_PATH" "$SHA_PATH"

  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_TEMP_DIR" \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH" >/dev/null

  rm -rf "$DMG_TEMP_DIR"

  (
    cd "$ROOT_DIR"
    shasum -a 256 "dist/release/$DMG_NAME" > "$SHA_PATH"
  )

  echo "$DMG_PATH"
done

echo ""
echo "=== Release artifacts ==="
ls -lh "$RELEASE_DIR"/*.dmg "$RELEASE_DIR"/*.sha256
