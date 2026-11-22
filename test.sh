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

# The menu's status line wraps to every line it needs: a cut-off instruction can't be followed.
status=$(grep -A4 'if let msg = store.message {' "$ROOT/app/ClaudeAccounts.swift")
if ! grep -q 'Text(msg).*fixedSize(horizontal: false, vertical: true)' <<<"$status" || grep -qE 'lineLimit|truncationMode' <<<"$status"; then
  echo "FAIL: the menu's status line must wrap (fixedSize vertical, no lineLimit or truncation)"; exit 1
fi
echo "Status line wraps: ok"

# A manual switch is the person's call: a row's action comes from RowAction (tested above), which
# never reads usage, and the switch itself never checks whether the target is out.
section() { awk -v start="$1" '$0 ~ start {f=1; print; next} f && /^(enum|struct|final class|class|extension) / {exit} f' "$ROOT/app/ClaudeAccounts.swift"; }
if ! grep -q 'RowAction.pick' <<<"$(section '^struct AccountRow')" \
   || grep -qE 'isOut|atLimit|MeterRule|AutoSwitchRule' <<<"$(section '^enum SwitchEngine')"; then
  echo "FAIL: a row's action must come from RowAction, and a manual switch must not check the target's usage"; exit 1
fi
echo "Manual switch to any row: ok"

# A confirmed set-up brings the previous row's chats over through the switch's own move and reopen.
if ! grep -q 'moveSessions(from: previous.id' <<<"$(awk '/private static func setUpLocked/,/struct Prepared/' "$ROOT/app/ClaudeAccounts.swift")" \
   || ! grep -q 'await reopen(as: want' <<<"$(awk '/private static func setUpLocked/,/struct Prepared/' "$ROOT/app/ClaudeAccounts.swift")"; then
  echo "FAIL: a confirmed set-up must move the previous row's chats with moveSessions and reopen like a switch"; exit 1
fi
echo "Set up brings the chats: ok"

swiftc -module-cache-path "$OUT" -o "$OUT/prompt-fixture" "$ROOT/tests/PromptFixture.swift"
swiftc -parse-as-library -module-cache-path "$OUT" -o "$OUT/prompt-test" \
  "$ROOT/app/QuitPrompt.swift" "$ROOT/tests/FixtureSupport.swift" "$ROOT/tests/PromptTest.swift"
"$OUT/prompt-test" "$OUT/prompt-fixture"

swiftc -parse-as-library -module-cache-path "$OUT" -o "$OUT/resume-test" \
  "$ROOT/app/Rules.swift" "$ROOT/app/ChatComposer.swift" "$ROOT/tests/FixtureSupport.swift" "$ROOT/tests/ResumeTest.swift"
"$OUT/resume-test" "$OUT/prompt-fixture"
