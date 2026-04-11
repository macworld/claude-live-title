#!/usr/bin/env bash
# test-throttle.sh — Verify throttle logic respects config values
# Tests the throttle decision in isolation (no AI calls)
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

# Source common.sh to get load_config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/hooks/lib/common.sh"
detect_platform

CONFIG="$HOME/.claude/plugins/claude-live-title/config.json"
mkdir -p "$(dirname "$CONFIG")"
ORIG_CONFIG=""
[[ -f "$CONFIG" ]] && ORIG_CONFIG=$(cat "$CONFIG")

cleanup() {
  if [[ -n "$ORIG_CONFIG" ]]; then
    echo "$ORIG_CONFIG" > "$CONFIG"
  fi
}
trap cleanup EXIT

# Throttle decision function (extracted from live-title.sh logic)
# Returns 0 = should proceed, 1 = should throttle
should_update() {
  local now="$1" total_msgs="$2" state_file="$3"
  if [[ -f "$state_file" ]]; then
    local last_time last_count
    if read -r last_time last_count < "$state_file" 2>/dev/null \
       && [[ -n "$last_time" && -n "$last_count" ]]; then
      local elapsed=$(( now - last_time ))
      local new_msgs=$(( total_msgs - last_count ))
      if [[ "$elapsed" -lt "$THROTTLE_INTERVAL" || "$new_msgs" -lt "$THROTTLE_MESSAGES" ]]; then
        return 1  # throttled
      fi
    fi
  fi
  return 0  # proceed
}

NOW=$(date +%s)
STATE="/tmp/test-throttle-state-$$"
rm -f "$STATE"

echo "=== Test 1: Config values are loaded ==="

echo '{"debug": true, "throttleInterval": 240, "throttleMessages": 2}' > "$CONFIG"
load_config

if [[ "$THROTTLE_INTERVAL" == "240" ]]; then report PASS "throttleInterval=240"; else report FAIL "throttleInterval=$THROTTLE_INTERVAL, expected 240"; fi
if [[ "$THROTTLE_MESSAGES" == "2" ]]; then report PASS "throttleMessages=2"; else report FAIL "throttleMessages=$THROTTLE_MESSAGES, expected 2"; fi

echo ""
echo "=== Test 2: First run (no state file) → proceed ==="

rm -f "$STATE"
if should_update "$NOW" 1 "$STATE"; then
  report PASS "First run proceeds"
else
  report FAIL "First run should not be throttled"
fi

echo ""
echo "=== Test 3: Interval not elapsed → throttle ==="

echo "$((NOW - 60)) 3" > "$STATE"  # 60s ago, 3 msgs
if should_update "$NOW" 6 "$STATE"; then
  report FAIL "Should be throttled (only 60s elapsed, need 240s)"
else
  report PASS "Throttled: 60s < 240s interval"
fi

echo ""
echo "=== Test 4: Not enough new messages → throttle ==="

echo "$((NOW - 300)) 5" > "$STATE"  # 300s ago, 5 msgs
if should_update "$NOW" 6 "$STATE"; then  # only 1 new msg
  report FAIL "Should be throttled (only 1 new msg, need 2)"
else
  report PASS "Throttled: 1 new msg < 2 required"
fi

echo ""
echo "=== Test 5: Both conditions met → proceed ==="

echo "$((NOW - 300)) 3" > "$STATE"  # 300s ago, 3 msgs
if should_update "$NOW" 6 "$STATE"; then  # 3 new msgs, 300s elapsed
  report PASS "Proceeds: 300s ≥ 240s AND 3 msgs ≥ 2"
else
  report FAIL "Should not be throttled"
fi

echo ""
echo "=== Test 6: Boundary - exactly at interval → proceed ==="

echo "$((NOW - 240)) 3" > "$STATE"  # exactly 240s ago
if should_update "$NOW" 5 "$STATE"; then  # 2 new msgs (exactly at threshold)
  report PASS "Proceeds: 240s ≥ 240s AND 2 msgs ≥ 2"
else
  report FAIL "Should proceed at exact boundary"
fi

echo ""
echo "=== Test 7: Boundary - one second short → throttle ==="

echo "$((NOW - 239)) 3" > "$STATE"  # 239s ago
if should_update "$NOW" 5 "$STATE"; then  # 2 new msgs
  report FAIL "Should be throttled (239s < 240s)"
else
  report PASS "Throttled: 239s < 240s interval"
fi

echo ""
echo "=== Test 8: Different config values ==="

echo '{"debug": true, "throttleInterval": 60, "throttleMessages": 1}' > "$CONFIG"
load_config

echo "$((NOW - 90)) 3" > "$STATE"  # 90s ago
if should_update "$NOW" 5 "$STATE"; then  # 2 new msgs
  report PASS "Custom config (60s/1msg): proceeds at 90s/2msgs"
else
  report FAIL "Should not be throttled with interval=60, msgs=1"
fi

echo ""
echo "=== Test 9: Default config values ==="

echo '{}' > "$CONFIG"
load_config

if [[ "$THROTTLE_INTERVAL" == "240" ]]; then report PASS "Default interval=240"; else report FAIL "Default interval=$THROTTLE_INTERVAL, expected 240"; fi
if [[ "$THROTTLE_MESSAGES" == "2" ]]; then report PASS "Default messages=2"; else report FAIL "Default messages=$THROTTLE_MESSAGES, expected 2"; fi

rm -f "$STATE"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && echo "All tests passed!" || exit 1
