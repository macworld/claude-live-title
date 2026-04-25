#!/usr/bin/env bash
# stop-title.sh — Stop hook entry point
# Fallback: generates title at session end if live hook didn't.
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

[[ -z "$SESSION_ID" || -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]] && exit 0

SAFE_ID=$(sanitize_session_id "$SESSION_ID")
[[ -z "$SAFE_ID" ]] && exit 0

load_config
log "stop-title triggered: session=$SESSION_ID (safe=$SAFE_ID)"

# ── Defer if Live hook is currently running ──
# Live holds its lock across its full title-generation cycle; if we see it,
# Live will write the title, so we skip to avoid concurrent generation.
LOCK_DIR="/tmp/claude-live-title-lock-${SAFE_ID}"
if [[ -d "$LOCK_DIR" ]]; then
  LOCK_AGE=$(( $(date +%s) - $(get_mtime "$LOCK_DIR") ))
  if [[ "$LOCK_AGE" -lt 60 ]]; then
    log "Live hook active (lock age=${LOCK_AGE}s), deferring"
    exit 0
  fi
  log "Stale Live lock (${LOCK_AGE}s), cleaning up"
  rm -rf "$LOCK_DIR"
fi

# ── Dedup: skip if already named by this Stop hook ──
# Marker is a directory so creation is atomic (mkdir succeeds for exactly one
# caller in a concurrent-Stop race); the previous file-marker had a TOCTOU
# window between the existence check and the touch.
MARKER="/tmp/claude-live-title-named-${SAFE_ID}"
[[ -d "$MARKER" ]] && { log "Already named (marker exists)"; exit 0; }

# ── Skip if live hook already wrote a custom-title ──
# `jq -e` exits 0 only when at least one record matches the selector, so
# this is a structured replacement for the previous substring grep (which
# could false-positive on user content that happened to quote the type tag).
if jq -e 'select(.type=="custom-title")' "$TRANSCRIPT_PATH" >/dev/null 2>&1; then
  mkdir -p "$MARKER" 2>/dev/null || true
  log "Already named (custom-title found in transcript)"
  rm -f "/tmp/claude-live-title-state-${SAFE_ID}"
  rm -rf "/tmp/claude-live-title-lock-${SAFE_ID}"
  exit 0
fi

# ── Atomically claim the marker to prevent concurrent Stop runs ──
if ! mkdir "$MARKER" 2>/dev/null; then
  log "Marker claimed by concurrent Stop hook"
  exit 0
fi

# ── Extract, generate, write ──
GOAL=$(extract_goal_message "$TRANSCRIPT_PATH")
USER_MSGS=$(extract_user_messages "$TRANSCRIPT_PATH" "" "$GOAL" || true)
AI_RAW=$(extract_last_ai_text "$TRANSCRIPT_PATH")
AI_TEXT=$(sanitize_ai_text "$AI_RAW")
DIALOG=$(format_dialog "$GOAL" "$USER_MSGS" "$AI_TEXT")

if [[ -z "$DIALOG" ]]; then
  rm -rf "$MARKER"
  exit 0
fi

TITLE_RAW=$(generate_title "$DIALOG" || true)
if [[ -z "$TITLE_RAW" ]]; then
  rm -rf "$MARKER"
  log "Title generation failed or empty"
  exit 0
fi

TITLE=$(clean_title "$TITLE_RAW")
if [[ -z "$TITLE" ]]; then
  rm -rf "$MARKER"
  log "Title empty after cleanup"
  exit 0
fi

write_title "$TRANSCRIPT_PATH" "$TITLE" "$SESSION_ID"
log_replay_event "$DIALOG" "$TITLE" "$SESSION_ID"
log "Stop hook: title written"

# ── Clean up live hook temp files ──
rm -f "/tmp/claude-live-title-state-${SAFE_ID}"
rm -rf "/tmp/claude-live-title-lock-${SAFE_ID}"
