#!/usr/bin/env bash
# apply-title.sh — UserPromptSubmit hook (sync, no model call)
# Keeps Claude Code's in-memory session title in step with the latest title
# this plugin generated. Once Claude Code holds a title (after compact,
# resume, attach, or an earlier sync) it re-appends that title to the
# transcript after every API request, which reverts ours. Only a synchronous
# UserPromptSubmit hook returning `sessionTitle` can change it, so this
# script does that and nothing else: it reads one small state file and exits
# within milliseconds.
#
# stdout carries only the JSON reply (plain stdout would be added to Claude's
# context), and the script always exits 0 (exit 2 would block the prompt).
set -u

# Skip when invoked by our own `claude -p` subsession.
[[ -n "${CLAUDE_LIVE_TITLE_INTERNAL:-}" ]] && exit 0

exec 3>&1 1>/dev/null 2>/dev/null

main() {
  local input session_id cc_title
  input=$(cat)
  IFS=$'\x1f' read -r session_id cc_title <<< "$(printf '%s' "$input" | jq -r \
    '[(.session_id // ""), (.session_title // "" | gsub("[\\r\\n]"; " "))] | join("\u001f")')"

  # Fast path: Claude Code holds no custom title, so the titles we append to
  # the transcript stand on their own.
  [[ -n "$session_id" && -n "$cc_title" ]] || return 0

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "${script_dir}/lib/common.sh"
  detect_platform
  load_config

  state_init "$(sanitize_session_id "$session_id")"
  is_pinned && return 0
  state_load
  # Unknown sessions are bootstrapped by the async hooks, never here.
  [[ "$ST_EXISTS" == "true" ]] || return 0
  [[ "$cc_title" == "$ST_LATEST" ]] && return 0
  # A title we never generated means the user renamed the session.
  check_foreign_title "$cc_title" || return 0
  [[ -n "$ST_LATEST" ]] || return 0

  log "apply: syncing Claude Code title '$cc_title' → '$ST_LATEST'"
  jq -nc --arg t "$ST_LATEST" \
    '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", sessionTitle: $t}}' >&3
}

main || true
exit 0
