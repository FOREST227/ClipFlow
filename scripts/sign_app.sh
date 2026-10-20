#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/dist/ClipFlow.app}"
IDENTITY_FILE="$HOME/Library/Application Support/ClipFlow/signing/identity.sha1"

if [[ "${CLIPFLOW_ADHOC_SIGN:-0}" == "1" ]]; then
  SIGNING_IDENTITY="-"
  echo "WARNING: Explicit ad-hoc build; permissions may not survive upgrades." >&2
else
  SIGNING_IDENTITY="${CLIPFLOW_SIGNING_IDENTITY:-}"
  if [[ -z "$SIGNING_IDENTITY" && -f "$IDENTITY_FILE" ]]; then
    SIGNING_IDENTITY="$(<"$IDENTITY_FILE")"
  fi
  if [[ ! "$SIGNING_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo "No fixed signing identity configured. Run: zsh scripts/setup_signing.sh" >&2
    echo "CLIPFLOW_SIGNING_IDENTITY may override it with a certificate's 40-character SHA-1 fingerprint." >&2
    exit 1
  fi
  SIGNING_IDENTITY="${(U)SIGNING_IDENTITY}"
  if ! /usr/bin/security find-identity -v -p codesigning |
    /usr/bin/awk -v fingerprint="$SIGNING_IDENTITY" '$2 == fingerprint { found = 1 } END { exit !found }'; then
    echo "Fixed signing identity unavailable: $SIGNING_IDENTITY. Refusing ad-hoc fallback." >&2
    exit 1
  fi
fi

if [[ "$APP_PATH" == "--check" ]]; then
  echo "Signing identity: $SIGNING_IDENTITY"
  exit 0
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
if [[ "$BUNDLE_ID" != "com.clipflow.app" ]]; then
  echo "Refusing to sign a bundle with an unexpected identifier: $BUNDLE_ID" >&2
  exit 1
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  /usr/bin/codesign --force --sign - "$APP_PATH"
else
  # Bind identity to the stable certificate and bundle ID, never the binary hash.
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none \
    --identifier com.clipflow.app \
    --requirements "=designated => identifier \"com.clipflow.app\" and certificate leaf = H\"$SIGNING_IDENTITY\"" \
    "$APP_PATH"
fi
/usr/bin/codesign --verify --strict --verbose=2 "$APP_PATH"
/usr/bin/codesign -d -r- "$APP_PATH"
