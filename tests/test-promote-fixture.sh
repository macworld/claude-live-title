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

# Seed the log with two title-generated events plus an unrelated log line
{
  echo "[2026-04-25 12:00:00] [123] some unrelated log entry"
  jq -nc '{event:"title-generated", ts:"2026-04-25T12:00:01Z", session_id:"sess-A",
    dialog:"GOAL: refactor auth\nUSER: split jwt parsing\nSTATE: extracted parse_jwt to lib/auth/jwt.py",
    title:"refactor auth jwt"}'
  jq -nc '{event:"title-generated", ts:"2026-04-25T12:05:00Z", session_id:"sess-B",
    dialog:"GOAL: 修复 logout 流程\nUSER: 看下 cookie 设置\nSTATE: 已修",
    title:"修复 logout cookie"}'
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

# Transcript shape: 1 user goal + 1 user mid + 1 assistant state
GOAL_C=$(jq -c 'select(.type=="user")' "$TX" | head -1 | jq -r '.message.content')
STATE_C=$(jq -c 'select(.type=="assistant")' "$TX" | head -1 | jq -r '.message.content[0].text')
USER_COUNT=$(jq -c 'select(.type=="user")' "$TX" | wc -l | tr -d ' ')
if [[ "$GOAL_C" == "修复 logout 流程" && "$STATE_C" == "已修" && "$USER_COUNT" == "2" ]]; then
  report PASS "transcript reproduces dialog structure"
else
  report FAIL "transcript: GOAL=$GOAL_C STATE=$STATE_C users=$USER_COUNT"
fi

# expected.yaml has the stub fields
if grep -q '^must_contain_any: \[\]' "$EXP" && grep -q '^must_not_contain: \[\]' "$EXP"; then
  report PASS "expected.yaml seeds empty assertions"
else
  report FAIL "expected.yaml missing stubs"
fi

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
