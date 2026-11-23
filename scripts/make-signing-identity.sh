#!/bin/bash
# Create the local code-signing identity that build.sh signs Claude Accounts with.
#
# Why: macOS keys the Accessibility permission to the app's designated requirement. With an
# ad-hoc signature that requirement is the binary's hash, so every rebuild loses the permission.
# Signed with one fixed identity, the requirement is the bundle identifier plus this certificate,
# and it stays the same from one build to the next.
#
# What it does: makes a self-signed code-signing certificate and private key with openssl,
# imports both into your login keychain, and lets /usr/bin/codesign use the key without asking.
# Nothing leaves this Mac, no trust setting changes, and the certificate stays untrusted, which
# codesign does not need. A second run finds the identity and changes nothing.
#
# What macOS asks: nothing while it runs, and builds sign without a keychain dialog. If a dialog
# ever asks to let codesign use "Imported Private Key", enter your login password and click
# Always Allow. The first build after this signs with the new identity, so remove the app from
# System Settings > Privacy & Security > Accessibility with "-" and add it again, once. Later
# builds keep the permission.
set -euo pipefail

NAME="Claude Accounts Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" | grep -qF "\"$NAME\""; then
  echo "Signing identity already present: $NAME"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.conf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# The .p12 only carries the key into the keychain; its password is random and never kept.
P12_PASS="$(/usr/bin/openssl rand -hex 16)"
export P12_PASS
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout env:P12_PASS -out "$WORK/identity.p12"

# -T lets codesign use the key without a keychain dialog; nothing else may use it unasked.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$P12_PASS" -T /usr/bin/codesign
echo "Created signing identity: $NAME"
