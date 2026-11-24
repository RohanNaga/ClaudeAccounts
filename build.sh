#!/bin/bash
# Build "Claude Accounts.app" into this folder, as one binary for Apple Silicon and Intel.
# The app keeps its state in ~/Library/Application Support/ClaudeAccounts.
# Needs only the Xcode Command Line Tools (swiftc).
#
# The new app is built, signed and checked beside the installed one before anything is replaced,
# so a build that fails leaves the installed app, and a running copy of it, as they were.
set -euo pipefail

VERSION="0.3.0"
BUILD="12"
ROOT="$(cd "$(dirname "$0")" && pwd -P)"
APP="$ROOT/Claude Accounts.app"
BIN="$APP/Contents/MacOS/ClaudeAccounts"
# The new build and the set-aside old one stay on the same volume as $APP, so each swap is a rename.
NEW="$ROOT/.build-cache/new.app"
OLD="$ROOT/.build-cache/old.app"

# Stop with one line saying why.
fail() {
  rm -rf "$NEW"
  echo "$1" >&2
  exit 1
}

# The processes running this folder's app, matched by their full executable path, so a copy
# installed anywhere else is never touched.
running_pids() {
  ps -axo pid=,comm= | awk -v bin="$BIN" '{ pid = $1; sub(/^ *[0-9]+ /, "") } $0 == bin { print pid }'
}

# Whether macOS reports this process as an app that has finished launching and not quit. ps keeps
# listing an app that exits while it starts for a moment, so its pid alone does not show it started.
finished_launching() {
  [ "$(osascript -l JavaScript -e "ObjC.import('AppKit'); var app = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($1); !app.isNil() && app.finishedLaunching && !app.terminated" 2>/dev/null)" = true ]
}

# Wait up to about 10 s until exactly one process runs this folder's app and it has finished launching.
started() {
  local deadline=$((SECONDS + 10)) pids
  while [ "$SECONDS" -lt "$deadline" ]; do
    pids="$(running_pids)"
    [ -n "$pids" ] && [ "$(wc -l <<<"$pids")" -eq 1 ] && finished_launching "$pids" && return 0
    sleep 0.1
  done
  return 1
}

# Ask one process to quit, as the Quit menu item does, and wait until it has. It stops the build
# rather than force it.
quit_running_copy() {
  local pid="$1"
  osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate" \
    >/dev/null 2>&1 || kill -TERM "$pid"
  for _ in $(seq 1 100); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  fail "Claude Accounts did not quit. Quit it from its menu, then run this again."
}

# macOS keys the Accessibility permission to this requirement. codesign prints an ad hoc one,
# which it derives rather than stores, behind a "# ". It fails when there is none to read.
designated_requirement() {
  codesign -d -r- "$1" 2>/dev/null | sed -nE 's/^(# )?designated => //p' | grep .
}

# Put the old app back if it is out of place, and reopen it if it was running and nothing runs
# it now. Every exit from the quit on runs this, except the success paths, which clear it.
put_back() {
  trap - EXIT INT TERM
  if [ ! -e "$APP" ] && [ -e "$OLD" ]; then mv "$OLD" "$APP"; fi
  if [ "$WAS_RUNNING" = true ] && [ -z "$(running_pids)" ]; then open "$APP"; fi
  exit 1
}

rm -rf "$NEW"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"

# Keep swiftc's module cache inside this folder instead of ~/Library/Caches.
export CLANG_MODULE_CACHE_PATH="$ROOT/.build-cache"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos15" \
    -module-cache-path "$ROOT/.build-cache" -o "$ROOT/.build-cache/ClaudeAccounts-$arch" \
    "$ROOT/app/Main.swift" "$ROOT/app/ClaudeAccounts.swift" "$ROOT/app/Views.swift" "$ROOT/app/Claude.swift" "$ROOT/app/Rules.swift" "$ROOT/app/QuitPrompt.swift" "$ROOT/app/ChatComposer.swift" \
    || fail "The app did not compile, so the installed app was left as it was."
done
lipo -create -output "$NEW/Contents/MacOS/ClaudeAccounts" "$ROOT/.build-cache/ClaudeAccounts-arm64" "$ROOT/.build-cache/ClaudeAccounts-x86_64" \
  || fail "The app did not compile, so the installed app was left as it was."

# The icon is drawn by app/make-icon.swift; regenerate it by deleting app/AppIcon.icns.
ICON="$ROOT/app/AppIcon.icns"
if [ ! -f "$ICON" ]; then
  SET="$ROOT/.build-cache/AppIcon.iconset"
  rm -rf "$SET" && mkdir -p "$SET"
  swift -module-cache-path "$ROOT/.build-cache" "$ROOT/app/make-icon.swift" "$ROOT/.build-cache/icon-1024.png"
  for px in 16 32 128 256 512; do
    sips -z $px $px "$ROOT/.build-cache/icon-1024.png" --out "$SET/icon_${px}x${px}.png" >/dev/null
    sips -z $((px * 2)) $((px * 2)) "$ROOT/.build-cache/icon-1024.png" --out "$SET/icon_${px}x${px}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$ICON"
fi
cp "$ICON" "$NEW/Contents/Resources/AppIcon.icns"

cat > "$NEW/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Accounts</string>
  <key>CFBundleDisplayName</key><string>Claude Accounts</string>
  <key>CFBundleIdentifier</key><string>com.rohan.claude-accounts</string>
  <key>CFBundleExecutable</key><string>ClaudeAccounts</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <!-- Menu bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Sign with the fixed local identity from scripts/make-signing-identity.sh when it exists, so the
# Accessibility permission survives rebuilds; otherwise ad hoc, which macOS also runs locally.
IDENTITY="Claude Accounts Local Signing"
if security find-identity -p codesigning | grep -qF "\"$IDENTITY\""; then
  echo "Signing with: $IDENTITY"
  codesign --force --sign "$IDENTITY" "$NEW" || fail "The new build could not be signed, so the installed app was left as it was."
else
  echo "Signing ad hoc (run scripts/make-signing-identity.sh to keep Accessibility across builds)"
  codesign --force --sign - "$NEW" || fail "The new build could not be signed, so the installed app was left as it was."
fi
codesign --verify --strict "$NEW" || fail "The new build's signature does not verify, so the installed app was left as it was."

# An ad hoc requirement is a hash that changes with every build, so it has no permission to keep.
# Any other must stay the same, or the installed app's Accessibility permission would be lost.
INSTALLED_REQUIREMENT=""
if [ -e "$APP" ]; then
  INSTALLED_REQUIREMENT="$(designated_requirement "$APP")" \
    || fail "The installed app's signature could not be read, so it was left as it was. To replace it anyway, quit it, delete it and run build.sh again."
fi
case "$INSTALLED_REQUIREMENT" in
  "" | cdhash*) ;;
  *) [ "$(designated_requirement "$NEW")" = "$INSTALLED_REQUIREMENT" ] \
       || fail "The new build is signed differently from the installed app and would lose its Accessibility permission, so the installed app was left as it was. To replace it anyway, quit it, delete it and run build.sh again." ;;
esac

# Swap the checked build in. A running copy quits first; if it will not, nothing changes.
rm -rf "$OLD" 2>/dev/null \
  || fail "$OLD is left from an earlier build and could not be deleted, so the installed app was left as it was. Delete it, then run this again."
WAS_RUNNING=false
trap put_back EXIT INT TERM
for pid in $(running_pids); do
  WAS_RUNNING=true
  quit_running_copy "$pid"
done
if [ -d "$APP" ]; then mv "$APP" "$OLD"; fi
mv "$NEW" "$APP"

if [ "$WAS_RUNNING" = false ]; then
  trap - EXIT INT TERM
  rm -rf "$OLD"
  echo "Installed: $APP"
  echo "Claude Accounts was not running, so it was left closed."
elif open "$APP" && started; then
  trap - EXIT INT TERM
  rm -rf "$OLD"
  echo "Installed: $APP"
  echo "Reopened Claude Accounts."
else
  # The new build did not start: stop whatever is left of it, put the old one back and reopen it.
  for pid in $(running_pids); do kill -KILL "$pid" 2>/dev/null || true; done
  mv "$APP" "$NEW"
  mv "$OLD" "$APP"
  if open "$APP" && started; then
    fail "The new build did not start, so the previous one was put back and reopened."
  fi
  fail "The new build did not start, and the previous one, put back, did not start either."
fi
