#!/usr/bin/env bash
# test-config.sh — load_config defaults, overrides, validation, migration.
# Runs against a throwaway CLAUDE_PLUGIN_DATA and HOME so the real config is
# never touched.
set -eu

PASS=0
FAIL=0
report() {
  local status="$1" desc="$2"
  if [[ "$status" == "PASS" ]]; then
    echo "  ✓ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"
    FAIL=$((FAIL + 1))
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export CLAUDE_PLUGIN_DATA="$TMP/data"
mkdir -p "$HOME" "$CLAUDE_PLUGIN_DATA"
CONFIG="$CLAUDE_PLUGIN_DATA/config.json"

# Load config in a fresh shell and print the resolved values on one line.
resolved() {
  bash -c 'source "$1/hooks/lib/common.sh"; load_config
    echo "$MODEL|$LANGUAGE|$MAX_LENGTH|$HEAD_MESSAGES|$TAIL_MESSAGES|$THROTTLE_INTERVAL|$LIVE_UPDATE|$DEBUG"' _ "$SCRIPT_DIR"
}

expect() {
  local desc="$1" expected="$2" actual
  actual=$(resolved)
  if [[ "$actual" == "$expected" ]]; then
    report PASS "$desc"
  else
    report FAIL "$desc — expected [$expected] got [$actual]"
  fi
}

echo "=== defaults ==="
rm -f "$CONFIG"
expect "no config file → defaults" "haiku|auto|30|1|5|60|true|false"
echo '{}' > "$CONFIG"
expect "empty object → defaults" "haiku|auto|30|1|5|60|true|false"

echo ""
echo "=== overrides ==="
echo '{"model":"sonnet","language":"zh","maxLength":40,"contextMessages":{"head":2,"tail":3},"throttleInterval":120,"liveUpdate":false,"debug":true}' > "$CONFIG"
expect "every field overridden" "sonnet|zh|40|2|3|120|false|true"
echo '{"liveUpdate":false}' > "$CONFIG"
expect "explicit liveUpdate:false survives (jq // would drop it)" "haiku|auto|30|1|5|60|false|false"
echo '{"contextMessages":{"tail":0}}' > "$CONFIG"
expect "tail 0 allowed" "haiku|auto|30|1|0|60|true|false"
echo '{"throttleMessages":2}' > "$CONFIG"
expect "retired throttleMessages is ignored" "haiku|auto|30|1|5|60|true|false"

echo ""
echo "=== validation ==="
echo '{"maxLength":"long","throttleInterval":-5,"liveUpdate":"yes","debug":1,"model":""}' > "$CONFIG"
expect "bad values fall back to defaults" "haiku|auto|30|1|5|60|true|false"
echo '{"contextMessages":5}' > "$CONFIG"
expect "pre-1.0.1 numeric contextMessages → defaults" "haiku|auto|30|1|5|60|true|false"
echo '{"maxLength":0}' > "$CONFIG"
expect "maxLength 0 rejected" "haiku|auto|30|1|5|60|true|false"
echo 'not json' > "$CONFIG"
expect "unparseable file → defaults" "haiku|auto|30|1|5|60|true|false"
echo '[1,2]' > "$CONFIG"
expect "non-object JSON → defaults" "haiku|auto|30|1|5|60|true|false"

echo ""
echo "=== style (custom naming rules) ==="
# style_of [project_dir]: STYLE after load_config (+ load_project_style),
# newlines shown as ⏎ so the comparison stays on one line.
style_of() {
  bash -c 'source "$1/hooks/lib/common.sh"; load_config; [[ -n "$2" ]] && load_project_style "$2"
    printf "%s" "$STYLE" | awk "{ printf \"%s%s\", (NR > 1 ? \"⏎\" : \"\"), \$0 }"' _ "$SCRIPT_DIR" "${1-}"
}
check_style() { local d="$1" e="$2" a; a=$(style_of "${3-}"); if [[ "$a" == "$e" ]]; then report PASS "$d"; else report FAIL "$d — expected [$e] got [$a]"; fi; }

rm -f "$CONFIG"
check_style "no config → no style" ""
echo '{"style":"Start with the ticket ID, like PROJ-123."}' > "$CONFIG"
check_style "style string is used" "Start with the ticket ID, like PROJ-123."
echo '{"style":"- type prefix: feat, fix, docs\n- then a short summary"}' > "$CONFIG"
check_style "multi-line style keeps its lines" "- type prefix: feat, fix, docs⏎- then a short summary"
echo '{"style":["not","a","string"]}' > "$CONFIG"
check_style "non-string style ignored" ""
echo '{"style":"   \n\t "}' > "$CONFIG"
check_style "whitespace-only style ignored" ""
echo '{"style":"Use | pipes and\ttabs","maxLength":40}' > "$CONFIG"
check_style "style with separators: kept" "Use | pipes and tabs"
expect "style doesn't disturb the other fields" "haiku|auto|40|1|5|60|true|false"
jq -n '{style: ("x" * 1500)}' > "$CONFIG"
check_style "style capped at 1000 characters" "$(printf 'x%.0s' $(seq 1 1000))"

PROJ="$TMP/project"
mkdir -p "$PROJ/.claude"
echo '{"style":"Global rule"}' > "$CONFIG"
check_style "no project file → configured style" "Global rule" "$PROJ"
printf 'Team rule: start with the Jira key.\nKeep it in English.\n' > "$PROJ/.claude/live-title.md"
check_style "project .claude/live-title.md replaces the configured style" "Team rule: start with the Jira key.⏎Keep it in English." "$PROJ"
mkdir -p "$TMP/elsewhere"
check_style "cwd without a project file → configured style" "Global rule" "$TMP/elsewhere"
OUT=$(CLAUDE_PROJECT_DIR="$PROJ" style_of "$TMP/elsewhere")
[[ "$OUT" == "Team rule: start with the Jira key.⏎Keep it in English." ]] \
  && report PASS "CLAUDE_PROJECT_DIR wins over the hook's cwd" || report FAIL "CLAUDE_PROJECT_DIR ignored — got [$OUT]"
printf '  \n\n' > "$PROJ/.claude/live-title.md"
check_style "blank project file → configured style" "Global rule" "$PROJ"
rm -f "$CONFIG"
printf 'y%.0s' $(seq 1 1500) > "$PROJ/.claude/live-title.md"
check_style "project file capped at 1000 characters" "$(printf 'y%.0s' $(seq 1 1000))" "$PROJ"
# A cloned repo could point the file at something private outside it.
echo 'secret outside the project' > "$TMP/private.txt"
rm -f "$PROJ/.claude/live-title.md"
ln -s "$TMP/private.txt" "$PROJ/.claude/live-title.md"
check_style "symlinked project file ignored" "" "$PROJ"
rm -rf "$PROJ"

echo ""
echo "=== legacy migration ==="
rm -f "$CONFIG"
mkdir -p "$HOME/.claude/plugins/claude-live-title"
echo '{"language":"ja"}' > "$HOME/.claude/plugins/claude-live-title/config.json"
expect "legacy config is migrated and read" "haiku|ja|30|1|5|60|true|false"
if [[ -f "$CONFIG" ]] && grep -q '"ja"' "$CONFIG"; then
  report PASS "legacy config copied into CLAUDE_PLUGIN_DATA"
else
  report FAIL "legacy config not copied"
fi

echo ""
echo "=== migration from the claude-live-title data dir (renamed in 2.0) ==="
OLD="$TMP/plugins-data/claude-live-title-mkt"
NEW="$TMP/plugins-data/live-title-mkt"
mkdir -p "$OLD/sessions"
echo '{"language":"ko"}' > "$OLD/config.json"
echo '{"latest":"Old title","history":["Old title"],"lastGen":1,"lastHumanCount":2}' > "$OLD/sessions/abc.json"
: > "$OLD/sessions/def.pinned"
mkdir "$OLD/sessions/abc.lock"
LANG_SEEN=$(CLAUDE_PLUGIN_DATA="$NEW" bash -c 'source "$1/hooks/lib/common.sh"; load_config; echo "$LANGUAGE"' _ "$SCRIPT_DIR")
check_eq() { if [[ "$2" == "$3" ]]; then report PASS "$1"; else report FAIL "$1 — expected [$2] got [$3]"; fi; }
check_eq "old config is used after the rename" "ko" "$LANG_SEEN"
check_eq "session state copied" "Old title" "$(jq -r .latest "$NEW/sessions/abc.json" 2>/dev/null)"
check_eq "pins copied" "yes" "$([[ -f "$NEW/sessions/def.pinned" ]] && echo yes || echo no)"
check_eq "locks not copied" "no" "$([[ -e "$NEW/sessions/abc.lock" ]] && echo yes || echo no)"
check_eq "old data dir left in place" "yes" "$([[ -f "$OLD/config.json" ]] && echo yes || echo no)"
echo '{"language":"fr"}' > "$NEW/config.json"
echo '{"language":"de"}' > "$OLD/config.json"
LANG_SEEN=$(CLAUDE_PLUGIN_DATA="$NEW" bash -c 'source "$1/hooks/lib/common.sh"; load_config; echo "$LANGUAGE"' _ "$SCRIPT_DIR")
check_eq "migration runs once; later changes win" "fr" "$LANG_SEEN"
LEFTOVER=$(ls -A "$NEW" "$NEW/sessions" | grep -c '\.tmp$' || true)
check_eq "no temp files left behind" "0" "$LEFTOVER"

echo ""
echo "=== unknown keys ==="
# A typo in a key would otherwise be a silent no-op.
LOG="$TMP/debug.log"
rm -f "$LOG"
echo '{"debug":true,"maxlength":40,"throttleMessages":2}' > "$CONFIG"
CLAUDE_LIVE_TITLE_DEBUG_LOG="$LOG" resolved >/dev/null
if grep -q 'unknown' "$LOG" 2>/dev/null && grep -q 'maxlength' "$LOG" && grep -q 'throttleMessages' "$LOG"; then
  report PASS "unknown keys are named in the debug log"
else
  report FAIL "unknown keys not logged: $(cat "$LOG" 2>/dev/null | tr '\n' ' ')"
fi
rm -f "$LOG"
echo '{"debug":true,"language":"en","contextMessages":{"head":2},"style":"x"}' > "$CONFIG"
CLAUDE_LIVE_TITLE_DEBUG_LOG="$LOG" resolved >/dev/null
grep -q 'unknown' "$LOG" 2>/dev/null && report FAIL "known keys reported as unknown: $(grep unknown "$LOG")" || report PASS "known keys only: nothing reported"
rm -f "$LOG" "$CONFIG"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && echo "All tests passed!" || exit 1
