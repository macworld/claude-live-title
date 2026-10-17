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
# Run inside a Claude Code session, the hooks' project dir would leak in.
unset CLAUDE_PROJECT_DIR
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
#   no-tools      rejects --tools as well, like a much older CLI (exit 5)
#   hang          never answers; the plugin's watchdog has to kill it
# A shorten request (prompt holds <title>) is answered with $STUB_SHORT, or
# with $STUB_SHORT2 when it is the second shorten request in a row.
# $STUB_LS_DIRS: directories whose contents are listed into the log at call
# time, to see which files exist while the model runs.
cat > "$FIX/bin/claude" <<'STUB'
#!/usr/bin/env bash
input=$(cat)
if [[ "$input" == *"<title>"* && -n "${STUB_SHORT-}" ]]; then
  STUB_TITLE="$STUB_SHORT"
  [[ "$input" == *"<title>${STUB_SHORT}</title>"* && -n "${STUB_SHORT2-}" ]] && STUB_TITLE="$STUB_SHORT2"
fi
{ printf 'CALL'; printf ' [%s]' "$@"; printf '\n'; printf '%s\n' "$input"; echo "END"; } >> "$STUB_LOG"
for d in ${STUB_LS_DIRS-}; do printf 'LS %s: %s\n' "$d" "$(ls -A "$d" 2>/dev/null | tr '\n' ' ')" >> "$STUB_LOG"; done
mode="${STUB_MODE:-ok}"
if [[ "$mode" == "no-lean" || "$mode" == "no-tools" ]]; then
  for a in "$@"; do
    [[ "$a" == "--safe-mode" ]] && { echo "error: unknown option '--safe-mode'" >&2; exit 5; }
    [[ "$a" == "--tools" && "$mode" == "no-tools" ]] && { echo "error: unknown option '--tools'" >&2; exit 5; }
  done
  mode=ok
fi
case "$mode" in
  ok)        jq -nc --arg t "${STUB_TITLE:-stub-title}" '{type:"result",subtype:"success",is_error:false,result:$t}' ;;
  quota)     jq -nc '{type:"result",subtype:"success",is_error:true,result:"You'"'"'ve hit your session limit · resets 3:20am (Asia/Singapore)"}' ;;
  unflagged) jq -nc '{type:"result",subtype:"success",is_error:false,result:"You'"'"'ve hit your session limit · resets 3:20am (Asia/Singapore)"}' ;;
  error)     jq -nc '{type:"result",subtype:"success",is_error:true,result:"API Error: 500 Internal server error"}' ;;
  hang)      exec sleep 30 ;;
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
  unset STUB_MODE STUB_TITLE STUB_SHORT STUB_SHORT2
}

human()   { jq -nc --arg c "$1" --arg p "${2-}" '{type:"user", origin:{kind:"human"}, promptId:$p, message:{role:"user", content:$c}}' >> "$TX"; }
system_msg() { jq -nc --arg c "$1" --arg p "${2-}" '{type:"user", origin:{kind:"task-notification"}, promptId:$p, message:{role:"user", content:$c}}' >> "$TX"; }
reply()   { jq -nc --arg t "$1" '{type:"assistant", message:{model:"claude-opus-5-5", content:[{type:"text", text:$t}]}}' >> "$TX"; }
cc_title() { jq -nc --arg t "$1" --arg s "$SID" '{type:"custom-title", customTitle:$t, sessionId:$s}' >> "$TX"; }

# run_live <prompt> [prompt_id] [session_title]; $HOOK_CWD becomes the input's cwd
run_live() {
  jq -nc --arg sid "$SID" --arg tx "$TX" --arg p "$1" --arg pid "${2-}" --arg st "${3-}" --arg cwd "${HOOK_CWD-}" \
    '{session_id:$sid, transcript_path:$tx, prompt:$p}
     + (if $pid != "" then {prompt_id:$pid} else {} end)
     + (if $st != "" then {session_title:$st} else {} end)
     + (if $cwd != "" then {cwd:$cwd} else {} end)' \
    | bash "$SCRIPT_DIR/hooks/live-title.sh" || true
}
# run_stop [last_assistant_message]; $HOOK_CWD becomes the input's cwd
run_stop() {
  jq -nc --arg sid "$SID" --arg tx "$TX" --arg cwd "${HOOK_CWD-}" --arg last "${1-}" \
    '{session_id:$sid, transcript_path:$tx} + (if $cwd != "" then {cwd:$cwd} else {} end)
     + (if $last != "" then {last_assistant_message:$last} else {} end)' \
    | bash "$SCRIPT_DIR/hooks/stop-title.sh" || true
}
# run_apply <session_title> [prompt] → prints the hook's stdout
run_apply() {
  jq -nc --arg sid "$SID" --arg tx "$TX" --arg st "${1-}" --arg p "${2-x}" \
    '{session_id:$sid, transcript_path:$tx, prompt:$p} + (if $st != "" then {session_title:$st} else {} end)' \
    | bash "$SCRIPT_DIR/hooks/apply-title.sh"
}
# Transcript head Claude Code writes on /clear: the previous session's
# title carried over, then the command itself.
clear_head() {
  cc_title "$1"
  jq -nc '{type:"user", isMeta:true, message:{role:"user", content:"<local-command-caveat>Caveat</local-command-caveat>"}}' >> "$TX"
  jq -nc '{type:"user", message:{role:"user", content:"<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"}}' >> "$TX"
}
sets_title() { jq -nc --arg t "$1" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", sessionTitle:$t}}'; }

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

new_session unterminated
human "fix the logout redirect" p1
# A write that was cut short leaves the last line without its newline.
printf '%s' '{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"on it"}]}}' >> "$TX"
STUB_TITLE="Fix logout redirect" run_live "fix the logout redirect" p1
check "unterminated last line: title on its own line" "Fix logout redirect" "$(last_title)"
# Line by line, like Claude Code reads it (jq alone accepts two objects on one line).
check "unterminated last line: every line parses on its own" "ok ok ok" \
  "$(jq -R -r 'fromjson? | "ok"' "$TX" | tr '\n' ' ' | sed 's/ $//')"

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

new_session notask
human "hi" p1
STUB_TITLE="SKIP" run_live "hi" p1
check "no task yet (SKIP): nothing written" "0" "$(title_count)"
check "no task yet: message counted as seen" "1" "$(state_get .lastHumanCount)"
check "no task yet: no title recorded" "" "$(state_get .latest)"
reply "Hi! What would you like to work on?"
STUB_TITLE="should-not-write" run_stop
check "no task yet: Stop doesn't retry the same message" "1" "$(calls)"
check "no task yet: apply-title hands Claude Code nothing" "" "$(run_apply "")"
human "fix the logout redirect" p2
STUB_TITLE="Fix logout redirect" run_live "fix the logout redirect" p2
check "first real task after SKIP: named right away" "Fix logout redirect" "$(last_title)"

new_session skipvariants
human "test" p1
STUB_TITLE='`skip`.' run_live "test" p1
check "SKIP in any case or wrapping: nothing written" "0" "$(title_count)"
human "hello?" p2
STUB_TITLE='"SKIP"' run_live "hello?" p2
check "quoted SKIP: nothing written" "0" "$(title_count)"
check "title merely starting with Skip is a title" "Skip onboarding step" \
  "$(human "make the onboarding skippable" p3; STUB_TITLE="Skip onboarding step" run_live "make the onboarding skippable" p3; last_title)"

new_session skipkept
human "refactor auth" p1
STUB_TITLE="Refactor auth" run_live "refactor auth" p1
age_state 0
human "thanks, that's all for now" p2
STUB_TITLE="SKIP" run_live "thanks, that's all for now" p2
check "SKIP with a current title: title kept" "Refactor auth" "$(last_title)"
check "SKIP with a current title: no duplicate record" "1" "$(title_count)"
check "SKIP with a current title: message counted" "2" "$(state_get .lastHumanCount)"

new_session skipstop
echo '{"liveUpdate":false}' > "$CLAUDE_PLUGIN_DATA/config.json"
human "hey"
reply "Hey! What are we working on?"
STUB_TITLE="SKIP" run_stop
check "Stop-only, no task yet: nothing written" "0" "$(title_count)"
human "write the release notes for 2.1"
reply "Drafting them now."
STUB_TITLE="Write 2.1 release notes" run_stop
check "Stop-only: named once a task arrives" "Write 2.1 release notes" "$(last_title)"
rm -f "$CLAUDE_PLUGIN_DATA/config.json"

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
check "shortening that doesn't shrink: asked twice, then gave up" "3" "$(calls)"

new_session twoshorten
human "add csv export with the date range in the file name" p1
STUB_TITLE="CSV export with date range in filename" STUB_SHORT="CSV export with date range in name" STUB_SHORT2="CSV export naming" run_live "x" p1
check "first shortening still too wide: asked once more" "CSV export naming" "$(last_title)"
check "first shortening still too wide: three calls in all" "3" "$(calls)"
grep -q '<title>CSV export with date range in name</title>' "$STUB_LOG" \
  && report PASS "second shorten request starts from the first result" || report FAIL "second shorten request malformed"
shorten_requests() { awk '/^CALL/ { b = "" } { b = b $0 "\n" } /^END$/ && b ~ /<title>/ { printf "%s", b }' "$STUB_LOG"; }
shorten_requests | grep -q 'is 38 columns, 8 more than the 30 the status bar fits. Shorten it to at most 30 columns: drop at least one word' \
  && report PASS "shorten request says how far over it is and asks to drop a word" || report FAIL "shorten request wording"

new_session narrowest
human "add csv export with the date range in the file name" p1
STUB_TITLE="CSV export with date range in filename" STUB_SHORT="CSV export with date range in name" STUB_SHORT2="CSV export with the date range in the file name" run_live "x" p1
check "second shortening wider than the first: narrowest kept" "CSV export with date range in name" "$(last_title)"

new_session shortskip
human "add csv export with the date range in the file name" p1
STUB_TITLE="CSV export with date range in filename" STUB_SHORT="SKIP" run_live "x" p1
check "SKIP as a shortened title: ignored" "CSV export with date range in filename" "$(last_title)"

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
# The prompt carries text from the transcript and the project's
# .claude/live-title.md, so no fallback may hand the model its tools.
grep '^CALL' "$STUB_LOG" | grep -qv '\[--tools\] \[\]' \
  && report FAIL "basic fallback ran with tools: $(grep '^CALL' "$STUB_LOG" | head -1)" \
  || report PASS "basic fallback still runs with --tools \"\""

new_session notools
human "write docs" p1
STUB_MODE=no-tools STUB_TITLE="Write docs" run_live "write docs" p1
check "CLI without --tools: nothing written" "0" "$(title_count)"
grep '^CALL' "$STUB_LOG" | grep -qv '\[--tools\] \[\]' \
  && report FAIL "model called without --tools \"\"" \
  || report PASS "CLI without --tools: never called with tools enabled"

new_session promptfile
human "fix the parser" p1
mkdir -p "$FIX/tmp"
# The prompt holds conversation text, so it belongs in the plugin's private
# data directory, not wherever TMPDIR points.
STUB_LS_DIRS="$FIX/tmp $CLAUDE_PLUGIN_DATA" TMPDIR="$FIX/tmp" STUB_TITLE="Fix parser" run_live "fix the parser" p1
grep -q "^LS $CLAUDE_PLUGIN_DATA:.*prompt" "$STUB_LOG" && ! grep -q "^LS $FIX/tmp:.*prompt" "$STUB_LOG" \
  && report PASS "prompt file is created in the data dir, not in TMPDIR" || report FAIL "prompt file location: $(grep '^LS' "$STUB_LOG" | tr '\n' ' ')"
[[ -z "$(ls -A "$CLAUDE_PLUGIN_DATA" | grep prompt)" ]] && report PASS "prompt file removed after the call" || report FAIL "prompt file left behind"

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
new_session disabledclear
clear_head "Previous task"
human "start on the export feature" p1
reply "done"
STUB_TITLE="Export feature" run_stop
check "liveUpdate=false after /clear: the session gets its own first title" "Export feature" "$(last_title)"
rm -f "$CLAUDE_PLUGIN_DATA/config.json"

new_session style
human "PROJ-88 the login times out" p1
STUB_TITLE="Fix login timeout" run_live "PROJ-88 the login times out" p1
grep -q '<rules>' "$STUB_LOG" && report FAIL "no style: rules sent anyway" || report PASS "no style: no rules in the request"
echo '{"style":"Start with the ticket ID."}' > "$CLAUDE_PLUGIN_DATA/config.json"
new_session style-config
human "PROJ-88 the login times out" p1
STUB_TITLE="PROJ-88 Fix login timeout" run_live "PROJ-88 the login times out" p1
grep -q '^Start with the ticket ID\.$' "$STUB_LOG" && grep -q '^<rules>$' "$STUB_LOG" \
  && report PASS "configured style reaches the model" || report FAIL "configured style missing from the request"
PROJ="$FIX/project"
mkdir -p "$PROJ/.claude/sub" "$PROJ/src"
printf 'Team rule: use the Jira key as a prefix.\n' > "$PROJ/.claude/live-title.md"
new_session style-project
human "PROJ-88 the login times out" p1
HOOK_CWD="$PROJ" STUB_TITLE="PROJ-88 Fix login timeout" run_live "PROJ-88 the login times out" p1
grep -q '^Team rule: use the Jira key as a prefix\.$' "$STUB_LOG" && ! grep -q 'Start with the ticket ID' "$STUB_LOG" \
  && report PASS "project .claude/live-title.md replaces the configured style" || report FAIL "project style not used"
new_session style-stop
human "PROJ-88 the login times out"
reply "Looking at the session timeout."
HOOK_CWD="$PROJ" STUB_TITLE="PROJ-88 Fix login timeout" run_stop
grep -q '^Team rule: use the Jira key as a prefix\.$' "$STUB_LOG" \
  && report PASS "Stop hook uses the project style too" || report FAIL "Stop hook ignored the project style"
new_session style-subdir
human "PROJ-88 the login times out" p1
CLAUDE_PROJECT_DIR="$PROJ" HOOK_CWD="$PROJ/src" STUB_TITLE="PROJ-88 Fix login timeout" run_live "PROJ-88 the login times out" p1
grep -q '^Team rule: use the Jira key as a prefix\.$' "$STUB_LOG" \
  && report PASS "cwd in a subdirectory: project root found via CLAUDE_PROJECT_DIR" || report FAIL "project style lost in a subdirectory"
rm -rf "$PROJ" "$CLAUDE_PLUGIN_DATA/config.json"

new_session replaylog
printf '%s' '{"debug":true,"style":"Start with the ticket ID.\nKeep it short."}' > "$CLAUDE_PLUGIN_DATA/config.json"
human "hi" p1
STUB_TITLE="SKIP" run_live "hi" p1
human "PROJ-88 the login times out" p2
STUB_TITLE="PROJ-88 login timeout" run_live "PROJ-88 the login times out" p2
EVENTS=$(grep -F '"event":"title-generated"' "$CLAUDE_PLUGIN_DATA/debug.log" | grep -F "\"session_id\":\"$SID\"")
check "debug: a SKIP is logged as an event too" "SKIP" "$(printf '%s\n' "$EVENTS" | head -1 | jq -r .title)"
check "debug: the event carries the style in effect" $'Start with the ticket ID.\nKeep it short.' "$(printf '%s\n' "$EVENTS" | tail -1 | jq -r .style)"
rm -f "$CLAUDE_PLUGIN_DATA/config.json" "$CLAUDE_PLUGIN_DATA/debug.log"

echo ""
echo "=== stop-title.sh ==="

new_session stopfirst
human "refactor utils module"
reply "extracted format_date to date_utils.py"
STUB_TITLE="Refactor utils" run_stop
check "no title yet: Stop writes one" "Refactor utils" "$(last_title)"

# Claude Code hands Stop the final reply as last_assistant_message; the
# transcript isn't guaranteed to hold it yet.
new_session lastmsg
human "migrate the settings page to the new form library"
reply "Started on the settings form; the transcript may still end with this earlier text."
STUB_TITLE="Migrate settings form" run_stop "Finished: the settings page now uses the new form library and every field validates."
grep -q '^CLAUDE: Finished: the settings page now uses the new form library' "$STUB_LOG" \
  && report PASS "Stop takes the Claude excerpt from last_assistant_message" || report FAIL "Stop read the excerpt from the transcript: $(grep '^CLAUDE:' "$STUB_LOG")"
new_session lastmsg-error
human "migrate the settings page to the new form library"
reply "Started on the settings form, wiring up the validation rules for every field."
STUB_TITLE="Migrate settings form" run_stop "API Error: 500 Internal server error, please retry the request in a moment"
grep -q '^CLAUDE: Started on the settings form' "$STUB_LOG" \
  && report PASS "error text as last_assistant_message: transcript used instead" || report FAIL "error text reached the model: $(grep '^CLAUDE:' "$STUB_LOG")"
new_session lastmsg-absent
human "migrate the settings page to the new form library"
reply "Started on the settings form, wiring up the validation rules for every field."
STUB_TITLE="Migrate settings form" run_stop
grep -q '^CLAUDE: Started on the settings form' "$STUB_LOG" \
  && report PASS "no last_assistant_message (older Claude Code): transcript used" || report FAIL "no Claude excerpt: $(grep '^CLAUDE:' "$STUB_LOG")"

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

new_session markers-gone
human "fix the parser" p1
cc_title "Fix parser"
human "now the lexer" p2
STUB_TITLE="Lexer work" run_live "now the lexer" p2 "Fix parser"
check "older plugin title, /tmp markers wiped: adopted and updated" "Lexer work" "$(last_title)"
[[ ! -f "$PIN" ]] && report PASS "older plugin title: not pinned" || report FAIL "pinned by mistake"

new_session renamed
human "fix the parser" p1
jq -nc '{type:"user", message:{role:"user", content:"<command-name>/rename</command-name>\n<command-message>rename</command-message>\n<command-args>Parser cleanup</command-args>"}}' >> "$TX"
cc_title "Parser cleanup"
human "go on" p2
STUB_TITLE="x" run_live "keep going" p2 "Parser cleanup"
check "/rename in the transcript: name kept" "Parser cleanup" "$(last_title)"
[[ -f "$PIN" ]] && report PASS "/rename in the transcript: pinned" || report FAIL "not pinned"

new_session cleared
clear_head "Previous task"
human "start on the export feature" p1
STUB_TITLE="Export feature" run_live "start on the export feature" p1 "Previous task"
check "/clear carried the old title over: replaced by the new task" "Export feature" "$(last_title)"
grep -qF "Previous task" "$STUB_LOG" && report FAIL "/clear: old title shown to the model as CURRENT_TITLE" \
  || report PASS "/clear: the previous session's title isn't this session's CURRENT_TITLE"
check "/clear: carried title kept in history" '["Previous task","Export feature"]' "$(state_get '.history|tojson')"

new_session mentioned
human "how does /rename work" p1
reply "It writes <command-name>/rename</command-name> into the transcript."
cc_title "Explain rename"
human "and /clear?" p2
STUB_TITLE="Explain rename and clear" run_live "and /clear?" p2 "Explain rename"
check "/rename only mentioned in text: still adopted" "Explain rename and clear" "$(last_title)"

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
# Claude Code shows its own first-message title (ai-title) in the tab and the
# statusline's session_name until it holds a custom title; ours never reaches
# it from the transcript alone.
OUT=$(run_apply "")
check "no custom title in Claude Code: sets sessionTitle to latest" \
  '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"Task B"}}' "$OUT"
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
for i in 1 2 3 4 5; do run_apply "A" >/dev/null; run_apply "" >/dev/null; done
MS=$(( ($(now_ms) - START) / 10 ))
(( MS < 150 )) && report PASS "apply-title.sh averages ${MS}ms" || report FAIL "apply-title.sh too slow: ${MS}ms"
new_session applynew
check "brand-new session, no custom title: no output" "" "$(run_apply "")"

# First prompt after /clear: Claude Code shows the previous session's title
# until the next prompt, so the prompt itself stands in for this turn.
new_session applyclear
clear_head "Previous task"
OUT=$(run_apply "Previous task" "start on the export feature")
check "after /clear: first prompt stands in for the carried title" "$(sets_title "start on the export feature")" "$OUT"
check "after /clear: stand-in recorded as ours, no current title yet" \
  '{"latest":"","history":["Previous task","start on the export feature"]}' "$(state_get '{latest, history}|tojson')"
[[ ! -f "$PIN" && ! -d "$STATE_DIR/$H.lock" ]] && report PASS "after /clear: not pinned, lock released" || report FAIL "pinned or lock left"
human "start on the export feature" p1
STUB_TITLE="Export feature" run_live "start on the export feature" p1 "Previous task"
check "after /clear: the generated title follows" "Export feature" "$(last_title)"
grep -qE "CURRENT_TITLE: (Previous task|start on)" "$STUB_LOG" && report FAIL "stand-in or old title sent as CURRENT_TITLE" \
  || report PASS "after /clear: model sees no CURRENT_TITLE"
cc_title "start on the export feature"   # Claude Code re-appends its title
run_stop
check "after /clear: Stop restores ours over the re-appended stand-in" "Export feature" "$(last_title)"
check "after /clear: next prompt swaps the stand-in for the title" "$(sets_title "Export feature")" "$(run_apply "start on the export feature")"
[[ ! -f "$PIN" ]] && report PASS "after /clear: never pinned" || report FAIL "pinned by mistake"

new_session applyclearlong
clear_head "Previous task"
OUT=$(run_apply "Previous task" "似乎我执行 clear 命令之后，然后再去对话写了一个新任务的时候，它并没有把标题重新命名")
STANDIN=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.sessionTitle')
W=$(bash -c 'source "$1/hooks/lib/common.sh"; display_width "$2"' _ "$SCRIPT_DIR" "$STANDIN")
[[ "$STANDIN" == 似乎我执行*… ]] && (( W <= 30 )) && report PASS "after /clear: long prompt cut to $W columns ($STANDIN)" \
  || report FAIL "after /clear: long prompt stand-in [$STANDIN] is $W columns"
new_session applyclearwords
clear_head "Previous task"
OUT=$(run_apply "Previous task" "Explain the difference between a process and a thread in two sentences.")
check "after /clear: English prompt cut at a word" "$(sets_title "Explain the difference…")" "$OUT"
new_session applyclearword
clear_head "Previous task"
OUT=$(run_apply "Previous task" "supercalifragilisticexpialidocious-and-more-hyphenated-text")
check "after /clear: one long word cut where it hits the limit" "$(sets_title "supercalifragilisticexpialido…")" "$OUT"
new_session applyclearspaces
clear_head "Previous task"
OUT=$(run_apply "Previous task" $'  fix   the\n\nlogin bug  ')
check "after /clear: whitespace collapsed" "$(sets_title "fix the login bug")" "$OUT"

new_session applyclearhi
clear_head "Previous task"
check "after /clear, greeting: stands in too" "$(sets_title "hi")" "$(run_apply "Previous task" "hi")"
human "hi" p1
STUB_TITLE="SKIP" run_live "hi" p1 "Previous task"
check "greeting: still no title of ours" "" "$(state_get .latest)"
check "after the greeting, the task's prompt stands in" "$(sets_title "fix the parser")" "$(run_apply "hi" "fix the parser")"
check "same prompt again: no output" "" "$(run_apply "fix the parser" "fix the parser")"

START=$(now_ms)
for i in 1 2 3 4 5; do
  new_session "applyclearfast$i"
  clear_head "Previous task"
  run_apply "Previous task" "start on the export feature" >/dev/null
done
MS=$(( ($(now_ms) - START) / 5 ))
(( MS < 300 )) && report PASS "stand-in after /clear averages ${MS}ms" || report FAIL "stand-in too slow: ${MS}ms"

new_session applyclearcmd
clear_head "Previous task"
check "after /clear, bare slash command: no output" "" "$(run_apply "Previous task" "/help")"
[[ ! -f "$ST" ]] && report PASS "after /clear, bare slash command: state left to the async hooks" || report FAIL "state created"
new_session applyclearbusy
clear_head "Previous task"
mkdir -p "$STATE_DIR/$H.lock"
OUT=$(run_apply "Previous task" "start on the export feature"; echo "rc=$?")
check "after /clear, lock held by a generation: no output, exit 0" "rc=0" "$OUT"
rm -rf "$STATE_DIR/$H.lock"
new_session applynamed
cc_title "Name from --name"
check "unknown session named before its first prompt: no output" "" "$(run_apply "Name from --name" "do things")"
[[ ! -f "$ST" && ! -f "$PIN" ]] && report PASS "named session: left to the async hooks" || report FAIL "state or pin created"
new_session applyclearold
clear_head "Previous task"
human "start on the export feature" p1
reply "Done."
cc_title "Export feature"
check "resumed /clear session the plugin never saw: no stand-in" "" "$(run_apply "Export feature" "and the import")"

echo ""
echo "=== model call time budget ==="
# One hook run holds the session lock, so all of its model calls together
# must finish well inside LOCK_STALE_SECS, or a second generation starts
# while the first is still running.
ask_model_with() {   # <shell snippet run after sourcing common.sh>; prints MODEL_STATUS
  bash -c 'source "$1/hooks/lib/common.sh"; detect_platform; '"$1"'
    _ask_model "<task>x</task>" >/dev/null 2>&1; echo "$MODEL_STATUS"' _ "$SCRIPT_DIR"
}
R=$(bash -c 'source "$1/hooks/lib/common.sh"; _run_with_timeout 1 /dev/null sleep 5; echo "rc=$? timed_out=$RUN_TIMED_OUT"' _ "$SCRIPT_DIR")
check "_run_with_timeout: a hanging command is killed and flagged" "rc=143 timed_out=true" "$R"
R=$(bash -c 'source "$1/hooks/lib/common.sh"; _run_with_timeout 5 /dev/null true; echo "rc=$? timed_out=$RUN_TIMED_OUT"' _ "$SCRIPT_DIR")
check "_run_with_timeout: a quick command is not flagged" "rc=0 timed_out=false" "$R"

new_session timeout
START=$(now_ms)
STATUS=$(STUB_MODE=hang ask_model_with 'MODEL_TIMEOUT_SECS=1')
ELAPSED=$(( ($(now_ms) - START) / 1000 ))
check "hung model call: status is timeout" "timeout" "$STATUS"
check "hung model call: not retried with the basic flag set" "1" "$(calls)"
(( ELAPSED < 10 )) && report PASS "hung model call: killed after MODEL_TIMEOUT_SECS (${ELAPSED}s)" || report FAIL "hung model call took ${ELAPSED}s"
[[ -f "$CLAUDE_PLUGIN_DATA/cooldown-until" ]] && report PASS "hung model call: cooldown set" || report FAIL "no cooldown after a timeout"

new_session budget
STATUS=$(ask_model_with 'GEN_DEADLINE=$(( $(date +%s) - 1 ))')
check "run budget spent: no call made" "0" "$(calls)"
check "run budget spent: status says so" "budget" "$STATUS"
[[ ! -f "$CLAUDE_PLUGIN_DATA/cooldown-until" ]] && report PASS "run budget spent: no cooldown, the API didn't fail" || report FAIL "cooldown set"

new_session budgetcap
START=$(now_ms)
STATUS=$(STUB_MODE=hang ask_model_with 'GEN_DEADLINE=$(( $(date +%s) + 2 ))')
ELAPSED=$(( ($(now_ms) - START) / 1000 ))
check "2s of budget left: the call gets only that" "timeout" "$STATUS"
(( ELAPSED < 10 )) && report PASS "2s of budget left: killed at the deadline (${ELAPSED}s)" || report FAIL "call ran ${ELAPSED}s past the budget"
R=$(bash -c 'source "$1/hooks/lib/common.sh"; echo "${GEN_BUDGET_SECS:-0} ${LOCK_STALE_SECS:-0}"' _ "$SCRIPT_DIR")
BUDGET=${R% *}; STALE=${R#* }
(( BUDGET > 0 && BUDGET < STALE )) && report PASS "run budget (${BUDGET}s) is below the stale-lock age (${STALE}s)" || report FAIL "budget/stale-lock: $R"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && echo "All tests passed!" || exit 1
