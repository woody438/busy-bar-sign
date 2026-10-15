#!/usr/bin/env bash
# Makes the certificate GitHub signs Busy Bar Sign with, so macOS sees every
# build as the same app and its permissions (Accessibility) carry over from
# one update to the next. Without it each build is signed ad hoc, looks new
# to macOS, and has to be allowed again.
#
# Run it once, on your Mac:
#   curl -fsSL https://raw.githubusercontent.com/woody438/busy-bar-sign/main/tools/make-signing-cert.sh | bash
# It copies the certificate (base64) to the clipboard and prints its password.
# On GitHub, Settings ▸ Secrets and variables ▸ Actions ▸ New repository secret:
#   SIGNING_CERT_P12        paste the clipboard
#   SIGNING_CERT_PASSWORD   the password it printed
# Nothing is kept on the Mac, so keep a copy of both (a password manager) if
# you'd like to reuse them; a new certificate later just means one more
# "Reset and ask again" for everyone.
#
# It's self-signed: Apple doesn't vouch for it, so the first open still needs
# Open Anyway, as now. Keep the secrets secret — anyone with them could sign
# an app macOS would take for Busy Bar Sign.
#
#   tools/make-signing-cert.sh OUT.p12    writes the .p12 there and prints only
#                                         the password (CI's own test of signing)
set -euo pipefail
OPENSSL=/usr/bin/openssl                 # macOS's own (LibreSSL): a .p12 the keychain imports
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
PASS=$("$OPENSSL" rand -hex 16)

cat > "$DIR/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Busy Bar Sign
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 -config "$DIR/cert.cnf" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -name "Busy Bar Sign" \
  -out "$DIR/cert.p12" -passout "pass:$PASS"

if [ $# -ge 1 ]; then
  cp "$DIR/cert.p12" "$1"
  echo "$PASS"
  exit 0
fi

base64 -i "$DIR/cert.p12" | tr -d '\n' | pbcopy
cat <<EOF

The certificate is on the clipboard. On GitHub, woody438/busy-bar-sign ▸ Settings ▸
Secrets and variables ▸ Actions ▸ New repository secret:

  SIGNING_CERT_P12        paste (⌘V)
  SIGNING_CERT_PASSWORD   $PASS

Then the next build is signed with it. Allow Busy Bar Sign in Accessibility once
more after installing that build; from then on updates keep the permission.
EOF
