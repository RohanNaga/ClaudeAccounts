#!/bin/bash
# Run the tests: the switching rules in app/Rules.swift, then app/QuitPrompt.swift against a real
# native alert (tests/PromptFixture.swift), which flashes a small window for a second or two.
# Needs only swiftc, like build.sh. The prompt test needs Accessibility access for the terminal
# that runs it and is skipped, with a note, without it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/.build-cache"
mkdir -p "$OUT"
export CLANG_MODULE_CACHE_PATH="$OUT"

swiftc -parse-as-library -module-cache-path "$OUT" -o "$OUT/rules-tests" \
  "$ROOT/app/Rules.swift" "$ROOT/tests/RulesTests.swift"
"$OUT/rules-tests"

swiftc -module-cache-path "$OUT" -o "$OUT/prompt-fixture" "$ROOT/tests/PromptFixture.swift"
swiftc -parse-as-library -module-cache-path "$OUT" -o "$OUT/prompt-test" \
  "$ROOT/app/QuitPrompt.swift" "$ROOT/tests/PromptTest.swift"
"$OUT/prompt-test" "$OUT/prompt-fixture"
