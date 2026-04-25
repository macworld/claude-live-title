#!/usr/bin/env bash
# test-entry.sh — Integration tests for live-title.sh and stop-title.sh.
# Runs each entry script end-to-end with a stubbed `claude -p` and a fixture
# transcript, then asserts on the custom-title record (or its absence).
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

# Stub `claude` in PATH that emits a deterministic stream-json title chosen
# by $STUB_CLAUDE_TITLE. We don't care about its CLI args — just that it
# exits 0 with one assistant text record on stdout.
FIX=$(mktemp -d)
mkdir -p "$FIX/bin"
cat > "$FIX/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
title="${STUB_CLAUDE_TITLE:-stub-title}"
printf '%s\n' '{"type":"system","subtype":"init"}'
printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"${title//\"/\\\"}\"}]}}"
STUB
chmod +x "$FIX/bin/claude"
export PATH="$FIX/bin:$PATH"

cleanup() {
  rm -rf "$FIX" \
    /tmp/claude-live-title-lock-* \
    /tmp/claude-live-title-named-* \
    /tmp/claude-live-title-state-* 2>/dev/null || true
}
trap cleanup EXIT

# Mirror common.sh sanitize_session_id (sha256 of the session id)
sid_hash() {
  printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

clear_state() {
  local h="$1"
  rm -rf "/tmp/claude-live-title-lock-$h" \
         "/tmp/claude-live-title-named-$h" \
         "/tmp/claude-live-title-state-$h" 2>/dev/null || true
}

# Run a hook script. JSON stdin is built via jq so newlines / quotes in the
# prompt are escaped correctly.
run_hook() {
  local script="$1" sid="$2" tx="$3" prompt="${4-}"
  local stdin_json
  if [[ -n "$prompt" ]]; then
    stdin_json=$(jq -nc --arg sid "$sid" --arg tx "$tx" --arg p "$prompt" \
      '{session_id:$sid, transcript_path:$tx, prompt:$p}')
  else
    stdin_json=$(jq -nc --arg sid "$sid" --arg tx "$tx" \
      '{session_id:$sid, transcript_path:$tx}')
  fi
  printf '%s\n' "$stdin_json" | bash "$SCRIPT_DIR/hooks/$script"
}

last_custom_title() {
  jq -c 'select(.type=="custom-title")' "$1" 2>/dev/null | tail -1
}

custom_title_count() {
  jq -c 'select(.type=="custom-title")' "$1" 2>/dev/null | wc -l | tr -d ' '
}

echo "=== live-title.sh ==="

# Scenario 1: fresh session (transcript empty), PROMPT drives GOAL fallback
SID="entry-fresh-$$"
H=$(sid_hash "$SID")
clear_state "$H"
TX="$FIX/fresh.jsonl"
: > "$TX"
STUB_CLAUDE_TITLE="fresh-title" run_hook live-title.sh "$SID" "$TX" "fix logout flow"
rec=$(last_custom_title "$TX")
if [[ -n "$rec" ]] \
   && [[ "$(echo "$rec" | jq -r '.customTitle')" == "fresh-title" ]] \
   && [[ "$(echo "$rec" | jq -r '.sessionId')" == "$SID" ]]; then
  report PASS "fresh session: PROMPT becomes GOAL, title written"
else
  report FAIL "fresh: rec=[$rec]"
fi
clear_state "$H"

# Scenario 2: throttle PASSES (state file shows old timestamp + enough new msgs)
SID="entry-throttle-pass-$$"
H=$(sid_hash "$SID")
clear_state "$H"
TX="$FIX/throttle-pass.jsonl"
{
  echo '{"type":"user","message":{"content":"first"}}'
  echo '{"type":"user","message":{"content":"second"}}'
  echo '{"type":"user","message":{"content":"third"}}'
  echo '{"type":"user","message":{"content":"fourth"}}'
  echo '{"type":"user","message":{"content":"fifth"}}'
} > "$TX"
NOW=$(date +%s)
echo "$((NOW - 300)) 2" > "/tmp/claude-live-title-state-$H"  # 300s ago, last count=2 → 3 new ≥ 2 OK
STUB_CLAUDE_TITLE="throttle-pass" run_hook live-title.sh "$SID" "$TX" "current"
rec=$(last_custom_title "$TX")
if [[ "$(echo "$rec" | jq -r '.customTitle')" == "throttle-pass" ]]; then
  report PASS "throttle pass: state file old enough, title written"
else
  report FAIL "throttle-pass: rec=[$rec]"
fi
clear_state "$H"

# Scenario 3: throttle BLOCKS (state file recent → skip)
SID="entry-throttle-block-$$"
H=$(sid_hash "$SID")
clear_state "$H"
TX="$FIX/throttle-block.jsonl"
{
  echo '{"type":"user","message":{"content":"a"}}'
  echo '{"type":"user","message":{"content":"b"}}'
} > "$TX"
NOW=$(date +%s)
echo "$((NOW - 30)) 2" > "/tmp/claude-live-title-state-$H"  # 30s ago, last count=2 → 0 new
STUB_CLAUDE_TITLE="should-not-write" run_hook live-title.sh "$SID" "$TX" "still here"
if [[ "$(custom_title_count "$TX")" -eq 0 ]]; then
  report PASS "throttle block: recent state, no title written"
else
  report FAIL "throttle-block: $(last_custom_title "$TX")"
fi
clear_state "$H"

# Scenario 4: multi-line first user prompt → GOAL flattened end-to-end
SID="entry-multi-$$"
H=$(sid_hash "$SID")
clear_state "$H"
TX="$FIX/multi.jsonl"
echo '{"type":"user","message":{"content":"fix this:\nstack trace line 1\nstack trace line 2"}}' > "$TX"
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"acknowledged"}]}}' >> "$TX"
STUB_CLAUDE_TITLE="multi-flat" run_hook stop-title.sh "$SID" "$TX"
rec=$(last_custom_title "$TX")
if [[ "$(echo "$rec" | jq -r '.customTitle')" == "multi-flat" ]] \
   && [[ "$(echo "$rec" | jq -r '.sessionId')" == "$SID" ]]; then
  report PASS "multi-line first prompt: GOAL flattened, title written"
else
  report FAIL "multi-line: rec=[$rec]"
fi
clear_state "$H"

# Scenario 5: lock contention — fresh lock dir present → live-title exits silently
SID="entry-locked-$$"
H=$(sid_hash "$SID")
clear_state "$H"
TX="$FIX/locked.jsonl"
echo '{"type":"user","message":{"content":"some prompt"}}' > "$TX"
mkdir "/tmp/claude-live-title-lock-$H"
echo "1234" > "/tmp/claude-live-title-lock-$H/pid"
STUB_CLAUDE_TITLE="locked-title" run_hook live-title.sh "$SID" "$TX" "ignored" || true
if [[ "$(custom_title_count "$TX")" -eq 0 ]]; then
  report PASS "lock contention: live-title exited without writing"
else
  report FAIL "lock-contention: $(last_custom_title "$TX")"
fi
clear_state "$H"

echo ""
echo "=== stop-title.sh ==="

# Scenario 6: basic stop-title flow → writes title
SID="entry-stop-basic-$$"
H=$(sid_hash "$SID")
clear_state "$H"
TX="$FIX/stop-basic.jsonl"
{
  echo '{"type":"user","message":{"content":"refactor utils module"}}'
  echo '{"type":"assistant","message":{"content":[{"type":"text","text":"extracted format_date to date_utils.py"}]}}'
} > "$TX"
STUB_CLAUDE_TITLE="stop-basic" run_hook stop-title.sh "$SID" "$TX"
rec=$(last_custom_title "$TX")
if [[ "$(echo "$rec" | jq -r '.customTitle')" == "stop-basic" ]]; then
  report PASS "stop basic: title written"
else
  report FAIL "stop-basic: rec=[$rec]"
fi
# Marker dir should now exist
if [[ -d "/tmp/claude-live-title-named-$H" ]]; then
  report PASS "stop basic: marker directory created"
else
  report FAIL "stop-basic: marker missing"
fi
clear_state "$H"

# Scenario 7: existing custom-title in transcript → skip, marker set, no rewrite
SID="entry-stop-existing-$$"
H=$(sid_hash "$SID")
clear_state "$H"
TX="$FIX/stop-existing.jsonl"
{
  echo '{"type":"user","message":{"content":"some prompt"}}'
  echo '{"type":"custom-title","customTitle":"already-set","sessionId":"'"$SID"'"}'
} > "$TX"
LINES_BEFORE=$(wc -l < "$TX")
STUB_CLAUDE_TITLE="should-not-write" run_hook stop-title.sh "$SID" "$TX"
LINES_AFTER=$(wc -l < "$TX")
if [[ "$LINES_BEFORE" -eq "$LINES_AFTER" ]] \
   && [[ "$(last_custom_title "$TX" | jq -r .customTitle)" == "already-set" ]]; then
  report PASS "stop existing: skipped, transcript untouched"
else
  report FAIL "stop-existing: lines $LINES_BEFORE -> $LINES_AFTER, last=$(last_custom_title "$TX")"
fi
clear_state "$H"

# Scenario 8: stop-title defers when Live lock is fresh
SID="entry-stop-deferlock-$$"
H=$(sid_hash "$SID")
clear_state "$H"
TX="$FIX/stop-defer.jsonl"
echo '{"type":"user","message":{"content":"in flight"}}' > "$TX"
mkdir "/tmp/claude-live-title-lock-$H"
echo "5678" > "/tmp/claude-live-title-lock-$H/pid"
STUB_CLAUDE_TITLE="should-not-write" run_hook stop-title.sh "$SID" "$TX"
if [[ "$(custom_title_count "$TX")" -eq 0 ]]; then
  report PASS "stop defer: fresh Live lock seen, stop exits without writing"
else
  report FAIL "stop-defer: $(last_custom_title "$TX")"
fi
clear_state "$H"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && echo "All tests passed!" || exit 1
