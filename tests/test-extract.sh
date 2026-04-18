#!/usr/bin/env bash
# test-extract.sh — Verify extract_last_ai_text and format_dialog
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
source "$SCRIPT_DIR/hooks/lib/common.sh"
detect_platform

make_transcript() {
  local path
  path="/tmp/test-extract-$$-$RANDOM.jsonl"
  printf '%s' "$1" > "$path"
  echo "$path"
}

echo "=== extract_last_ai_text ==="

# Empty transcript
T=$(make_transcript "")
R=$(extract_last_ai_text "$T")
[[ -z "$R" ]] && report PASS "empty transcript → empty" || report FAIL "empty got '$R'"
rm -f "$T"

# Only user entries
T=$(make_transcript '{"type":"user","message":{"content":"hi"}}
')
R=$(extract_last_ai_text "$T")
[[ -z "$R" ]] && report PASS "user-only → empty" || report FAIL "user-only got '$R'"
rm -f "$T"

# Single assistant with one text block
T=$(make_transcript '{"type":"assistant","message":{"content":[{"type":"text","text":"hello world"}]}}
')
R=$(extract_last_ai_text "$T")
[[ "$R" == "hello world" ]] && report PASS "single AI text" || report FAIL "got '$R'"
rm -f "$T"

# Multiple assistants, last has text+tool_use; expect last text
T=$(make_transcript '{"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"second"},{"type":"tool_use","name":"X","id":"a","input":{}}]}}
')
R=$(extract_last_ai_text "$T")
[[ "$R" == "second" ]] && report PASS "multi-assistant last text wins" || report FAIL "got '$R'"
rm -f "$T"

# Text > 300 chars → truncated with "..."
LONG=$(python3 -c 'print("a" * 350)')
LINE=$(jq -nc --arg t "$LONG" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}')
T=$(make_transcript "$LINE
")
R=$(extract_last_ai_text "$T")
if [[ ${#R} -eq 303 ]] && [[ "${R: -3}" == "..." ]]; then
  report PASS "long text truncated with ..."
else
  report FAIL "got length ${#R}, tail '${R: -3}'"
fi
rm -f "$T"

# Multi-paragraph → first paragraph only
T=$(make_transcript '{"type":"assistant","message":{"content":[{"type":"text","text":"intent here.\n\nDetail paragraph."}]}}
')
R=$(extract_last_ai_text "$T")
[[ "$R" == "intent here." ]] && report PASS "multi-paragraph → first only" || report FAIL "got '$R'"
rm -f "$T"

# Last assistant has only tool_use; earlier has text → falls back to earlier
T=$(make_transcript '{"type":"assistant","message":{"content":[{"type":"text","text":"earlier text"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"X","id":"a","input":{}}]}}
')
R=$(extract_last_ai_text "$T")
[[ "$R" == "earlier text" ]] && report PASS "tool-only last → falls back" || report FAIL "got '$R'"
rm -f "$T"

echo ""
echo "=== format_dialog ==="

# USER + AI labels
R=$(format_dialog "hello
world" "AI said this")
EXPECTED="USER: hello
USER: world
AI: AI said this"
[[ "$R" == "$EXPECTED" ]] && report PASS "USER + AI labels" || report FAIL "mismatch: got '$R'"

# USER + empty AI → only USER lines, no trailing AI
R=$(format_dialog "hello" "")
[[ "$R" == "USER: hello" ]] && report PASS "empty AI → no AI line" || report FAIL "got '$R'"

# Multi-line USER → each line prefixed; blank lines dropped
R=$(format_dialog "line1
line2
line3" "")
EXPECTED="USER: line1
USER: line2
USER: line3"
[[ "$R" == "$EXPECTED" ]] && report PASS "each line prefixed" || report FAIL "got '$R'"

# Only AI, no user content → AI line only
R=$(format_dialog "" "only ai here")
[[ "$R" == "AI: only ai here" ]] && report PASS "empty user + AI → AI only" || report FAIL "got '$R'"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && echo "All tests passed!" || exit 1
