#!/usr/bin/env bash
# apply-title.sh — UserPromptSubmit hook (sync, no model call)
# Keeps Claude Code's in-memory session title in step with the latest title
# this plugin generated. Without it Claude Code shows its own first-message
# title in the terminal tab and the statusline's session_name, and once it
# holds a title (after compact, resume, attach, /clear, or an earlier sync)
# it re-appends that title to the transcript after every API request, which
# reverts ours. Only a synchronous UserPromptSubmit hook returning
# `sessionTitle` can change it, so this script does that and nothing else:
# it reads one small state file and exits within milliseconds.
#
# stdout carries only the JSON reply (plain stdout would be added to Claude's
# context), and the script always exits 0 (exit 2 would block the prompt).
set -u

# Skip when invoked by our own `claude -p` subsession.
[[ -n "${CLAUDE_LIVE_TITLE_INTERNAL:-}" ]] && exit 0

exec 3>&1 1>/dev/null 2>/dev/null

reply_title() {
  jq -nc --arg t "$1" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", sessionTitle: $t}}' >&3
}

main() {
  local input session_id transcript cc_title
  input=$(cat)
  IFS=$'\x1f' read -r session_id transcript cc_title <<< "$(printf '%s' "$input" | jq -r \
    '[(.session_id // ""), (.transcript_path // ""), (.session_title // "" | gsub("[\\r\\n]"; " "))] | join("\u001f")')"

  [[ -n "$session_id" ]] || return 0

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "${script_dir}/lib/common.sh"
  detect_platform
  load_config

  state_init "$(sanitize_session_id "$session_id")"
  is_pinned && return 0
  state_load

  # No title of ours yet while Claude Code shows one: the previous session's,
  # carried over by /clear, or the stand-in for an earlier prompt. Ours is
  # ready by the next prompt at the earliest, so this prompt stands in for
  # this turn. Other unknown sessions are bootstrapped by the async hooks.
  local stand_in=""
  if [[ "$ST_EXISTS" != "true" || -z "$ST_LATEST" ]]; then
    [[ -n "$cc_title" ]] || return 0
    [[ "$ST_EXISTS" == "true" ]] || fresh_from_clear "$transcript" || return 0
    stand_in=$(stand_in_title "$(printf '%s' "$input" | jq -r '.prompt // empty')")
    [[ -n "$stand_in" && "$stand_in" != "$cc_title" ]] || return 0
    # Never wait: a generation holding the lock means a title is on its way.
    acquire_lock "$LOCK_DIR" 0 || return 0
    trap 'release_lock "$LOCK_DIR"' EXIT
    state_bootstrap "$transcript" "$cc_title" 0
    is_pinned && return 0
    state_load
  fi

  [[ "$cc_title" == "$ST_LATEST" ]] && return 0
  # A title we never generated means the user renamed the session. With no
  # custom title, Claude Code is showing its own ai-title; replace that.
  if [[ -n "$cc_title" ]]; then
    check_foreign_title "$cc_title" || return 0
  fi

  if [[ -z "$ST_LATEST" ]]; then
    [[ -n "$stand_in" ]] || return 0
    # Recorded first, so the next prompt and the Stop hook know it as ours.
    state_save "" "$ST_LAST_GEN" "$ST_LAST_HUMAN" "$(jq -nc --arg t "$stand_in" '[$t]')"
    log "apply: standing in for '$cc_title' with '$stand_in'"
    reply_title "$stand_in"
    return 0
  fi

  log "apply: syncing Claude Code title '$cc_title' → '$ST_LATEST'"
  reply_title "$ST_LATEST"
}

main || true
exit 0
