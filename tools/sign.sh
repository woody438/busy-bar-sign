#!/usr/bin/env bash
# Signs the built app with the project's certificate (tools/make-signing-cert.sh)
# in place of Xcode's ad-hoc signature. macOS then knows every build as the
# same app — its designated requirement names the certificate, not the build —
# so Accessibility and the other permissions carry over between updates.
#
#   tools/sign.sh "Busy Bar Sign.app" cert.p12 PASSWORD
#
# The certificate goes into a keychain of its own, made for this and deleted
# after; the login keychain is never touched.
set -euo pipefail
APP="$1"
P12="$2"
PASS="$3"

KC="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/busybarsign-signing.keychain-db"
KCPASS=$(/usr/bin/openssl rand -hex 16)
SEARCH=$(security list-keychains -d user | tr -d '"')
cleanup() {
  # shellcheck disable=SC2086
  security list-keychains -d user -s $SEARCH
  security delete-keychain "$KC" 2>/dev/null || true
}
trap cleanup EXIT

security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings -lut 3600 "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$P12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null
# shellcheck disable=SC2086
security list-keychains -d user -s "$KC" $SEARCH

# the certificate's SHA-1: self-signed, so it isn't "valid" (trusted), but codesign signs with it
ID=$(security find-identity -p codesigning "$KC" | awk '/^ *[0-9]+\)/ { print $2; exit }')
if [ -z "$ID" ]; then
  echo "sign.sh: no code-signing identity in $P12" >&2
  exit 1
fi

codesign --force --sign "$ID" --keychain "$KC" --timestamp=none \
  --preserve-metadata=entitlements,flags "$APP"
codesign --verify --strict --verbose=2 "$APP"
REQ=$(codesign -d -r- "$APP" 2>&1)
echo "$REQ" | grep "designated"
if ! echo "$REQ" | grep -q "certificate"; then
  echo "sign.sh: $APP isn't signed with the certificate" >&2
  exit 1
fi
