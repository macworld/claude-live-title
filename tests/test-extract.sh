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

# Multi-line first user message → flattened to a single line, all content preserved
T=$(make_transcript '{"type":"user","message":{"content":"帮我修\n登录 bug"}}
{"type":"user","message":{"content":"第二条"}}
')
R=$(extract_goal_message "$T")
[[ "$R" == "帮我修 登录 bug" ]] && report PASS "multi-line goal flattened to single line" || report FAIL "got '$R'"
rm -f "$T"

# Multi-line goal with a fenced block → fence text preserved verbatim (sanitize is not goal's job)
T=$(make_transcript '{"type":"user","message":{"content":"帮我看这段\n```python\nx=1\n```\n出错了"}}
')
R=$(extract_goal_message "$T")
if [[ "$R" == *"帮我看这段"* && "$R" == *'```python'* && "$R" == *"x=1"* && "$R" == *"出错了"* && "$R" != *$'\n'* ]]; then
  report PASS "multi-line goal with fence preserved verbatim and flattened"
else
  report FAIL "fence-preservation got '$R'"
fi
rm -f "$T"

# system-reminder block stripped, real content preserved (block-mode strip)
T=$(make_transcript '{"type":"user","message":{"content":"<system-reminder>\nrunning hook X\nmore reminder text\n</system-reminder>\n实际的用户问题"}}
')
R=$(extract_goal_message "$T")
if [[ "$R" == "实际的用户问题" && "$R" != *"running hook X"* && "$R" != *"system-reminder"* ]]; then
  report PASS "system-reminder block stripped from goal"
else
  report FAIL "reminder-strip got '$R'"
fi
rm -f "$T"

# Multi-line tool_result-only first entry skipped, multi-line second entry returned as flat goal
T=$(make_transcript '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"some output"}]}}
{"type":"user","message":{"content":"第二条\n包含两行"}}
')
R=$(extract_goal_message "$T")
[[ "$R" == "第二条 包含两行" ]] && report PASS "tool_result skipped, multi-line next entry flattened" || report FAIL "got '$R'"
rm -f "$T"

echo ""
echo "=== _cap_chars (UTF-8 char-aware truncation) ==="

# ASCII shorter than max — no change
R=$(printf '%s' "hello" | _cap_chars 10)
[[ "$R" == "hello" ]] && report PASS "ASCII < max unchanged" || report FAIL "got '$R'"

# ASCII exactly max — boundary, no truncation
R=$(printf '%s' "hello" | _cap_chars 5)
[[ "$R" == "hello" ]] && report PASS "ASCII == max unchanged" || report FAIL "got '$R'"

# ASCII longer than max — appends "..."
R=$(printf '%s' "hello world" | _cap_chars 5)
[[ "$R" == "hello..." ]] && report PASS "ASCII > max truncated with ..." || report FAIL "got '$R'"

# CJK longer than max — char-aware (not byte) truncation
R=$(printf '%s' "中文中文" | _cap_chars 2)
[[ "$R" == "中文..." ]] && report PASS "CJK truncation char-aware" || report FAIL "got '$R'"

# Mixed ASCII + CJK at boundary — no mid-char split
R=$(printf '%s' "ASCII中文" | _cap_chars 6)
[[ "$R" == "ASCII中..." ]] && report PASS "mixed ASCII+CJK boundary safe" || report FAIL "got '$R'"

# Mixed input exactly at max
R=$(printf '%s' "ASCII中文" | _cap_chars 7)
[[ "$R" == "ASCII中文" ]] && report PASS "mixed exactly at max" || report FAIL "got '$R'"

# Empty input → empty output
R=$(printf '' | _cap_chars 10)
[[ -z "$R" ]] && report PASS "empty input → empty" || report FAIL "got '$R'"

# Suffix-override: empty suffix on truncation
R=$(printf '%s' "hello world" | _cap_chars 5 '')
[[ "$R" == "hello" ]] && report PASS "empty suffix omits trailing marker" || report FAIL "got '$R'"

# Run under LC_ALL=C — must still produce char-correct CJK truncation
R=$(LC_ALL=C bash -c "source $SCRIPT_DIR/hooks/lib/common.sh; printf '%s' '中文中文' | _cap_chars 2")
[[ "$R" == "中文..." ]] && report PASS "CJK truncation works under LC_ALL=C" || report FAIL "LC=C got '$R'"

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

# Multi-line user entry → flattened to one line so format_dialog labels it once
T=$(make_transcript '{"type":"user","message":{"content":"first goal"}}
{"type":"user","message":{"content":"multi\nline\nuser"}}
')
R=$(extract_user_messages "$T" "")
N=$(printf '%s\n' "$R" | wc -l | tr -d ' ')
if [[ "$N" -eq 2 && "$R" == *"first goal"* && "$R" == *"multi line user"* ]]; then
  report PASS "multi-line user entry flattened to one line"
else
  report FAIL "multi-line user got (lines=$N): '$R'"
fi
rm -f "$T"

# Multi-line GOAL passed as exclude is flattened before grep -vxF
T=$(make_transcript '{"type":"user","message":{"content":"goal\nspans two"}}
{"type":"user","message":{"content":"another"}}
')
R=$(extract_user_messages "$T" "" $'goal\nspans two')
if [[ "$R" != *"goal spans two"* && "$R" == *"another"* ]]; then
  report PASS "multi-line exclude flattened before dedup"
else
  report FAIL "multi-line exclude got '$R'"
fi
rm -f "$T"

# After Task 1.1 GOAL is single-line. A multi-line user entry whose flattened form
# equals that single-line GOAL must be excluded — the real end-to-end dedup case.
T=$(make_transcript '{"type":"user","message":{"content":"goal\nspans two"}}
{"type":"user","message":{"content":"another"}}
')
R=$(extract_user_messages "$T" "" "goal spans two")
N=$(printf '%s\n' "$R" | wc -l | tr -d ' ')
if [[ "$N" -eq 1 && "$R" == "another" ]]; then
  report PASS "single-line exclude vs multi-line user entry"
else
  report FAIL "flat-exclude got (lines=$N): '$R'"
fi
rm -f "$T"

# system-reminder block within a user entry stripped (block-mode)
T=$(make_transcript '{"type":"user","message":{"content":"<system-reminder>\nhook ran with X\nmore reminder text\n</system-reminder>\n实际内容"}}
')
R=$(extract_user_messages "$T" "")
if [[ "$R" == "实际内容" && "$R" != *"hook ran"* ]]; then
  report PASS "system-reminder block stripped from user entry"
else
  report FAIL "user-reminder got '$R'"
fi
rm -f "$T"

# local-command-stdout block stripped (block-mode)
T=$(make_transcript '{"type":"user","message":{"content":"<local-command-stdout>\nlots of output\nmore output\n</local-command-stdout>\n实际问题"}}
')
R=$(extract_user_messages "$T" "")
if [[ "$R" == "实际问题" && "$R" != *"output"* ]]; then
  report PASS "local-command-stdout block stripped from user entry"
else
  report FAIL "stdout-block got '$R'"
fi
rm -f "$T"

echo ""
echo "=== format_dialog (goal, users, state) ==="

# Full: GOAL + USER + STATE
R=$(format_dialog "the goal" $'user one\nuser two' "state content here")
EXPECTED=$'GOAL: the goal\nUSER: user one\nUSER: user two\nSTATE: state content here'
[[ "$R" == "$EXPECTED" ]] && report PASS "GOAL + USER + STATE" || report FAIL "full got: $R"

# No STATE
R=$(format_dialog "the goal" "user one" "")
EXPECTED=$'GOAL: the goal\nUSER: user one'
[[ "$R" == "$EXPECTED" ]] && report PASS "GOAL + USER, no STATE" || report FAIL "no-state got: $R"

# GOAL only
R=$(format_dialog "just the goal" "" "")
[[ "$R" == "GOAL: just the goal" ]] && report PASS "GOAL only" || report FAIL "goal-only got: $R"

# GOAL + STATE (no USER in between)
R=$(format_dialog "the goal" "" "state content")
EXPECTED=$'GOAL: the goal\nSTATE: state content'
[[ "$R" == "$EXPECTED" ]] && report PASS "GOAL + STATE (skip USER)" || report FAIL "goal+state got: $R"

# Empty USER content with blank line → blank filtered
R=$(format_dialog "g" $'user one\n\nuser two' "s")
EXPECTED=$'GOAL: g\nUSER: user one\nUSER: user two\nSTATE: s'
[[ "$R" == "$EXPECTED" ]] && report PASS "blank USER lines dropped" || report FAIL "blank-drop got: $R"

# All empty → empty output
R=$(format_dialog "" "" "")
[[ -z "$R" ]] && report PASS "all-empty → empty" || report FAIL "all-empty got: $R"

# Multi-line GOAL flattened to one labeled line
R=$(format_dialog $'goal line one\ngoal line two' "user one" "state content")
EXPECTED=$'GOAL: goal line one goal line two\nUSER: user one\nSTATE: state content'
[[ "$R" == "$EXPECTED" ]] && report PASS "multi-line GOAL flattened" || report FAIL "multi-goal got: $R"

# Multi-line STATE flattened to one labeled line
R=$(format_dialog "g" "user one" $'state line one\nstate line two')
EXPECTED=$'GOAL: g\nUSER: user one\nSTATE: state line one state line two'
[[ "$R" == "$EXPECTED" ]] && report PASS "multi-line STATE flattened" || report FAIL "multi-state got: $R"

# GOAL with embedded tabs and CR collapsed to single spaces
R=$(format_dialog $'tabbed\tgoal\rwith CR' "" "")
[[ "$R" == "GOAL: tabbed goal with CR" ]] && report PASS "tab/CR in GOAL flattened" || report FAIL "tab/CR got: $R"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && echo "All tests passed!" || exit 1
