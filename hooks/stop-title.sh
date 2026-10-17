#!/usr/bin/env bash
# stop-title.sh — Stop hook (async), runs after every Claude reply
#   1. Restores our latest title if Claude Code re-appended an older one
#      during the turn, so the idle session shows the right name.
#   2. Generates a title when the session has none yet (and a message came
#      in since the model last found no task in it), when user messages
#      arrived that the live hook skipped (throttle; bare "ok"/"继续" don't
#      count), or when the last check is REFRESH_INTERVAL old, so long
#      autonomous runs stay current. The reply the model sees is the one
#      Claude Code hands this hook; the transcript may not hold it yet.
set -eu

# Skip when invoked by our own `claude -p` subsession — otherwise the
# title-generation subprocess would recursively trigger this hook.
[[ -n "${CLAUDE_LIVE_TITLE_INTERNAL:-}" ]] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ── Initialize ──
detect_platform
INPUT=$(cat)
exec >/dev/null
IFS=$'\x1f' read -r SESSION_ID TRANSCRIPT_PATH CWD <<< "$(printf '%s' "$INPUT" | jq -r \
  '[(.session_id // ""), (.transcript_path // ""), (.cwd // "")] | join("\u001f")')"
LAST_REPLY=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null) || LAST_REPLY=""

[[ -z "$SESSION_ID" || -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]] && exit 0

load_config
load_project_style "$CWD"
state_init "$(sanitize_session_id "$SESSION_ID")"
is_pinned && exit 0
log "stop-title triggered: session=$SESSION_ID"

# Let a running live generation finish first; it may make ours unnecessary.
acquire_lock "$LOCK_DIR" 45 || exit 0
trap 'release_lock "$LOCK_DIR"' EXIT

HUMANS=$(extract_human_messages "$TRANSCRIPT_PATH")
HUMAN_COUNT=$(printf '%s' "$HUMANS" | jq 'length')

state_bootstrap "$TRANSCRIPT_PATH" "" "$HUMAN_COUNT"
is_pinned && exit 0
state_load

# ── Repair ──
LAST=$(last_custom_title "$TRANSCRIPT_PATH")
check_foreign_title "$LAST" || exit 0
if [[ -n "$ST_LATEST" && "$LAST" != "$ST_LATEST" ]]; then
  log "Transcript ends with '$LAST'; restoring '$ST_LATEST'"
  write_title "$TRANSCRIPT_PATH" "$ST_LATEST" "$SESSION_ID"
fi

maybe_cleanup_state

# ── Decide whether to generate ──
[[ "$HUMAN_COUNT" -gt 0 ]] || exit 0
NOW=$(date +%s)
TRIGGER=""
if [[ -z "$ST_LATEST" ]]; then
  # Messages the model found no task in are counted; only new ones retry.
  if (( HUMAN_COUNT > ST_LAST_HUMAN )); then TRIGGER="first"; fi
elif [[ "$LIVE_UPDATE" != "true" ]]; then
  exit 0
else
  if (( HUMAN_COUNT > ST_LAST_HUMAN )); then
    if only_acks_since "$HUMANS" "$ST_LAST_HUMAN"; then
      state_save "$ST_LATEST" "$ST_LAST_GEN" "$HUMAN_COUNT"
    else
      TRIGGER="catch-up"
    fi
  fi
  if [[ -z "$TRIGGER" ]] && (( NOW - ST_LAST_GEN >= REFRESH_INTERVAL )); then
    TRIGGER="refresh"
  fi
fi
[[ -z "$TRIGGER" ]] && exit 0
cooldown_active && { log "Cooldown active, skipping $TRIGGER"; exit 0; }

log "Stop generating ($TRIGGER): humans=$HUMAN_COUNT last=$ST_LAST_HUMAN age=$(( NOW - ST_LAST_GEN ))s"
title_update "$TRANSCRIPT_PATH" "$SESSION_ID" "$HUMANS" "$TRIGGER" "$LAST_REPLY"
