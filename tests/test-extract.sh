#!/usr/bin/env bash
# test-extract.sh — transcript readers and dialog assembly:
# extract_human_messages / prompt_human_text / find_prompt_entry /
# extract_last_ai_text / list_custom_titles / build_dialog.
# Fixture lines mirror the entry shapes Claude Code actually writes.
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
export HOME="$TMP/home" CLAUDE_PLUGIN_DATA="$TMP/data"
source "$SCRIPT_DIR/hooks/lib/common.sh"
detect_platform

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    report PASS "$desc"
  else
    report FAIL "$desc — expected [$expected] got [$actual]"
  fi
}

# ── A transcript with one of every entry kind seen in the wild ──
TX="$TMP/mixed.jsonl"
{
  # typed by a person (interactive, current CC)
  echo '{"type":"user","origin":{"kind":"human"},"promptSource":"typed","promptId":"p1","message":{"role":"user","content":"fix the login redirect loop"}}'
  # skill body injected after a slash command
  echo '{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /x/skills/brainstorming\n# Brainstorming"}]}}'
  # tool result
  echo '{"type":"user","promptId":"p1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
  # background task notification
  echo '{"type":"user","origin":{"kind":"task-notification","producer":"session-task"},"promptSource":"system","message":{"role":"user","content":"<task-notification> <summary>Background work done</summary> </task-notification>"}}'
  # subagent hand-back
  echo '{"type":"user","isMeta":true,"origin":{"kind":"peer"},"promptSource":"system","message":{"role":"user","content":"Another Claude session sent a message: <agent-message from=\"a1\">report</agent-message>"}}'
  # /compact and its output
  echo '{"type":"user","message":{"role":"user","content":"<command-name>/compact</command-name>\n            <command-message>compact</command-message>\n            <command-args></command-args>"}}'
  echo '{"type":"user","message":{"role":"user","content":"<local-command-stdout>Compacted</local-command-stdout>"}}'
  echo '{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued from a previous conversation that ran out of context."}}'
  # caveat (meta) and interruption
  echo '{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat: ...</local-command-caveat>"}}'
  echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}'
  # slash command with args
  echo '{"type":"user","message":{"role":"user","content":"<command-name>/goal</command-name>\n<command-message>goal</command-message>\n<command-args>ship the admin dashboard</command-args>"}}'
  # older CC: no origin field, plain text, multi-line with a system reminder
  echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"now   look at\nthe logout flow <system-reminder>\nnoise\n</system-reminder>[Image #1]"}]}}'
  # sidechain entry (subagent) and an auto-continuation
  echo '{"type":"user","isSidechain":true,"message":{"role":"user","content":"subagent prompt"}}'
  echo '{"type":"user","isMeta":true,"origin":{"kind":"auto-continuation"},"message":{"role":"user","content":"continue"}}'
  # hook feedback injected by CC
  echo '{"type":"user","message":{"role":"user","content":"Stop hook feedback:\nkeep going"}}'
  # bare slash command typed without args
  echo '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"/clear"}}'
  # accepted suggestion and queued message are still the person
  echo '{"type":"user","origin":{"kind":"human"},"promptSource":"suggestion_accepted","message":{"role":"user","content":"run the tests"}}'
  echo '{"type":"user","origin":{"kind":"human"},"promptSource":"queued","promptId":"p9","message":{"role":"user","content":"then commit"}}'
  # assistant replies, last real one followed by a synthetic usage-limit message
  echo '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"Fixed the redirect loop in auth/session.ts by clearing the stale cookie."}]}}'
  echo '{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"model":"<synthetic>","content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets 3:20am"}]}}'
  echo '{"type":"custom-title","customTitle":"Fix login redirect","sessionId":"s"}'
  echo '{"type":"custom-title","customTitle":"Fix logout flow","sessionId":"s"}'
  # a user message quoting a custom-title record must not count as one
  echo '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"why is {\"type\":\"custom-title\"} in my file"}}'
} > "$TX"

echo "=== extract_human_messages ==="

H=$(extract_human_messages "$TX")
check "keeps only what a person typed, in order" \
  '["fix the login redirect loop","/goal ship the admin dashboard","now look at the logout flow","run the tests","then commit","why is {\"type\":\"custom-title\"} in my file"]' "$H"
check "missing transcript → []" "[]" "$(extract_human_messages "$TMP/nope.jsonl")"

# A half-written last line (CC mid-append) must not discard the rest.
cp "$TX" "$TMP/partial.jsonl"
printf '%s' '{"type":"user","origin":{"kind":"human"},"message":{"content":"trunc' >> "$TMP/partial.jsonl"
check "truncated last line ignored" "6" "$(extract_human_messages "$TMP/partial.jsonl" | jq length)"

echo ""
echo "=== prompt_human_text (raw UserPromptSubmit .prompt) ==="

check "plain prompt kept"             "fix it now"            "$(prompt_human_text $'fix it\n  now')"
check "task notification dropped"     ""                      "$(prompt_human_text '<task-notification><summary>x</summary></task-notification>')"
check "peer message dropped"          ""                      "$(prompt_human_text 'Another Claude session sent a message: hi')"
check "bare slash command dropped"    ""                      "$(prompt_human_text '/compact')"
check "slash command with args kept"  "/review the auth module" "$(prompt_human_text '/review the auth module')"
check "system reminder stripped"      "hello"                 "$(prompt_human_text 'hello <system-reminder>x</system-reminder>')"

echo ""
echo "=== find_prompt_entry / entry_human_text ==="

E=$(find_prompt_entry "$TX" "p1")
check "finds the prompt entry, not its tool results" "fix the login redirect loop" "$(entry_human_text "$E")"
check "unknown prompt id → nothing" "" "$(find_prompt_entry "$TX" "nope")"
check "empty prompt id → nothing" "" "$(find_prompt_entry "$TX" "")"
TN='{"type":"user","origin":{"kind":"task-notification"},"promptId":"p5","message":{"content":"looks like a real sentence"}}'
check "origin decides even when the text looks human" "" "$(entry_human_text "$TN")"

echo ""
echo "=== only_acks_since ==="

ack() { only_acks_since "$(jq -nc --arg m "$1" '["first", $m]')" 1 && echo ack || echo real; }
for m in "ok" "OK!" "继续" "好的，继续" "yes please" "ok continue" "go ahead" "嗯嗯" "lgtm" "keep going" "y" "はい"; do
  check "ack: $m" "ack" "$(ack "$m")"
done
for m in "fix it" "ok now do the signup page" "这是什么" "好的，顺便把测试也补上" "continue with the auth module" "next: onboarding" "修复"; do
  check "real: $m" "real" "$(ack "$m")"
done
only_acks_since '["a","ok","new request"]' 1 && R=ack || R=real
check "an ack followed by a request is real" "real" "$R"
only_acks_since '["a"]' 1 && R=ack || R=real
check "nothing new is not an ack" "real" "$R"

echo ""
echo "=== extract_last_ai_text ==="

check "skips synthetic usage-limit message" \
  "Fixed the redirect loop in auth/session.ts by clearing the stale cookie." "$(extract_last_ai_text "$TX")"
AI="$TMP/ai.jsonl"
{
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"second"},{"type":"tool_use","name":"X","id":"a","input":{}}]}}'
  echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Y","id":"b","input":{}}]}}'
  echo '{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"subagent"}]}}'
} > "$AI"
check "last text block wins, tool-only and sidechain skipped" "second" "$(extract_last_ai_text "$AI")"
echo '{"type":"user","message":{"content":"hi"}}' > "$TMP/u.jsonl"
check "no assistant → empty" "" "$(extract_last_ai_text "$TMP/u.jsonl")"

echo ""
echo "=== custom titles ==="

check "list in order, quoted record ignored" $'Fix login redirect\nFix logout flow' "$(list_custom_titles "$TX")"
check "last_custom_title" "Fix logout flow" "$(last_custom_title "$TX")"
check "no titles → empty" "" "$(last_custom_title "$TMP/u.jsonl")"

echo ""
echo "=== build_dialog ==="

HEAD_MESSAGES=1
TAIL_MESSAGES=5
check "single message → LATEST only" "LATEST: only one" "$(build_dialog "" '["only one"]' "")"
check "no messages → empty, even with title and Claude text" "" "$(build_dialog "T" '[]' "some reply")"
check "full shape" $'CURRENT_TITLE: Fix login\nFIRST: a\nEARLIER: b\nLATEST: c\nCLAUDE: did it' \
  "$(build_dialog "Fix login" '["a","b","c"]' $'did\n  it')"

# Head + tail window: first 1 and last 5 of 10 → indices 0,5..9
D=$(build_dialog "" '["m0","m1","m2","m3","m4","m5","m6","m7","m8","m9"]' "")
check "window keeps first + last 5" $'FIRST: m0\nEARLIER: m5\nEARLIER: m6\nEARLIER: m7\nEARLIER: m8\nLATEST: m9' "$D"
TAIL_MESSAGES=0
check "tail 0 still keeps LATEST" $'FIRST: m0\nLATEST: m3' "$(build_dialog "" '["m0","m1","m2","m3"]' "")"
TAIL_MESSAGES=5
HEAD_MESSAGES=0
check "head 0 drops FIRST" $'EARLIER: m1\nLATEST: m2' "$(build_dialog "" '["m1","m2"]' "")"
HEAD_MESSAGES=1

# Each message is capped on its own; a long paste keeps head and tail.
LONG=$(printf 'x%.0s' $(seq 1 1000))
D=$(build_dialog "" "$(jq -nc --arg l "start ${LONG} question?" '[$l, "short"]')" "")
FIRST_LINE=$(printf '%s\n' "$D" | head -1)
check "long FIRST capped to 500 chars" "500" "$(printf '%s' "${FIRST_LINE#FIRST: }" | jq -Rs length)"
AGAIN=$(build_dialog "" "$(jq -nc --arg l "${FIRST_LINE#FIRST: }" '[$l, "short"]')" "" | head -1)
check "capping a capped message changes nothing" "$FIRST_LINE" "$AGAIN"
[[ "$FIRST_LINE" == "FIRST: start"* && "$FIRST_LINE" == *"question?" && "$FIRST_LINE" == *" … "* ]] \
  && report PASS "long message keeps head and tail" || report FAIL "head/tail not kept: ${FIRST_LINE:0:80}…"
check "short LATEST untouched" "LATEST: short" "$(printf '%s\n' "$D" | tail -1)"
CJK=$(printf '中%.0s' $(seq 1 700))
D=$(build_dialog "" "$(jq -nc --arg l "$CJK" '[$l]')" "")
check "CJK cap counts characters, not bytes" "1" "$(( $(printf '%s' "${D#LATEST: }" | jq -Rs length) <= 605 ))"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && echo "All tests passed!" || exit 1
