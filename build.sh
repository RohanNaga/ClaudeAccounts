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
mkdir -p "$APP/Contents/MacOS"

# Keep swiftc's module cache inside this folder instead of ~/Library/Caches.
export CLANG_MODULE_CACHE_PATH="$ROOT/.build-cache"
swiftc -O -parse-as-library -target arm64-apple-macos14 \
  -module-cache-path "$ROOT/.build-cache" -o "$BIN" "$ROOT/app/ClaudeAccounts.swift"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Accounts</string>
  <key>CFBundleDisplayName</key><string>Claude Accounts</string>
  <key>CFBundleIdentifier</key><string>com.rohan.claude-accounts</string>
  <key>CFBundleExecutable</key><string>ClaudeAccounts</string>
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
