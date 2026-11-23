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

# The menu's one notice is one line (model, section 11), so a cut-off line must still be readable
# whole: its tooltip carries the full text.
notice=$(awk '/^struct NoticeLine/ {f=1} f {print} f && /^}/ {exit}' "$ROOT/app/Views.swift")
if ! grep -q 'lineLimit(1)' <<<"$notice" || ! grep -q '\.help(notice.detail ?? notice.text)' <<<"$notice"; then
  echo "FAIL: the notice must be one line with its full text as its tooltip"; exit 1
fi
echo "Notice is one line with its full text on hover: ok"

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

# The end-to-end scenarios (tests/Scenarios.swift): the app's own Store against a stand-in Claude
# on a virtual clock, one (state, event) pair at a time. Each pair runs alone in its own stand-in
# root, several side by side, each stopped after SCENARIO_LIMIT seconds of real time. Pair names
# travel NUL-separated, so any character in a name is safe.
APP_SOURCES=()
for f in "$ROOT"/app/*.swift; do
  case "$(basename "$f")" in Main.swift|make-icon.swift|make-social.swift) ;; *) APP_SOURCES+=("$f") ;; esac
done
SCENARIO_FILES=("$ROOT/tests/StandIn.swift" "$ROOT/tests/SeatSurface.swift" "$ROOT/tests/Scenarios.swift" "$ROOT/tests/BugScenarios.swift")
swiftc -parse-as-library -module-cache-path "$OUT" -o "$OUT/scenarios" "${APP_SOURCES[@]}" "${SCENARIO_FILES[@]}"
# The resume pair drives ChatComposer's own Accessibility code against the chat fixture.
export CHAT_FIXTURE="$OUT/prompt-fixture"
RESULTS="$OUT/scenario-results"
rm -rf "$RESULTS"; mkdir -p "$RESULTS"
"$OUT/scenarios" --list | awk '{ printf "%03d %s%c", NR, $0, 0 }' \
  | BIN="$OUT/scenarios" D="$RESULTS" LIMIT="${SCENARIO_LIMIT:-120}" xargs -0 -n 1 -P "${SCENARIO_JOBS:-6}" bash -c '
      n=${0%% *}; pair=${0#* }
      r=$(perl -e "alarm $LIMIT; exec @ARGV" "$BIN" "$pair" 2>&1); code=$?
      { grep -v "^Scenarios:" <<<"$r"; if [ $code -ge 128 ]; then echo "TIME $pair: stopped after $LIMIT s real time"; fi; } > "$D/$n"'
cat "$RESULTS"/*
passed=$(cat "$RESULTS"/* | awk '/^ok/ {n++} END {print n+0}')
failed=$(cat "$RESULTS"/* | awk '/^(FAIL|TIME|PEND)/ {n++} END {print n+0}')
echo "Scenarios: $passed passed, $failed not passing"
[ "$failed" -eq 0 ]
