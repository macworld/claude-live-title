#!/usr/bin/env bash
# test-promote-fixture.sh — smoke tests for bin/promote-fixture.sh
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

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROMOTE="$REPO/bin/promote-fixture.sh"
FIX_DIR="$REPO/tests/fixtures/transcripts"

# Use an isolated debug log so we don't depend on what's actually in /tmp
TMP=$(mktemp -d)
LOG="$TMP/debug.log"
export CLAUDE_LIVE_TITLE_DEBUG_LOG="$LOG"

# Slugs are time-suffixed so re-runs don't collide; cleanup removes them
SLUG="promote-test-$$-$RANDOM"

cleanup() {
  rm -rf "$TMP"
  rm -f "$FIX_DIR"/bad-*-"$SLUG".jsonl "$FIX_DIR"/bad-*-"$SLUG".expected.yaml \
        "$FIX_DIR"/bad-*-"${SLUG}-grep".jsonl "$FIX_DIR"/bad-*-"${SLUG}-grep".expected.yaml 2>/dev/null || true
}
trap cleanup EXIT

# Seed the log with a pre-1.4 event, a current one, and an unrelated line
NEW_DIALOG=$'CURRENT_TITLE: 修复 logout 流程\nFIRST: 修复 logout 流程\nEARLIER: 看下 cookie 设置\nLATEST: 再查一下 session 过期\nCLAUDE: 已修复 cookie 的 SameSite 设置'
{
  echo "[2026-04-25 12:00:00] [123] some unrelated log entry"
  jq -nc '{event:"title-generated", ts:"2026-04-25T12:00:01Z", session_id:"sess-A",
    dialog:"GOAL: refactor auth\nUSER: split jwt parsing\nSTATE: extracted parse_jwt to lib/auth/jwt.py",
    title:"refactor auth jwt"}'
  jq -nc --arg d "$NEW_DIALOG" '{event:"title-generated", ts:"2026-04-25T12:05:00Z", session_id:"sess-B",
    trigger:"prompt", dialog:$d, title:"修复 logout cookie"}'
} > "$LOG"

echo "=== promote-fixture happy path ==="

bash "$PROMOTE" "$SLUG" >/dev/null
TX=$(ls "$FIX_DIR"/bad-*-"$SLUG".jsonl 2>/dev/null | head -1 || echo "")
EXP=$(ls "$FIX_DIR"/bad-*-"$SLUG".expected.yaml 2>/dev/null | head -1 || echo "")
if [[ -f "$TX" && -f "$EXP" ]]; then
  report PASS "creates .jsonl and .expected.yaml"
else
  report FAIL "files missing: TX=$TX EXP=$EXP"
fi

# Most-recent (default index=1) is sess-B → 修复 logout cookie
TITLE_LINE=$(grep '^# *observed_title' "$EXP" || true)
if [[ "$TITLE_LINE" == *"修复 logout cookie"* ]]; then
  report PASS "default index picks the most recent event"
else
  report FAIL "default index: $TITLE_LINE"
fi

# Transcript shape: 3 user messages, the shown title, 1 assistant reply
FIRST_C=$(jq -c 'select(.type=="user")' "$TX" | head -1 | jq -r '.message.content')
CLAUDE_C=$(jq -c 'select(.type=="assistant")' "$TX" | head -1 | jq -r '.message.content[0].text')
USER_COUNT=$(jq -c 'select(.type=="user")' "$TX" | wc -l | tr -d ' ')
SHOWN=$(jq -r 'select(.type=="custom-title") | .customTitle' "$TX")
if [[ "$FIRST_C" == "修复 logout 流程" && "$CLAUDE_C" == "已修复 cookie 的 SameSite 设置" && "$USER_COUNT" == "3" && "$SHOWN" == "修复 logout 流程" ]]; then
  report PASS "transcript reproduces dialog structure"
else
  report FAIL "transcript: FIRST=$FIRST_C CLAUDE=$CLAUDE_C users=$USER_COUNT shown=$SHOWN"
fi

# Round trip: the plugin's own pipeline rebuilds the logged dialog exactly.
REBUILT=$(CLAUDE_PLUGIN_DATA="$TMP/data" bash -c 'source "$1/hooks/lib/common.sh"
  build_dialog "$(last_custom_title "$2")" "$(extract_human_messages "$2")" "$(sanitize_ai_text "$(extract_last_ai_text "$2")")"' _ "$REPO" "$TX")
if [[ "$REBUILT" == "$NEW_DIALOG" ]]; then
  report PASS "replaying the fixture rebuilds the logged dialog"
else
  report FAIL "rebuilt dialog differs: [$REBUILT]"
fi

# expected.yaml has the stub fields
if grep -q '^must_contain_any: \[\]' "$EXP" && grep -q '^must_not_contain: \[\]' "$EXP"; then
  report PASS "expected.yaml seeds empty assertions"
else
  report FAIL "expected.yaml missing stubs"
fi

echo ""
echo "=== promote-fixture keeps the style ==="

STYLE_SLUG="${SLUG}-style"
jq -nc --arg d "$NEW_DIALOG" '{event:"title-generated", ts:"2026-04-25T12:06:00Z", session_id:"sess-C",
  trigger:"prompt", dialog:$d, title:"PROJ-9 logout cookie", style:"Start with the ticket ID.\nKeep it short."}' >> "$LOG"
bash "$PROMOTE" "$STYLE_SLUG" >/dev/null
EXP3=$(ls "$FIX_DIR"/bad-*-"$STYLE_SLUG".expected.yaml 2>/dev/null | head -1 || echo "")
STYLE_LINE=$(grep '^style:' "$EXP3" 2>/dev/null | sed 's/^style:[[:space:]]*//' || true)
if [[ "$(printf '%s' "$STYLE_LINE" | jq -r . 2>/dev/null)" == $'Start with the ticket ID.\nKeep it short.' ]]; then
  report PASS "style written to expected.yaml as a JSON string"
else
  report FAIL "style line: [$STYLE_LINE]"
fi
grep -q '^style:' "$EXP" && report FAIL "event without style got a style line" || report PASS "no style → no style line"
rm -f "$FIX_DIR"/bad-*-"$STYLE_SLUG".jsonl "$EXP3"

echo ""
echo "=== promote-fixture --grep ==="

bash "$PROMOTE" "${SLUG}-grep" --grep "refactor auth" >/dev/null
TX2=$(ls "$FIX_DIR"/bad-*-"${SLUG}-grep".jsonl 2>/dev/null | head -1 || echo "")
EXP2=$(ls "$FIX_DIR"/bad-*-"${SLUG}-grep".expected.yaml 2>/dev/null | head -1 || echo "")
TITLE_LINE2=$(grep '^# *observed_title' "$EXP2" 2>/dev/null || true)
if [[ -f "$TX2" ]] && [[ "$TITLE_LINE2" == *"refactor auth jwt"* ]]; then
  report PASS "--grep picks the matching event"
else
  report FAIL "--grep: TX=$TX2 title=$TITLE_LINE2"
fi
LEGACY_USERS=$(jq -r 'select(.type=="user") | .message.content' "$TX2" 2>/dev/null | paste -sd'|' -)
LEGACY_AI=$(jq -r 'select(.type=="assistant") | .message.content[0].text' "$TX2" 2>/dev/null)
if [[ "$LEGACY_USERS" == "refactor auth|split jwt parsing" && "$LEGACY_AI" == "extracted parse_jwt to lib/auth/jwt.py" ]]; then
  report PASS "pre-1.4 GOAL/USER/STATE dialog still promotes"
else
  report FAIL "legacy dialog: users=$LEGACY_USERS ai=$LEGACY_AI"
fi

echo ""
echo "=== promote-fixture finds the log in the plugin data dir ==="

FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME/.claude/plugins/data/live-title-claude-live-title"
cp "$LOG" "$FAKE_HOME/.claude/plugins/data/live-title-claude-live-title/debug.log"
OUT=$(env -u CLAUDE_LIVE_TITLE_DEBUG_LOG HOME="$FAKE_HOME" bash "$PROMOTE" "${SLUG}-found" 2>&1 || true)
rm -f "$FIX_DIR"/bad-*-"${SLUG}-found".jsonl "$FIX_DIR"/bad-*-"${SLUG}-found".expected.yaml
if [[ "$OUT" == *"Wrote:"* ]]; then
  report PASS "default log location discovered"
else
  report FAIL "default log not found: $OUT"
fi

echo ""
echo "=== promote-fixture error paths ==="

# Bad slug
if bash "$PROMOTE" "bad slug" 2>/dev/null; then
  report FAIL "spaces-in-slug should error"
else
  report PASS "rejects slug with spaces"
fi

# Missing log
CLAUDE_LIVE_TITLE_DEBUG_LOG="$TMP/does-not-exist.log" \
  bash "$PROMOTE" some-slug 2>/dev/null \
  && report FAIL "missing log should error" \
  || report PASS "rejects missing debug log"

# Empty log
: > "$LOG"
if bash "$PROMOTE" empty-slug 2>/dev/null; then
  report FAIL "empty log should error"
else
  report PASS "rejects log with no events"
fi

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && echo "All tests passed!" || exit 1
