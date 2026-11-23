#!/bin/bash
# Draw the menu in fixed states to PNGs with scripts/render-menu.swift, without starting the app.
# Usage: scripts/render-menu.sh [folder]   (default .build-cache/menu)
# Its menu-readme.png is docs/menu.png.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/.build-cache/menu}"
mkdir -p "$ROOT/.build-cache" "$OUT"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build-cache"

swiftc -parse-as-library -module-cache-path "$ROOT/.build-cache" -o "$ROOT/.build-cache/render-menu" \
  "$ROOT/app/ClaudeAccounts.swift" "$ROOT/app/Views.swift" "$ROOT/app/Claude.swift" "$ROOT/app/Rules.swift" \
  "$ROOT/app/QuitPrompt.swift" "$ROOT/app/ChatComposer.swift" "$ROOT/scripts/render-menu.swift"
"$ROOT/.build-cache/render-menu" "$OUT"
