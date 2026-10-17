#!/usr/bin/env bash
# live-title.sh — UserPromptSubmit hook (async)
# Generates a fresh title as soon as the user sends a message, in parallel
# with Claude's reply. Prompts Claude Code starts on its own (task
# notifications, subagent hand-backs, messages from other sessions) don't
# change what the user asked for, so they're skipped; stop-title.sh covers
# long autonomous runs.
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
IFS=$'\x1f' read -r SESSION_ID TRANSCRIPT_PATH PROMPT_ID CWD CC_TITLE <<< "$(printf '%s' "$INPUT" | jq -r \
  '[(.session_id // ""), (.transcript_path // ""), (.prompt_id // ""), (.cwd // ""), (.session_title // "" | gsub("[\\r\\n]"; " "))] | join("\u001f")')"
# UserPromptSubmit delivers the current prompt here before it's in transcript.
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty')

[[ -z "$SESSION_ID" || -z "$TRANSCRIPT_PATH" ]] && exit 0

load_config
[[ "$LIVE_UPDATE" != "true" ]] && { log "Live update disabled"; exit 0; }
load_project_style "$CWD"

state_init "$(sanitize_session_id "$SESSION_ID")"
is_pinned && { log "Session pinned, skipping"; exit 0; }
cooldown_active && { log "Cooldown active, skipping"; exit 0; }

log "live-title triggered: session=$SESSION_ID"

# ── Find this prompt in the transcript ──
# On turn 1 of a brand-new session the transcript file appears ~100ms after
# this hook fires, and the prompt's entry lands ~100-200ms later. The entry
# carries `origin`, which tells a typed prompt from one Claude Code started.
ENTRY=""
WAIT_ITERS=0
while [[ "$WAIT_ITERS" -lt 20 ]]; do
  if [[ -f "$TRANSCRIPT_PATH" ]]; then
    [[ -z "$PROMPT_ID" ]] && break
    ENTRY=$(find_prompt_entry "$TRANSCRIPT_PATH" "$PROMPT_ID")
    [[ -n "$ENTRY" ]] && break
  fi
  sleep 0.1
  WAIT_ITERS=$(( WAIT_ITERS + 1 ))
done
[[ ! -f "$TRANSCRIPT_PATH" ]] && { log "Transcript never appeared"; exit 0; }

if [[ -n "$ENTRY" ]]; then
  PROMPT_TEXT=$(entry_human_text "$ENTRY")
else
  PROMPT_TEXT=$(prompt_human_text "$PROMPT")
fi
log "prompt wait=${WAIT_ITERS}x100ms entry=$([[ -n "$ENTRY" ]] && echo found || echo missing) human=$([[ -n "$PROMPT_TEXT" ]] && echo yes || echo no)"
[[ -z "$PROMPT_TEXT" ]] && exit 0

# ── Generate under the session lock ──
# Wait for a generation that's already running (previous prompt or Stop)
# instead of racing it; the throttle below then decides.
acquire_lock "$LOCK_DIR" 30 || exit 0
trap 'release_lock "$LOCK_DIR"' EXIT

HUMANS=$(extract_human_messages "$TRANSCRIPT_PATH")
if [[ -z "$ENTRY" ]]; then
  # Older Claude Code (no prompt_id) or the entry is still in flight.
  HUMANS=$(printf '%s' "$HUMANS" | jq -c --arg p "$PROMPT_TEXT" \
    'if (.[-1] // "") == $p then . else . + [$p] end')
fi
HUMAN_COUNT=$(printf '%s' "$HUMANS" | jq 'length')

state_bootstrap "$TRANSCRIPT_PATH" "$CC_TITLE" "$HUMAN_COUNT"
is_pinned && exit 0
state_load
check_foreign_title "$CC_TITLE" || exit 0

if [[ -n "$ST_LATEST" ]] && only_acks_since "$HUMANS" "$ST_LAST_HUMAN"; then
  log "Only acknowledgements since the last title; keeping it"
  state_save "$ST_LATEST" "$ST_LAST_GEN" "$HUMAN_COUNT"
  exit 0
fi

NOW=$(date +%s)
if [[ -n "$ST_LATEST" ]] && (( NOW - ST_LAST_GEN < THROTTLE_INTERVAL )); then
  log "Throttled: last generation $(( NOW - ST_LAST_GEN ))s ago; Stop will catch up"
  exit 0
fi

title_update "$TRANSCRIPT_PATH" "$SESSION_ID" "$HUMANS" "prompt"
