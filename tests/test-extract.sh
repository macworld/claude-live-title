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

# Text > 300 chars → returned as-is (no truncation at this layer)
LONG=$(python3 -c 'print("a" * 350)')
LINE=$(jq -nc --arg t "$LONG" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}')
T=$(make_transcript "$LINE
")
R=$(extract_last_ai_text "$T")
if [[ ${#R} -eq 350 ]]; then
  report PASS "long text returned raw (no truncation)"
else
  report FAIL "got length ${#R}, expected 350"
fi
rm -f "$T"

# Multi-paragraph → returned as-is (no paragraph split at this layer)
T=$(make_transcript '{"type":"assistant","message":{"content":[{"type":"text","text":"intent here.\n\nDetail paragraph."}]}}
')
R=$(extract_last_ai_text "$T")
EXPECTED=$'intent here.\n\nDetail paragraph.'
[[ "$R" == "$EXPECTED" ]] && report PASS "multi-paragraph returned raw" || report FAIL "got '$R'"
rm -f "$T"

# Last assistant has only tool_use; earlier has text → falls back to earlier
T=$(make_transcript '{"type":"assistant","message":{"content":[{"type":"text","text":"earlier text"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"X","id":"a","input":{}}]}}
')
R=$(extract_last_ai_text "$T")
[[ "$R" == "earlier text" ]] && report PASS "tool-only last → falls back" || report FAIL "got '$R'"
rm -f "$T"

echo ""
echo "=== extract_goal_message ==="

# Goal normal case — first user message
T=$(make_transcript '{"type":"user","message":{"content":"帮我修登录 bug"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"好的"}]}}
{"type":"user","message":{"content":"用 redis 还是 memory"}}
')
R=$(extract_goal_message "$T")
[[ "$R" == "帮我修登录 bug" ]] && report PASS "goal = first user message" || report FAIL "got '$R'"
rm -f "$T"

# No user messages → empty
T=$(make_transcript '{"type":"assistant","message":{"content":[{"type":"text","text":"only AI"}]}}
')
R=$(extract_goal_message "$T")
[[ -z "$R" ]] && report PASS "no user entries → empty" || report FAIL "got '$R'"
rm -f "$T"

# First user entry is a tool_result (type:user with content[0].type:tool_result) → skip to next real user text
T=$(make_transcript '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"output"}]}}
{"type":"user","message":{"content":"实际的第一条用户消息"}}
')
R=$(extract_goal_message "$T")
[[ "$R" == "实际的第一条用户消息" ]] && report PASS "tool_result skipped, next user text wins" || report FAIL "got '$R'"
rm -f "$T"

# Content as array with text block → extract text
T=$(make_transcript '{"type":"user","message":{"content":[{"type":"text","text":"数组形式的第一条"}]}}
')
R=$(extract_goal_message "$T")
[[ "$R" == "数组形式的第一条" ]] && report PASS "array content with text extracted" || report FAIL "got '$R'"
rm -f "$T"

echo ""
echo "=== extract_user_messages exclude ==="

# Three user messages; exclude the first → tail returns only the other two
T=$(make_transcript '{"type":"user","message":{"content":"first goal message"}}
{"type":"user","message":{"content":"second mid"}}
{"type":"user","message":{"content":"third tail"}}
')
R=$(extract_user_messages "$T" "" "first goal message")
if [[ "$R" != *"first goal message"* && "$R" == *"second mid"* && "$R" == *"third tail"* ]]; then
  report PASS "exclude=first removes first from sample"
else
  report FAIL "exclude got '$R'"
fi
rm -f "$T"

# No exclude arg → behaves as before (first message included)
T=$(make_transcript '{"type":"user","message":{"content":"first goal message"}}
{"type":"user","message":{"content":"second mid"}}
')
R=$(extract_user_messages "$T" "")
[[ "$R" == *"first goal message"* ]] && report PASS "no exclude → first still in sample" || report FAIL "no-exclude got '$R'"
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
