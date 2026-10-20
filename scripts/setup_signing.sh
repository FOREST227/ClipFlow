#!/bin/zsh
# Run once on this Mac. Never regenerate the identity during a normal build.
set -euo pipefail
umask 077

CERT_NAME="ClipFlow Local Development"
CONFIG_DIR="$HOME/Library/Application Support/ClipFlow/signing"
IDENTITY_FILE="$CONFIG_DIR/identity.sha1"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipflow-signing.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$CONFIG_DIR"

has_identity() {
  /usr/bin/security find-identity -v -p codesigning "$KEYCHAIN" |
    /usr/bin/awk -v fingerprint="$1" '$2 == fingerprint { found = 1 } END { exit !found }'
}

if [[ -f "$IDENTITY_FILE" ]]; then
  FINGERPRINT="$(<"$IDENTITY_FILE")"
  if has_identity "$FINGERPRINT"; then
    echo "Fixed signing identity already configured: $CERT_NAME ($FINGERPRINT)"
    exit 0
  fi
  echo "The configured identity is unavailable. Restore its certificate/private key in the login keychain." >&2
  echo "Refusing to create a different identity and invalidate existing permissions." >&2
  exit 1
fi

if /usr/bin/security find-certificate -c "$CERT_NAME" -p "$KEYCHAIN" > "$TEMP_DIR/certificate.pem" 2>/dev/null; then
  echo "Reusing the existing $CERT_NAME certificate."
else
  cat > "$TEMP_DIR/openssl.cnf" <<'CONFIG'
[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = ClipFlow Local Development
O = ClipFlow Local Development
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
CONFIG
  /usr/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 3650 \
    -config "$TEMP_DIR/openssl.cnf" \
    -keyout "$TEMP_DIR/private-key.pem" -out "$TEMP_DIR/certificate.pem" 2>"$TEMP_DIR/openssl.log"
  /usr/bin/openssl rand -hex 32 > "$TEMP_DIR/password"
  /usr/bin/openssl pkcs12 -export -name "$CERT_NAME" \
    -inkey "$TEMP_DIR/private-key.pem" -in "$TEMP_DIR/certificate.pem" \
    -out "$TEMP_DIR/identity.p12" -passout "file:$TEMP_DIR/password" \
    -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
  # Apple's PKCS#12 importer requires legacy transport algorithms. A random,
  # temporary password protects this bundle; only codesign gets key access.
  /usr/bin/security import "$TEMP_DIR/identity.p12" -k "$KEYCHAIN" \
    -P "$(<"$TEMP_DIR/password")" -T /usr/bin/codesign
fi

# User-domain trust for code signing only; no SSL or system-wide root trust.
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TEMP_DIR/certificate.pem"
FINGERPRINT="$(/usr/bin/openssl x509 -in "$TEMP_DIR/certificate.pem" -noout -fingerprint -sha1 |
  /usr/bin/awk -F= '{ gsub(":", "", $2); print toupper($2) }')"
if ! has_identity "$FINGERPRINT"; then
  echo "Certificate exists but no usable signing identity was found. Check its private key and trust in Keychain Access." >&2
  exit 1
fi
cp "$TEMP_DIR/certificate.pem" "$CONFIG_DIR/certificate.pem"
printf '%s\n' "$FINGERPRINT" > "$IDENTITY_FILE"
echo "Configured fixed signing identity: $CERT_NAME ($FINGERPRINT)"
echo "Private key: login keychain. Public configuration: $CONFIG_DIR"
