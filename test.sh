#!/bin/bash
# Run the tests: the switching rules in app/Rules.swift, then app/QuitPrompt.swift against a real
# native alert and app/ChatComposer.swift's resume step against a stand-in chat window, both in
# tests/PromptFixture.swift, which flashes small windows for a second or two without taking
# keyboard focus. Needs only swiftc, like build.sh. The fixture tests need Accessibility access
# for the terminal that runs them and are skipped, with a note, without it.
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
  "$ROOT/app/QuitPrompt.swift" "$ROOT/tests/FixtureSupport.swift" "$ROOT/tests/PromptTest.swift"
"$OUT/prompt-test" "$OUT/prompt-fixture"

swiftc -parse-as-library -module-cache-path "$OUT" -o "$OUT/resume-test" \
  "$ROOT/app/Rules.swift" "$ROOT/app/ChatComposer.swift" "$ROOT/tests/FixtureSupport.swift" "$ROOT/tests/ResumeTest.swift"
"$OUT/resume-test" "$OUT/prompt-fixture"
