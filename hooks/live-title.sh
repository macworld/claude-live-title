#!/usr/bin/env bash
# live-title.sh — UserPromptSubmit hook entry point
# Generates/updates session title in real-time with throttling.
# Fires immediately when the user submits a message, so the title is
# typically ready before Claude finishes responding (and before HUD renders).
set -eu

# Skip when invoked by our own `claude -p` subsession — otherwise the
# title-generation subprocess would recursively trigger this hook.
[[ -n "${CLAUDE_LIVE_TITLE_INTERNAL:-}" ]] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ── Initialize ──
detect_platform
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
# UserPromptSubmit delivers the current prompt here before it's in transcript.
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')

[[ -z "$SESSION_ID" || -z "$TRANSCRIPT_PATH" ]] && exit 0

SAFE_ID=$(sanitize_session_id "$SESSION_ID")
[[ -z "$SAFE_ID" ]] && exit 0

load_config

# ── Check live update switch ──
[[ "$LIVE_UPDATE" != "true" ]] && { log "Live update disabled"; exit 0; }

# ── Acquire lock BEFORE waiting / generating ──
# Holding the lock early lets the Stop hook see "Live is working" and defer,
# preventing both hooks from generating titles concurrently.
LOCK_DIR="/tmp/claude-live-title-lock-${SAFE_ID}"
acquire_lock "$LOCK_DIR" || exit 0
trap 'release_lock "$LOCK_DIR"' EXIT

# ── Wait for transcript (fresh-session race) ──
# On turn 1 of a brand-new session, UserPromptSubmit can fire ~100ms before
# CC creates the transcript file. Poll briefly for it to appear.
WAIT_ITERS=0
while [[ ! -f "$TRANSCRIPT_PATH" && "$WAIT_ITERS" -lt 10 ]]; do
  sleep 0.1
  WAIT_ITERS=$(( WAIT_ITERS + 1 ))
done
[[ ! -f "$TRANSCRIPT_PATH" ]] && exit 0

log "live-title triggered: session=$SESSION_ID (safe=$SAFE_ID) transcript_wait=${WAIT_ITERS}x100ms"

# ── Count user messages ──
TOTAL_MSGS=$(jq -c 'select(.type == "user")' "$TRANSCRIPT_PATH" 2>/dev/null | wc -l || echo 0)
# On a brand-new session the transcript has no user entries yet, but we can
# still title from $PROMPT alone. Only bail when we truly have nothing.
[[ "$TOTAL_MSGS" -eq 0 && -z "$PROMPT" ]] && exit 0

# ── Throttle check ──
NOW=$(date +%s)
STATE_FILE="/tmp/claude-live-title-state-${SAFE_ID}"

if [[ -f "$STATE_FILE" ]]; then
  if read -r LAST_TIME LAST_COUNT < "$STATE_FILE" 2>/dev/null \
     && [[ -n "$LAST_TIME" && -n "$LAST_COUNT" ]]; then
    ELAPSED=$(( NOW - LAST_TIME ))
    NEW_MSGS=$(( TOTAL_MSGS - LAST_COUNT ))
    if [[ "$ELAPSED" -lt "$THROTTLE_INTERVAL" || "$NEW_MSGS" -lt "$THROTTLE_MESSAGES" ]]; then
      log "Throttled: elapsed=${ELAPSED}s new_msgs=${NEW_MSGS}"
      exit 0
    fi
  else
    # Corrupted state file, remove and treat as first run
    rm -f "$STATE_FILE"
  fi
fi
# No state file = first run in this session, proceed immediately

# ── Extract, generate, write ──
GOAL=$(extract_goal_message "$TRANSCRIPT_PATH")
# Fresh-session turn-1 race: transcript hasn't been flushed yet, but the
# prompt itself is the goal.
[[ -z "$GOAL" && -n "$PROMPT" ]] && GOAL="$PROMPT"

USER_MSGS=$(extract_user_messages "$TRANSCRIPT_PATH" "$PROMPT" "$GOAL" || true)
AI_RAW=$(extract_last_ai_text "$TRANSCRIPT_PATH")
AI_TEXT=$(sanitize_ai_text "$AI_RAW")
DIALOG=$(format_dialog "$GOAL" "$USER_MSGS" "$AI_TEXT")

[[ -z "$DIALOG" ]] && { log "Empty dialog, skipping"; exit 0; }

TITLE_RAW=$(generate_title "$DIALOG") || { log "Title generation failed"; exit 0; }
TITLE=$(clean_title "$TITLE_RAW")

if [[ -z "$TITLE" ]]; then
  log "Title empty after cleanup"
  exit 0
fi

write_title "$TRANSCRIPT_PATH" "$TITLE" "$SESSION_ID"
log_replay_event "$DIALOG" "$TITLE" "$SESSION_ID"

# ── Update state AFTER successful generation ──
echo "$NOW $TOTAL_MSGS" > "$STATE_FILE"
log "State updated: time=$NOW msgs=$TOTAL_MSGS"
