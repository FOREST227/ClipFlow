#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCT_NAME="ClipFlowApp"
APP_NAME="ClipFlow"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ICON_PNG="$ROOT_DIR/assets/icon/ClipFlow-icon-1024.png"
ICONSET_DIR="$DIST_DIR/ClipFlow.iconset"
ICON_NAME="AppIcon"
ICNS_PATH="$APP_DIR/Contents/Resources/$ICON_NAME.icns"
APP_VERSION="${CLIPFLOW_VERSION:-0.1.0}"
BUILD_NUMBER="${CLIPFLOW_BUILD_NUMBER:-1}"

# Fail before rebuilding if the fixed local signing identity is unavailable.
zsh "$ROOT_DIR/scripts/sign_app.sh" --check
cd "$ROOT_DIR"

swift "$ROOT_DIR/scripts/render_icon.swift" "$ICON_PNG"

swift build -c release --product "$PRODUCT_NAME"
BIN_DIR="$(swift build -c release --show-bin-path)"
BINARY_PATH="$BIN_DIR/$PRODUCT_NAME"

if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Release binary not found at $BINARY_PATH" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/$PRODUCT_NAME"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>ClipFlowApp</string>
  <key>CFBundleDisplayName</key>
  <string>ClipFlow 剪流</string>
  <key>CFBundleIdentifier</key>
  <string>com.clipflow.app</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>ClipFlow</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

zsh "$ROOT_DIR/scripts/sign_app.sh" "$APP_DIR"

echo "Built app bundle at:"
echo "$APP_DIR"
