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

# What the app knows about Claude (app/Claude.swift) and the code that reads Claude's windows.
CORE=("$ROOT/app/Claude.swift" "$ROOT/app/Rules.swift" "$ROOT/app/QuitPrompt.swift" "$ROOT/app/ChatComposer.swift")

# First the guard every stand-in test relies on: a test world never reaches the real Claude.
swiftc -parse-as-library -module-cache-path "$OUT" -o "$OUT/world-guard" "${CORE[@]}" "$ROOT/tests/WorldGuardTest.swift"
"$OUT/world-guard"

swiftc -parse-as-library -module-cache-path "$OUT" -o "$OUT/rules-tests" \
  "${CORE[@]}" "$ROOT/tests/RulesTests.swift"
"$OUT/rules-tests"

# The menu's status line wraps to every line it needs: a cut-off instruction can't be followed.
status=$(grep -A4 'if let msg = store.message {' "$ROOT/app/Views.swift")
if ! grep -q 'Text(msg).*fixedSize(horizontal: false, vertical: true)' <<<"$status" || grep -qE 'lineLimit|truncationMode' <<<"$status"; then
  echo "FAIL: the menu's status line must wrap (fixedSize vertical, no lineLimit or truncation)"; exit 1
fi
echo "Status line wraps: ok"

# Manual Switch, Set Up and the automatic switch run one procedure, which never reads meters:
# a manual switch is the person's call (model, section 6).
section() { awk -v start="$1" '$0 ~ start {f=1; print; next} f && /^(enum|struct|final class|class|extension) / {exit} f' "$ROOT/app/$2"; }
if ! grep -q 'Switch.run(request' <<<"$(section '^final class Store' ClaudeAccounts.swift)" \
   || ! grep -q 'case manual, auto, setUp' <<<"$(section '^struct SwitchJournal' ClaudeAccounts.swift)" \
   || grep -qE 'meters|Usage\.|OutRule|isFresh' <<<"$(section '^enum Switch ' ClaudeAccounts.swift)"; then
  echo "FAIL: every switch must run Switch.run, with Set Up as one of its kinds, and Switch must not read usage"; exit 1
fi
echo "One switch for every way in: ok"

swiftc -module-cache-path "$OUT" -o "$OUT/prompt-fixture" "$ROOT/tests/PromptFixture.swift"
swiftc -parse-as-library -module-cache-path "$OUT" -o "$OUT/prompt-test" \
  "${CORE[@]}" "$ROOT/tests/FixtureSupport.swift" "$ROOT/tests/PromptTest.swift"
"$OUT/prompt-test" "$OUT/prompt-fixture"

swiftc -parse-as-library -module-cache-path "$OUT" -o "$OUT/resume-test" \
  "${CORE[@]}" "$ROOT/tests/FixtureSupport.swift" "$ROOT/tests/ResumeTest.swift"
"$OUT/resume-test" "$OUT/prompt-fixture"
