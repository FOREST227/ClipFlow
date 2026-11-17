#!/bin/zsh

set -euo pipefail

# ---------------------------------------------------------------------------
# build_app.sh — Build ClipFlow.app for a given architecture.
#
# Usage:
#   ./scripts/build_app.sh                  # host architecture (default)
#   ./scripts/build_app.sh arm64            # Apple Silicon
#   ./scripts/build_app.sh x86_64           # Intel
#
# Environment variables:
#   CLIPFLOW_VERSION       — bundle short version (default 0.2.2)
#   CLIPFLOW_BUILD_NUMBER  — bundle build number (default 32)
#   CLIPFLOW_ADHOC_SIGN    — set to 1 for explicit ad-hoc signing (CI only)
# ---------------------------------------------------------------------------

ARCH="${1:-host}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCT_NAME="ClipFlowApp"
APP_NAME="ClipFlow"
DIST_DIR="$ROOT_DIR/dist"
ICON_PNG="$ROOT_DIR/assets/icon/ClipFlow-icon-1024.png"
ICON_NAME="AppIcon"
APP_VERSION="${CLIPFLOW_VERSION:-0.2.2}"
BUILD_NUMBER="${CLIPFLOW_BUILD_NUMBER:-32}"
DEPLOYMENT_TARGET="12.0"

# Resolve output directory based on architecture
case "$ARCH" in
  host)
    APP_DIR="$DIST_DIR/$APP_NAME.app"
    ICONSET_DIR="$DIST_DIR/ClipFlow.iconset"
    SWIFT_ARCH_FLAGS=()
    ;;
  arm64|x86_64)
    APP_DIR="$DIST_DIR/$APP_NAME-$ARCH.app"
    ICONSET_DIR="$DIST_DIR/ClipFlow-$ARCH.iconset"
    SWIFT_ARCH_FLAGS=(--arch "$ARCH" --scratch-path "$ROOT_DIR/.build/release-$ARCH"
      -Xswiftc -target -Xswiftc "${ARCH}-apple-macosx${DEPLOYMENT_TARGET}")
    ;;
  *)
    echo "Usage: $0 [arm64|x86_64]" >&2
    exit 1
    ;;
esac

if [[ ! -f "$ICON_PNG" ]]; then
  echo "Icon source not found at $ICON_PNG" >&2
  exit 1
fi

# Fail before compiling if the fixed local signing certificate is unavailable.
zsh "$ROOT_DIR/scripts/sign_app.sh" --check

# Build
cd "$ROOT_DIR"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
SWIFT="$(xcrun --find swift)"
"$SWIFT" build -c release --product "$PRODUCT_NAME" "${SWIFT_ARCH_FLAGS[@]}"
BIN_DIR="$("$SWIFT" build -c release --show-bin-path "${SWIFT_ARCH_FLAGS[@]}")"
BINARY_PATH="$BIN_DIR/$PRODUCT_NAME"

if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Release binary not found at $BINARY_PATH" >&2
  exit 1
fi

# Verify architecture
echo "Binary architecture:"
lipo -info "$BINARY_PATH"
if [[ "$ARCH" != "host" ]]; then
  lipo "$BINARY_PATH" -verify_arch "$ARCH"
fi

# Assemble .app bundle
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/$PRODUCT_NAME"
ditto "$ROOT_DIR/Sources/ClipFlowApp/Renderer" "$APP_DIR/Contents/Resources/Renderer"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$ICON_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/$ICON_NAME.icns"

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
  <string>ClipFlow</string>
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
  <string>$DEPLOYMENT_TARGET</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>ClipFlow 需要控制 Microsoft Excel，以便在 Excel 自己的复制会话结束后插入单元格并粘贴原来的表格格式。</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# The packaged app keeps renderer scripts in Contents/Resources/Renderer.
# SwiftPM's generated Bundle accessor aborts when its .bundle is absent, so the
# app target must not reference it, and the shipped binary must be able to build
# plain-text, code, and markdown detail HTML from that Resources directory.
verify_packaged_renderer() {
  local app_dir="$1"
  local binary="$app_dir/Contents/MacOS/$PRODUCT_NAME"
  local renderer_dir="$app_dir/Contents/Resources/Renderer"
  local file match=0

  while IFS= read -r -d '' file; do
    if grep -n -E 'Bundle\.module' "$file"; then
      match=1
    fi
  done < <(find "$ROOT_DIR/Sources" -name '*.swift' -print0)
  if (( match != 0 )); then
    echo "The generated SwiftPM resource accessor aborts when its bundle is not in the app." >&2
    exit 1
  fi

  if [[ ! -d "$renderer_dir" ]]; then
    echo "Packaged renderer directory is missing: $renderer_dir" >&2
    exit 1
  fi
  for name in highlight.min.js markdown-it.min.js lang-swift.js; do
    if [[ ! -s "$renderer_dir/$name" ]]; then
      echo "Packaged app is missing renderer resource: $name" >&2
      exit 1
    fi
  done
  if [[ ! -x "$binary" ]]; then
    echo "Packaged executable is missing: $binary" >&2
    exit 1
  fi

  local host_arch binary_archs
  host_arch="$(uname -m)"
  binary_archs="$(lipo -archs "$binary")"
  if [[ " $binary_archs " != *" $host_arch "* ]]; then
    echo "Skipping in-process renderer verification for [$binary_archs] on $host_arch; packaged resources are present."
    return 0
  fi

  local output_file pid elapsed=0 verify_status output
  output_file="$(mktemp)"
  env -u PACKAGE_RESOURCE_BUNDLE_PATH -u PACKAGE_RESOURCE_BUNDLE_URL \
    "$binary" --verify-renderer >"$output_file" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (( elapsed >= 150 )); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo "Renderer verification timed out." >&2
      cat "$output_file" >&2 || true
      rm -f "$output_file"
      exit 1
    fi
    sleep 0.2
    elapsed=$((elapsed + 1))
  done
  set +e
  wait "$pid"
  verify_status=$?
  set -e
  output="$(<"$output_file")"
  rm -f "$output_file"
  printf '%s\n' "$output"
  if (( verify_status != 0 )); then
    echo "Renderer verification failed with status $verify_status." >&2
    exit 1
  fi
  case "$output" in
    *"Renderer resources verified"*) ;;
    *)
      echo "Renderer verification did not report success." >&2
      exit 1
      ;;
  esac
}

zsh "$ROOT_DIR/scripts/sign_app.sh" "$APP_DIR"
verify_packaged_renderer "$APP_DIR"

echo "Built app bundle at:"
echo "$APP_DIR"
