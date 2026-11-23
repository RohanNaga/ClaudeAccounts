#!/bin/bash
# Build the app and zip it into dist/ for a GitHub release; prints the checksum the
# Homebrew cask needs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# build.sh signs with the local identity from scripts/make-signing-identity.sh when this Mac has
# it; that certificate is for this Mac's own builds and must never reach a public download.
if security find-identity -p codesigning | grep -qF '"Claude Accounts Local Signing"'; then
  echo "release.sh: this Mac has the local signing identity, which must not ship; build releases on a Mac without it." >&2
  exit 1
fi

"$ROOT/build.sh"
VERSION="$(defaults read "$ROOT/Claude Accounts.app/Contents/Info.plist" CFBundleShortVersionString)"
ZIP="$ROOT/dist/ClaudeAccounts-$VERSION.zip"
mkdir -p "$ROOT/dist"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/Claude Accounts.app" "$ZIP"
echo "Release: $ZIP"
echo "Version: $VERSION"
echo "sha256:  $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
