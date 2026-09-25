#!/bin/bash
# Build the app and zip it into dist/ for a GitHub release; prints the checksum the
# Homebrew cask needs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
"$ROOT/build.sh"
VERSION="$(defaults read "$ROOT/Claude Accounts.app/Contents/Info.plist" CFBundleShortVersionString)"
ZIP="$ROOT/dist/ClaudeAccounts-$VERSION.zip"
mkdir -p "$ROOT/dist"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/Claude Accounts.app" "$ZIP"
echo "Release: $ZIP"
echo "Version: $VERSION"
echo "sha256:  $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
