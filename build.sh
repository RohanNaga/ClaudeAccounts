#!/bin/bash
# Build "Claude Accounts.app" into this folder. Nothing is installed elsewhere:
# the app keeps its data in ./data beside itself, so this folder is the whole footprint.
# Needs only the Xcode Command Line Tools (swiftc).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Claude Accounts.app"
BIN="$APP/Contents/MacOS/ClaudeAccounts"

# Quit a running copy so the rebuilt binary is the one that launches next.
pkill -x ClaudeAccounts 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Keep swiftc's module cache inside this folder instead of ~/Library/Caches.
export CLANG_MODULE_CACHE_PATH="$ROOT/.build-cache"
swiftc -O -parse-as-library -target arm64-apple-macos14 \
  -module-cache-path "$ROOT/.build-cache" -o "$BIN" "$ROOT/app/ClaudeAccounts.swift"

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
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
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
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Menu bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS runs a locally built app without a developer ID.
codesign --force --sign - "$APP"
echo "Built: $APP"
