#!/bin/bash
# Run the tests: the switching rules in app/Rules.swift, then app/QuitPrompt.swift against a real
# native alert and app/ChatComposer.swift's resume step against a stand-in chat window, both in
# tests/PromptFixture.swift, which flashes small windows for a second or two without taking
# keyboard focus. Needs only swiftc, like build.sh. The fixture tests need Accessibility access
# for the terminal that runs them and are skipped, with a note, without it. A fixture puts a real
# window on screen, and macOS shows Accessibility no window while the screen is locked: then each
# is skipped with that reason, and everything else still runs. The run fails only on a real failure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/.build-cache"
mkdir -p "$OUT"
export CLANG_MODULE_CACHE_PATH="$OUT"

# What the app knows about Claude (app/Claude.swift) and the code that reads Claude's windows.
CORE=("$ROOT/app/Claude.swift" "$ROOT/app/Rules.swift" "$ROOT/app/QuitPrompt.swift" "$ROOT/app/ChatComposer.swift")

# First the guard every stand-in test relies on: a test world never reaches the real Claude. If it
# fails, nothing else runs.
swiftc -parse-as-library -module-cache-path "$OUT" -o "$OUT/world-guard" "${CORE[@]}" "$ROOT/tests/WorldGuardTest.swift"
"$OUT/world-guard"

failed=0
skipped=()
locked=""
if ioreg -n Root -d1 | grep -q '"IOConsoleLocked" = Yes'; then locked="the screen is locked (IOConsoleLocked)"; fi

swiftc -parse-as-library -module-cache-path "$OUT" -o "$OUT/rules-tests" \
  "${CORE[@]}" "$ROOT/tests/RulesTests.swift"
"$OUT/rules-tests" || failed=$((failed + 1))

# The menu's one notice is one line (model, section 11), so a cut-off line must still be readable
# whole: its tooltip carries the full text.
notice=$(awk '/^struct NoticeLine/ {f=1} f {print} f && /^}/ {exit}' "$ROOT/app/Views.swift")
if ! grep -q 'lineLimit(1)' <<<"$notice" || ! grep -q '\.help(notice.detail ?? notice.text)' <<<"$notice"; then
  echo "FAIL: the notice must be one line with its full text as its tooltip"; failed=$((failed + 1))
else
  echo "Notice is one line with its full text on hover: ok"
fi

# Manual Switch, Set Up and the automatic switch run one procedure, which never reads meters:
# a manual switch is the person's call (model, section 6).
section() { awk -v start="$1" '$0 ~ start {f=1; print; next} f && /^(enum|struct|final class|class|extension) / {exit} f' "$ROOT/app/$2"; }
if ! grep -q 'Switch.run(request' <<<"$(section '^final class Store' ClaudeAccounts.swift)" \
   || ! grep -q 'case manual, auto, setUp' <<<"$(section '^struct SwitchJournal' ClaudeAccounts.swift)" \
   || grep -qE 'meters|Usage\.|fullUntil|seatState|isFresh' <<<"$(section '^enum Switch ' ClaudeAccounts.swift)"; then
  echo "FAIL: every switch must run Switch.run, with Set Up as one of its kinds, and Switch must not read usage"; failed=$((failed + 1))
else
  echo "One switch for every way in: ok"
fi

# A fixture test, unless the screen is locked.
fixture() {
  local name=$1; shift
  if [ -n "$locked" ]; then echo "$name skipped: $locked."; skipped+=("$name: $locked"); return; fi
  "$@" || failed=$((failed + 1))
}
swiftc -module-cache-path "$OUT" -o "$OUT/prompt-fixture" "$ROOT/tests/PromptFixture.swift"
swiftc -parse-as-library -module-cache-path "$OUT" -o "$OUT/prompt-test" \
  "${CORE[@]}" "$ROOT/tests/FixtureSupport.swift" "$ROOT/tests/PromptTest.swift"
fixture "Prompt test" "$OUT/prompt-test" "$OUT/prompt-fixture"

swiftc -parse-as-library -module-cache-path "$OUT" -o "$OUT/resume-test" \
  "${CORE[@]}" "$ROOT/tests/FixtureSupport.swift" "$ROOT/tests/ResumeTest.swift"
fixture "Resume test" "$OUT/resume-test" "$OUT/prompt-fixture"

# The end-to-end scenarios (tests/Scenarios.swift): the app's own Store against a stand-in Claude
# on a virtual clock, one (state, event) pair at a time. Each pair runs alone in its own stand-in
# root, several side by side, each stopped after SCENARIO_LIMIT seconds of real time. Pair names
# travel NUL-separated, so any character in a name is safe.
APP_SOURCES=()
for f in "$ROOT"/app/*.swift; do
  case "$(basename "$f")" in Main.swift|make-icon.swift|make-social.swift) ;; *) APP_SOURCES+=("$f") ;; esac
done
SCENARIO_FILES=("$ROOT/tests/StandIn.swift" "$ROOT/tests/SeatSurface.swift" "$ROOT/tests/Scenarios.swift" "$ROOT/tests/BugScenarios.swift" "$ROOT/tests/FaultScenarios.swift" "$ROOT/tests/GapScenarios.swift" "$ROOT/tests/WaitScenarios.swift" "$ROOT/tests/HoldScenarios.swift" "$ROOT/tests/ArrivalScenarios.swift" "$ROOT/tests/QuitScenarios.swift" "$ROOT/tests/ReviewFiveScenarios.swift" "$ROOT/tests/ReviewSixScenarios.swift" "$ROOT/tests/ReviewSevenScenarios.swift")
swiftc -parse-as-library -module-cache-path "$OUT" -o "$OUT/scenarios" "${APP_SOURCES[@]}" "${SCENARIO_FILES[@]}"
# The resume pair drives ChatComposer's own Accessibility code against the chat fixture; with the
# screen locked it has no fixture and reports itself skipped.
if [ -z "$locked" ]; then export CHAT_FIXTURE="$OUT/prompt-fixture"; else unset CHAT_FIXTURE; fi
RESULTS="$OUT/scenario-results"
rm -rf "$RESULTS"; mkdir -p "$RESULTS"
"$OUT/scenarios" --list | awk '{ printf "%03d %s%c", NR, $0, 0 }' \
  | BIN="$OUT/scenarios" D="$RESULTS" LIMIT="${SCENARIO_LIMIT:-120}" xargs -0 -n 1 -P "${SCENARIO_JOBS:-6}" bash -c '
      n=${0%% *}; pair=${0#* }
      r=$(perl -e "alarm $LIMIT; exec @ARGV" "$BIN" "$pair" 2>&1); code=$?
      { grep -v "^Scenarios:" <<<"$r"; if [ $code -ge 128 ]; then echo "TIME $pair: stopped after $LIMIT s real time"; fi; } > "$D/$n"'
cat "$RESULTS"/*
passed=$(cat "$RESULTS"/* | awk '/^ok/ {n++} END {print n+0}')
notPassing=$(cat "$RESULTS"/* | awk '/^(FAIL|TIME|PEND)/ {n++} END {print n+0}')
while IFS= read -r line; do skipped+=("${line#SKIP }"); done < <(cat "$RESULTS"/* | grep '^SKIP' || true)
echo "Scenarios: $passed passed, $notPassing not passing, $(cat "$RESULTS"/* | grep -c '^SKIP' || true) skipped"
for s in ${skipped[@]+"${skipped[@]}"}; do echo "Skipped: $s"; done
[ $((failed + notPassing)) -eq 0 ]
