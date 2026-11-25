#!/bin/bash
# Build a release copy of the app, signed ad hoc, and zip it into dist/ for a GitHub release;
# prints the version and the checksum the Homebrew cask needs.
#
# It runs on any Mac, including one with the local signing identity from
# scripts/make-signing-identity.sh: the release copy is built in dist/release by
# `build.sh --release`, which always signs ad hoc, and the zip is unpacked and checked to hold no
# certificate before its checksum is printed. This folder's app and a running copy of it are never
# replaced, quit or opened.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd -P)"
OUT="$ROOT/dist/release"
COPY="$OUT/Claude Accounts.app"

step() { echo; echo "==> $1"; }
fail() { echo "release.sh: $1" >&2; exit 1; }

# The app at $1 is signed ad hoc: no certificate, so no authority and no team, and the local
# identity appears nowhere in its signature.
check_ad_hoc() {
  local info requirement
  codesign --verify --strict --deep "$1" || fail "$1 does not verify."
  info="$(codesign -dvvv "$1" 2>&1)" || fail "$1 has no signature that codesign can read."
  requirement="$(codesign -d -r- "$1" 2>&1)" || fail "$1 has no requirement that codesign can read."
  grep -qx 'Signature=adhoc' <<<"$info" || fail "$1 is not signed ad hoc."
  ! grep -q '^Authority=' <<<"$info" || fail "$1 is signed with a certificate: $(grep '^Authority=' <<<"$info" | head -1)"
  ! grep -qF 'Claude Accounts Local Signing' <<<"$info" || fail "$1 carries the local signing identity."
  grep -q 'designated => cdhash' <<<"$requirement" || fail "$1 has a designated requirement other than an ad hoc one."
  echo "$info" | grep -E '^(Identifier|Format|Signature|TeamIdentifier)='
}

step "1/4 Build a release copy in dist/release (this folder's app is left alone)"
rm -rf "$OUT"
"$ROOT/build.sh" --release "$OUT"
VERSION="$(defaults read "$COPY/Contents/Info.plist" CFBundleShortVersionString)"
BUILD="$(defaults read "$COPY/Contents/Info.plist" CFBundleVersion)"
echo "Version $VERSION, build $BUILD"

step "2/4 Check the release copy is signed ad hoc"
check_ad_hoc "$COPY"

step "3/4 Zip it into dist/ClaudeAccounts-$VERSION.zip"
ZIP="$ROOT/dist/ClaudeAccounts-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$COPY" "$ZIP"
echo "$ZIP"

step "4/4 Unpack the zip and check the app in it"
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$ZIP" "$CHECK"
[ "$(ls "$CHECK")" = "Claude Accounts.app" ] || fail "the zip should hold only Claude Accounts.app, and holds: $(ls "$CHECK" | tr '\n' ' ')"
[ "$(defaults read "$CHECK/Claude Accounts.app/Contents/Info.plist" CFBundleShortVersionString)" = "$VERSION" ] \
  || fail "the zip's app is not version $VERSION."
check_ad_hoc "$CHECK/Claude Accounts.app"
lipo -archs "$CHECK/Claude Accounts.app/Contents/MacOS/ClaudeAccounts"
# The zip holds the release copy; a second app with this one's bundle id is not left lying around.
rm -rf "$OUT"

echo
echo "Release: $ZIP"
echo "Version: $VERSION"
echo "sha256:  $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
