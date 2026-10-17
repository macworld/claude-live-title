#!/usr/bin/env bash
# test-entry.sh — End-to-end tests for live-title.sh, stop-title.sh and
# apply-title.sh with a stubbed `claude` and fixture transcripts. Runs
# against a throwaway CLAUDE_PLUGIN_DATA and HOME.
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
check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    report PASS "$desc"
  else
    report FAIL "$desc — expected [$expected] got [$actual]"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
export HOME="$FIX/home" CLAUDE_PLUGIN_DATA="$FIX/data"
mkdir -p "$HOME" "$CLAUDE_PLUGIN_DATA" "$FIX/bin"
STUB_LOG="$FIX/stub.log"
export STUB_LOG

# Stub `claude`: records each call (args + stdin) and answers like
# `claude -p --output-format json` would, per $STUB_MODE:
#   ok (default)  success with $STUB_TITLE
#   quota         is_error with the usage-limit text
#   unflagged     usage-limit text but is_error=false (defensive path)
#   error         is_error with a generic API error
#   no-lean       rejects --safe-mode like an older CLI (exit 5)
# A shorten request (prompt holds <title>) is answered with $STUB_SHORT.
cat > "$FIX/bin/claude" <<'STUB'
#!/usr/bin/env bash
input=$(cat)
[[ "$input" == *"<title>"* && -n "${STUB_SHORT-}" ]] && STUB_TITLE="$STUB_SHORT"
{ printf 'CALL'; printf ' [%s]' "$@"; printf '\n'; printf '%s\n' "$input"; echo "END"; } >> "$STUB_LOG"
mode="${STUB_MODE:-ok}"
if [[ "$mode" == "no-lean" ]]; then
  for a in "$@"; do
    [[ "$a" == "--safe-mode" ]] && { echo "error: unknown option '--safe-mode'" >&2; exit 5; }
  done
  mode=ok
fi
case "$mode" in
  ok)        jq -nc --arg t "${STUB_TITLE:-stub-title}" '{type:"result",subtype:"success",is_error:false,result:$t}' ;;
  quota)     jq -nc '{type:"result",subtype:"success",is_error:true,result:"You'"'"'ve hit your session limit · resets 3:20am (Asia/Singapore)"}' ;;
  unflagged) jq -nc '{type:"result",subtype:"success",is_error:false,result:"You'"'"'ve hit your session limit · resets 3:20am (Asia/Singapore)"}' ;;
  error)     jq -nc '{type:"result",subtype:"success",is_error:true,result:"API Error: 500 Internal server error"}' ;;
esac
STUB
chmod +x "$FIX/bin/claude"
export PATH="$FIX/bin:$PATH"

STATE_DIR="$CLAUDE_PLUGIN_DATA/sessions"
sid_hash() { bash -c 'source "$1/hooks/lib/common.sh"; sanitize_session_id "$2"' _ "$SCRIPT_DIR" "$1"; }
# Portable helpers (BSD date/touch on macOS lack %N and -d).
now_ms() { python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || echo $(( $(date +%s) * 1000 )); }
backdate() { local ts; ts=$(date -r "$2" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$2" +%Y%m%d%H%M.%S); touch -t "$ts" "$1"; }

# new_session <name>: sets SID, TX, H, ST (state file), PIN
new_session() {
  SID="entry-$1-$$"
  H=$(sid_hash "$SID")
  TX="$FIX/$1.jsonl"
  ST="$STATE_DIR/$H.json"
  PIN="$STATE_DIR/$H.pinned"
  : > "$TX"
  rm -f "$ST" "$PIN" "$CLAUDE_PLUGIN_DATA/cooldown-until" "$CLAUDE_PLUGIN_DATA/lean-flags-unsupported"
  rm -rf "$STATE_DIR/$H.lock"
  : > "$STUB_LOG"
  unset STUB_MODE STUB_TITLE STUB_SHORT
}

human()   { jq -nc --arg c "$1" --arg p "${2-}" '{type:"user", origin:{kind:"human"}, promptId:$p, message:{role:"user", content:$c}}' >> "$TX"; }
system_msg() { jq -nc --arg c "$1" --arg p "${2-}" '{type:"user", origin:{kind:"task-notification"}, promptId:$p, message:{role:"user", content:$c}}' >> "$TX"; }
reply()   { jq -nc --arg t "$1" '{type:"assistant", message:{model:"claude-opus-5-5", content:[{type:"text", text:$t}]}}' >> "$TX"; }
cc_title() { jq -nc --arg t "$1" --arg s "$SID" '{type:"custom-title", customTitle:$t, sessionId:$s}' >> "$TX"; }

# run_live <prompt> [prompt_id] [session_title]
run_live() {
  jq -nc --arg sid "$SID" --arg tx "$TX" --arg p "$1" --arg pid "${2-}" --arg st "${3-}" \
    '{session_id:$sid, transcript_path:$tx, prompt:$p}
     + (if $pid != "" then {prompt_id:$pid} else {} end)
     + (if $st != "" then {session_title:$st} else {} end)' \
    | bash "$SCRIPT_DIR/hooks/live-title.sh" || true
}
run_stop() {
  jq -nc --arg sid "$SID" --arg tx "$TX" '{session_id:$sid, transcript_path:$tx}' \
    | bash "$SCRIPT_DIR/hooks/stop-title.sh" || true
}
# run_apply <session_title> → prints the hook's stdout
run_apply() {
  jq -nc --arg sid "$SID" --arg tx "$TX" --arg st "${1-}" \
    '{session_id:$sid, transcript_path:$tx, prompt:"x"} + (if $st != "" then {session_title:$st} else {} end)' \
    | bash "$SCRIPT_DIR/hooks/apply-title.sh"
}

last_title()  { jq -r 'select(.type=="custom-title") | .customTitle' "$TX" | tail -1; }
title_count() { jq -c 'select(.type=="custom-title")' "$TX" | wc -l | tr -d ' '; }
calls()       { grep -c '^CALL' "$STUB_LOG" 2>/dev/null || true; }
state_get()   { jq -r "$1" "$ST" 2>/dev/null; }
age_state()   { local t; t=$(mktemp); jq --argjson g "$1" '.lastGen = $g' "$ST" > "$t" && mv "$t" "$ST"; }

echo "=== live-title.sh ==="

new_session fresh
human "fix the logout redirect" p1
STUB_TITLE="Fix logout redirect" run_live "fix the logout redirect" p1
check "fresh session: title written" "Fix logout redirect" "$(last_title)"
check "fresh session: state records latest" "Fix logout redirect" "$(state_get .latest)"
check "fresh session: state records human count" "1" "$(state_get .lastHumanCount)"
check "debug-free run leaves no log" "no" "$([[ -f "$CLAUDE_PLUGIN_DATA/debug.log" ]] && echo yes || echo no)"
grep -q '\[--safe-mode\]' "$STUB_LOG" && grep -q '\[--tools\] \[\]' "$STUB_LOG" && grep -q '\[--output-format\] \[json\]' "$STUB_LOG" \
  && report PASS "lean flags used (--tools \"\", --safe-mode, json output)" || report FAIL "lean flags missing: $(head -1 "$STUB_LOG")"
grep -q '^LATEST: fix the logout redirect$' "$STUB_LOG" \
  && report PASS "dialog sent to model contains LATEST" || report FAIL "dialog: $(cat "$STUB_LOG")"

new_session turn1
# Turn 1 of a new session: transcript empty, no prompt_id (older CC) → PROMPT used.
STUB_TITLE="Plan the migration" run_live "plan the db migration"
check "prompt not yet in transcript: PROMPT used" "Plan the migration" "$(last_title)"

new_session system
human "build the export feature" p1
STUB_TITLE="Build export" run_live "build the export feature" p1
system_msg "<task-notification><summary>done</summary></task-notification>" p2
STUB_TITLE="should-not-write" run_live "<task-notification><summary>done</summary></task-notification>" p2
check "task notification prompt: no new generation" "1" "$(calls)"
check "task notification prompt: title kept" "Build export" "$(last_title)"
system_msg "looks like a normal sentence" p3
STUB_TITLE="should-not-write" run_live "looks like a normal sentence" p3
check "origin beats text heuristics" "1" "$(calls)"

new_session throttle
human "first task" p1
STUB_TITLE="First task" run_live "first task" p1
human "second task" p2
STUB_TITLE="Second task" run_live "second task" p2
check "second prompt within throttleInterval: skipped" "1" "$(calls)"
check "throttled: title unchanged" "First task" "$(last_title)"
reply "working on the second task now"
STUB_TITLE="Second task" run_stop
check "Stop catches up on the skipped prompt" "Second task" "$(last_title)"
check "catch-up: one more call" "2" "$(calls)"
run_stop
check "Stop with nothing new: no call" "2" "$(calls)"

new_session same
human "refactor auth" p1
STUB_TITLE="Refactor auth" run_live "refactor auth" p1
age_state 0
human "also handle the token refresh path" p2
STUB_TITLE="Refactor auth" run_live "also handle the token refresh path" p2
check "unchanged title: no duplicate record" "1" "$(title_count)"
grep -q '^CURRENT_TITLE: Refactor auth$' "$STUB_LOG" \
  && report PASS "current title sent to model" || report FAIL "CURRENT_TITLE missing"
check "unchanged title: generation still recorded" "2" "$(state_get .lastHumanCount)"

new_session acks
human "fix the flaky checkout test" p1
STUB_TITLE="Fix flaky checkout test" run_live "fix the flaky checkout test" p1
human "ok continue" p2
STUB_TITLE="Reworded" run_live "ok continue" p2
check "bare acknowledgement: no model call" "1" "$(calls)"
check "bare acknowledgement: counted as seen" "2" "$(state_get .lastHumanCount)"
human "好的，继续" p3
reply "still on the checkout test"
STUB_TITLE="Reworded" run_stop
check "acknowledgements don't trigger a Stop catch-up" "1" "$(calls)"
check "title kept through acknowledgements" "Fix flaky checkout test" "$(last_title)"
age_state 0
human "好的，顺便把 cart 页面的样式也改一下" p4
STUB_TITLE="Checkout test and cart styles" run_live "好的，顺便把 cart 页面的样式也改一下" p4
check "ack-prefixed real request still generates" "2" "$(calls)"

new_session acks-mixed
human "task one" p1
STUB_TITLE="Task one" run_live "task one" p1
human "now task two" p2
STUB_TITLE="Task two" run_live "now task two" p2
human "ok" p3
STUB_TITLE="Task two" run_live "ok" p3
check "throttled request then ack: live hook still waits" "1" "$(calls)"
reply "done with task two"
STUB_TITLE="Task two" run_stop
check "throttled request then ack: Stop catches up" "Task two" "$(last_title)"

new_session toolong
human "add csv export with the date range in the file name" p1
STUB_TITLE="CSV export with date range in filename" STUB_SHORT="CSV export file naming" run_live "x" p1
check "over maxLength: shortened by a second call" "CSV export file naming" "$(last_title)"
check "over maxLength: exactly two calls" "2" "$(calls)"
grep -q '<title>CSV export with date range in filename</title>' "$STUB_LOG" \
  && report PASS "shorten request carries the long title" || report FAIL "shorten request malformed"

new_session stilllong
human "add csv export with the date range in the file name" p1
STUB_TITLE="CSV export with date range in filename" STUB_SHORT="CSV export with the date range in the file name" run_live "x" p1
check "shortening that doesn't shrink: long title kept" "CSV export with date range in filename" "$(last_title)"

new_session cjklong
human "把后台总览页的统计卡片和图表区域布局都重新优化一下" p1
STUB_TITLE="后台总览页统计卡片与图表区域布局优化" STUB_SHORT="后台总览页布局优化" run_live "x" p1
check "CJK counts double: 36 columns shortened" "后台总览页布局优化" "$(last_title)"

new_session quota
human "fix the parser" p1
STUB_MODE=quota run_live "fix the parser" p1
check "usage-limit error: nothing written" "0" "$(title_count)"
[[ -f "$CLAUDE_PLUGIN_DATA/cooldown-until" ]] && report PASS "usage-limit error: cooldown set" || report FAIL "no cooldown file"
check "usage-limit error: no retry with basic flags" "1" "$(calls)"
STUB_TITLE="Fix parser" run_live "fix the parser" p1
check "during cooldown: no call" "1" "$(calls)"
STUB_TITLE="Fix parser" run_stop
check "during cooldown: Stop doesn't call either" "1" "$(calls)"
echo 0 > "$CLAUDE_PLUGIN_DATA/cooldown-until"
STUB_TITLE="Fix parser" run_stop
check "after cooldown: title written" "Fix parser" "$(last_title)"

new_session unflagged
human "fix the parser" p1
STUB_MODE=unflagged run_live "fix the parser" p1
check "limit text without is_error: still rejected" "0" "$(title_count)"
[[ -f "$CLAUDE_PLUGIN_DATA/cooldown-until" ]] && report PASS "limit text without is_error: cooldown set" || report FAIL "no cooldown"

new_session apierror
human "fix the parser" p1
STUB_MODE=error run_live "fix the parser" p1
check "API error: nothing written" "0" "$(title_count)"
check "API error: lean then basic tried" "2" "$(calls)"
[[ ! -f "$CLAUDE_PLUGIN_DATA/lean-flags-unsupported" ]] && report PASS "API error doesn't blame lean flags" || report FAIL "lean wrongly marked"

new_session nolean
human "write docs" p1
STUB_MODE=no-lean STUB_TITLE="Write docs" run_live "write docs" p1
check "older CLI rejects lean flags: basic fallback writes title" "Write docs" "$(last_title)"
[[ -f "$CLAUDE_PLUGIN_DATA/lean-flags-unsupported" ]] && report PASS "lean flags remembered as unsupported" || report FAIL "marker missing"
: > "$STUB_LOG"
age_state 0
human "write more docs" p2
STUB_MODE=no-lean STUB_TITLE="Write more docs" run_live "write more docs" p2
check "next call goes straight to basic" "1" "$(calls)"

new_session pinned
human "fix login" p1
STUB_TITLE="Fix login" run_live "fix login" p1
age_state 0
human "now the signup page" p2
STUB_TITLE="Signup page" run_live "now the signup page" p2 "My own name"
check "foreign session_title: no write" "Fix login" "$(last_title)"
[[ -f "$PIN" ]] && report PASS "foreign session_title pins the session" || report FAIL "not pinned"
STUB_TITLE="x" run_stop
check "pinned: Stop leaves it alone" "1" "$(calls)"

new_session busy
human "long job" p1
mkdir -p "$STATE_DIR/$H.lock"
( sleep 1; rm -rf "$STATE_DIR/$H.lock" ) &
STUB_TITLE="Long job" run_live "long job" p1
wait
check "busy lock: waits for it, then writes" "Long job" "$(last_title)"

new_session stale
human "stale lock" p1
mkdir -p "$STATE_DIR/$H.lock"
backdate "$STATE_DIR/$H.lock" $(( $(date +%s) - 600 ))
STUB_TITLE="Stale lock" run_live "stale lock" p1
check "stale lock: recovered" "Stale lock" "$(last_title)"

new_session disabled
echo '{"liveUpdate":false}' > "$CLAUDE_PLUGIN_DATA/config.json"
human "only once" p1
STUB_TITLE="x" run_live "only once" p1
check "liveUpdate=false: live hook does nothing" "0" "$(calls)"
reply "done"
STUB_TITLE="Only once" run_stop
check "liveUpdate=false: Stop writes the first title" "Only once" "$(last_title)"
human "something else" p2
reply "done too"
STUB_TITLE="Changed" run_stop
check "liveUpdate=false: never updated afterwards" "Only once" "$(last_title)"
rm -f "$CLAUDE_PLUGIN_DATA/config.json"

echo ""
echo "=== stop-title.sh ==="

new_session stopfirst
human "refactor utils module"
reply "extracted format_date to date_utils.py"
STUB_TITLE="Refactor utils" run_stop
check "no title yet: Stop writes one" "Refactor utils" "$(last_title)"

new_session revert
human "task a" p1
STUB_TITLE="Task A" run_live "task a" p1
age_state 0
human "task b" p2
STUB_TITLE="Task B" run_live "task b" p2
cc_title "Task A"   # Claude Code re-appends its stale in-memory title
STUB_TITLE="unused" run_stop
check "Stop restores latest after Claude Code reverted it" "Task B" "$(last_title)"
check "repair needs no model call" "2" "$(calls)"

new_session foreign
human "task a" p1
STUB_TITLE="Task A" run_live "task a" p1
cc_title "Renamed by user"
reply "ok"
STUB_TITLE="x" run_stop
check "foreign last title: left alone" "Renamed by user" "$(last_title)"
[[ -f "$PIN" ]] && report PASS "foreign last title pins the session" || report FAIL "not pinned"

new_session refresh
human "long autonomous run" p1
STUB_TITLE="Research phase" run_live "long autonomous run" p1
reply "research done, implementing now"
STUB_TITLE="Implementation phase" run_stop
check "recent generation: no refresh" "Research phase" "$(last_title)"
age_state $(( $(date +%s) - 1000 ))
STUB_TITLE="Implementation phase" run_stop
check "after REFRESH_INTERVAL: Stop refreshes" "Implementation phase" "$(last_title)"

new_session nohuman
system_msg "<task-notification>x</task-notification>"
reply "background done"
STUB_TITLE="x" run_stop
check "no human messages: nothing to title" "0" "$(calls)"

echo ""
echo "=== bootstrap of sessions this version hasn't seen ==="

new_session named
cc_title "Name from --name"
human "do things" p1
STUB_TITLE="x" run_live "do things" p1 "Name from --name"
check "pre-existing unknown title: not overwritten" "Name from --name" "$(last_title)"
[[ -f "$PIN" ]] && report PASS "pre-existing unknown title: pinned" || report FAIL "not pinned"

new_session legacy
cc_title "Old plugin title"
echo "$(( $(date +%s) - 500 )) 3" > "/tmp/claude-live-title-state-$H"
human "keep going on the parser" p1
STUB_TITLE="Parser work" run_live "keep going on the parser" p1
check "legacy (≤1.3) session: titles adopted and updated" "Parser work" "$(last_title)"
check "legacy history kept" '["Old plugin title","Parser work"]' "$(state_get '.history|tojson')"
[[ ! -f "/tmp/claude-live-title-state-$H" ]] && report PASS "legacy /tmp state removed" || { report FAIL "legacy state left"; rm -f "/tmp/claude-live-title-state-$H"; }

new_session fork-parent
human "parent work" p1
STUB_TITLE="Parent work" run_live "parent work" p1
PARENT_TX="$TX"
new_session fork-child
cp "$PARENT_TX" "$TX"
human "child work" p2
STUB_TITLE="Child work" run_live "child work" p2
check "fork: inherited title recognized as ours, updated" "Child work" "$(last_title)"

echo ""
echo "=== apply-title.sh ==="

new_session apply
human "task a" p1
STUB_TITLE="Task A" run_live "task a" p1
age_state 0
human "task b" p2
STUB_TITLE="Task B" run_live "task b" p2
check "no session_title: no output" "" "$(run_apply "")"
check "session_title is latest: no output" "" "$(run_apply "Task B")"
OUT=$(run_apply "Task A")
check "stale title of ours: sets sessionTitle to latest" \
  '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"Task B"}}' "$OUT"
check "unknown session: no output" "" "$(SID=unknown-$$ run_apply "Whatever")"
check "foreign title: no output" "" "$(run_apply "User picked this")"
[[ -f "$PIN" ]] && report PASS "foreign title: pinned" || report FAIL "not pinned"
check "pinned: no output even for a stale title" "" "$(run_apply "Task A")"
check "internal subsession: no output" "" "$(CLAUDE_LIVE_TITLE_INTERNAL=1 run_apply "Task A")"
OUT=$(printf 'not json' | bash "$SCRIPT_DIR/hooks/apply-title.sh"; echo "rc=$?")
check "malformed input: silent, exit 0" "rc=0" "$OUT"

# Timing: the hook runs before every prompt, so it must stay fast.
new_session applyfast
human "a" p1
STUB_TITLE="A" run_live "a" p1
START=$(now_ms)
for i in 1 2 3 4 5; do run_apply "A" >/dev/null; done
MS=$(( ($(now_ms) - START) / 5 ))
(( MS < 150 )) && report PASS "apply-title.sh averages ${MS}ms" || report FAIL "apply-title.sh too slow: ${MS}ms"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && echo "All tests passed!" || exit 1
