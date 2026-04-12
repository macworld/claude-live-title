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

# ── Dedup: skip if already named by this Stop hook ──
MARKER="/tmp/claude-live-title-named-${SAFE_ID}"
[[ -f "$MARKER" ]] && { log "Already named (marker exists)"; exit 0; }

# ── Skip if live hook already wrote a custom-title ──
if grep -q '"type":"custom-title"' "$TRANSCRIPT_PATH" 2>/dev/null; then
  touch "$MARKER"
  log "Already named (custom-title found in transcript)"
  rm -f "/tmp/claude-live-title-state-${SAFE_ID}"
  rm -rf "/tmp/claude-live-title-lock-${SAFE_ID}"
  exit 0
fi

# ── Create marker to prevent concurrent runs ──
touch "$MARKER"

# ── Extract, generate, write ──
USER_MSGS=$(extract_user_messages "$TRANSCRIPT_PATH" || true)
if [[ -z "$USER_MSGS" ]]; then
  rm -f "$MARKER"
  exit 0
fi

TITLE_RAW=$(generate_title "$USER_MSGS" || true)
if [[ -z "$TITLE_RAW" ]]; then
  rm -f "$MARKER"
  log "Title generation failed or empty"
  exit 0
fi

TITLE=$(clean_title "$TITLE_RAW")
if [[ -z "$TITLE" ]]; then
  rm -f "$MARKER"
  log "Title empty after cleanup"
  exit 0
fi

write_title "$TRANSCRIPT_PATH" "$TITLE" "$SESSION_ID"
log "Stop hook: title written"

# ── Clean up live hook temp files ──
rm -f "/tmp/claude-live-title-state-${SAFE_ID}"
rm -rf "/tmp/claude-live-title-lock-${SAFE_ID}"
