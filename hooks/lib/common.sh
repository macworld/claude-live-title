#!/usr/bin/env bash
# common.sh — claude-live-title shared function library
# Sourced by live-title.sh and stop-title.sh

# ── Internal Constants ──
MAX_INPUT_CHARS=8000
DEBUG_LOG="/tmp/claude-live-title-debug.log"

# ── Session ID Sanitization ──
# Derive a filesystem-safe key from session_id via SHA-256 (collision-free)
sanitize_session_id() {
  local raw="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$raw" | sha256sum | cut -d' ' -f1
  else
    printf '%s' "$raw" | shasum -a 256 | cut -d' ' -f1
  fi
}

# ── Config Defaults (overridden by load_config) ──
MODEL="haiku"
LANGUAGE="auto"
MAX_LENGTH=30
HEAD_MESSAGES=3
TAIL_MESSAGES=5
THROTTLE_INTERVAL=240
THROTTLE_MESSAGES=2
LIVE_UPDATE=true
DEBUG=false

# ── Platform Detection ──
IS_MACOS=false

detect_platform() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    IS_MACOS=true
  fi
}

# ── Debug Logging ──
log() {
  if [[ "$DEBUG" == "true" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$$] $*" >> "$DEBUG_LOG"
  fi
}

# ── Config Loading ──
load_config() {
  local config_dir="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claude-live-title}"
  local config_file="$config_dir/config.json"

  # Migrate from legacy path if needed
  local legacy_file="$HOME/.claude/plugins/claude-live-title/config.json"
  if [[ ! -f "$config_file" && -f "$legacy_file" && "$config_file" != "$legacy_file" ]]; then
    mkdir -p "$config_dir"
    cp "$legacy_file" "$config_file"
    log "Migrated config from $legacy_file to $config_file"
  fi

  if [[ -f "$config_file" ]]; then
    local parsed
    parsed=$(jq '.' "$config_file" 2>/dev/null) || { log "Config parse failed, using defaults"; return 0; }

    MODEL=$(echo "$parsed" | jq -r '.model // "haiku"')
    LANGUAGE=$(echo "$parsed" | jq -r '.language // "auto"')
    MAX_LENGTH=$(echo "$parsed" | jq -r '.maxLength // 30')
    HEAD_MESSAGES=$(echo "$parsed" | jq -r '.contextMessages.head // 3')
    TAIL_MESSAGES=$(echo "$parsed" | jq -r '.contextMessages.tail // 5')
    THROTTLE_INTERVAL=$(echo "$parsed" | jq -r '.throttleInterval // 240')
    THROTTLE_MESSAGES=$(echo "$parsed" | jq -r '.throttleMessages // 2')
    LIVE_UPDATE=$(echo "$parsed" | jq -r '.liveUpdate // true')
    DEBUG=$(echo "$parsed" | jq -r '.debug // false')

    # Validate numeric fields — fall back to defaults if not integers
    [[ "$MAX_LENGTH" =~ ^[0-9]+$ ]] || MAX_LENGTH=30
    [[ "$HEAD_MESSAGES" =~ ^[0-9]+$ ]] || HEAD_MESSAGES=3
    [[ "$TAIL_MESSAGES" =~ ^[0-9]+$ ]] || TAIL_MESSAGES=5
    [[ "$THROTTLE_INTERVAL" =~ ^[0-9]+$ ]] || THROTTLE_INTERVAL=240
    [[ "$THROTTLE_MESSAGES" =~ ^[0-9]+$ ]] || THROTTLE_MESSAGES=2

    # Validate boolean fields — fall back to defaults if not true/false
    [[ "$LIVE_UPDATE" == "true" || "$LIVE_UPDATE" == "false" ]] || LIVE_UPDATE=true
    [[ "$DEBUG" == "true" || "$DEBUG" == "false" ]] || DEBUG=false
  fi
  log "Config loaded: model=$MODEL lang=$LANGUAGE maxLen=$MAX_LENGTH ctx=h${HEAD_MESSAGES}+t${TAIL_MESSAGES} throttle=${THROTTLE_INTERVAL}s/${THROTTLE_MESSAGES}msgs live=$LIVE_UPDATE"
}

# ── Cross-Platform File Timestamps ──

get_mtime() {
  local file="$1"
  if [[ "$IS_MACOS" == "true" ]]; then
    stat -f %m "$file" 2>/dev/null || echo 0
  else
    stat -c %Y "$file" 2>/dev/null || echo 0
  fi
}

get_atime() {
  local file="$1"
  if [[ "$IS_MACOS" == "true" ]]; then
    stat -f %a "$file" 2>/dev/null || echo 0
  else
    stat -c %X "$file" 2>/dev/null || echo 0
  fi
}

get_file_times() {
  local file="$1"
  ORIG_ATIME=$(get_atime "$file")
  ORIG_MTIME=$(get_mtime "$file")
  log "Saved timestamps: atime=$ORIG_ATIME mtime=$ORIG_MTIME"
}

restore_file_times() {
  local file="$1"
  if [[ "$IS_MACOS" == "true" ]]; then
    local atime_fmt mtime_fmt
    atime_fmt=$(date -r "$ORIG_ATIME" '+%Y%m%d%H%M.%S' 2>/dev/null) || return 0
    mtime_fmt=$(date -r "$ORIG_MTIME" '+%Y%m%d%H%M.%S' 2>/dev/null) || return 0
    touch -a -t "$atime_fmt" "$file" 2>/dev/null || true
    touch -m -t "$mtime_fmt" "$file" 2>/dev/null || true
  else
    touch -a -d "@${ORIG_ATIME}" "$file" 2>/dev/null || true
    touch -m -d "@${ORIG_MTIME}" "$file" 2>/dev/null || true
  fi
  log "Restored timestamps for $file"
}

# ── Locking (mkdir-based, cross-platform) ──

LOCK_ACQUIRED=false

acquire_lock() {
  local lock_dir="$1"
  if mkdir "$lock_dir" 2>/dev/null; then
    echo "$$" > "$lock_dir/pid"
    LOCK_ACQUIRED=true
    log "Lock acquired: $lock_dir"
    return 0
  fi
  # Stale lock recovery: if lock is older than 60s, it's stale
  # (hook timeout is 30s, so 2x is a safe margin)
  local lock_age
  lock_age=$(( $(date +%s) - $(get_mtime "$lock_dir") ))
  if [[ "$lock_age" -gt 60 ]]; then
    log "Stale lock detected (${lock_age}s old), removing: $lock_dir"
    rm -rf "$lock_dir"
    if mkdir "$lock_dir" 2>/dev/null; then
      echo "$$" > "$lock_dir/pid"
      LOCK_ACQUIRED=true
      log "Lock acquired after stale recovery: $lock_dir"
      return 0
    fi
  fi
  log "Lock busy: $lock_dir"
  return 1
}

release_lock() {
  local lock_dir="$1"
  if [[ "$LOCK_ACQUIRED" == "true" ]]; then
    rm -rf "$lock_dir"
    LOCK_ACQUIRED=false
    log "Lock released: $lock_dir"
  fi
}

# ── Message Extraction ──

extract_user_messages() {
  local transcript="$1"
  # UserPromptSubmit fires before the prompt lands in transcript, so callers
  # pass it in to avoid a one-turn lag (and to have any content at all on the
  # first prompt of a fresh session).
  local current_prompt="${2:-}"
  # Optional: a goal string to exclude from the sample so GOAL: and USER:
  # lines don't duplicate the same content in the dialog.
  local exclude="${3:-}"

  local msgs=""

  local all_user_lines
  all_user_lines=$(jq -c 'select(.type == "user")' "$transcript" 2>/dev/null || true)

  if [[ -n "$all_user_lines" ]]; then
    # Sample: first N + last N, deduplicated preserving order
    local first_lines last_lines selected
    first_lines=$(echo "$all_user_lines" | head -"$HEAD_MESSAGES")
    last_lines=$(echo "$all_user_lines" | tail -"$TAIL_MESSAGES")
    selected=$(printf '%s\n%s' "$first_lines" "$last_lines" | awk '!seen[$0]++')

    msgs=$(echo "$selected" | jq -r '
      if (.message.content | type) == "string" then
        .message.content
      elif (.message.content | type) == "array" then
        [.message.content[] | select(.type == "text") | .text] | join(" ")
      else
        empty
      end
    ' 2>/dev/null \
      | sed '/<system-reminder>/d; /<\/system-reminder>/d' \
      | grep -v '^<command-' | grep -v '^<local-command' \
      | sed '/^[[:space:]]*$/d')
  fi

  if [[ -n "$current_prompt" ]]; then
    if [[ -n "$msgs" ]]; then
      msgs=$(printf '%s\n%s' "$msgs" "$current_prompt")
    else
      msgs="$current_prompt"
    fi
  fi

  if [[ -n "$exclude" ]]; then
    msgs=$(printf '%s' "$msgs" | grep -vxF -- "$exclude" || true)
  fi

  msgs=$(printf '%s' "$msgs" | head -c "$MAX_INPUT_CHARS")
  [[ -z "$msgs" ]] && return 1
  echo "$msgs"
}

# Collapse any whitespace (newlines, tabs, CR, runs of spaces) in stdin to
# single spaces, trim leading/trailing space. Used to flatten multi-line
# message text into one labeled line for the dialog feed (per design call D1).
_flatten_oneline() {
  tr '\n\r\t' '   ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'
}

# Return the first substantive user-message text in the transcript, flattened
# to a single line. Skips user entries whose content is only tool_result (no
# text block). Drops `<system-reminder>...</system-reminder>` blocks (the
# harness embeds these in user content). Returns empty when the transcript
# has no user text at all.
extract_goal_message() {
  local transcript="$1"
  jq -rs '
    [.[] | select(.type == "user")
          | if (.message.content | type) == "string" then
              .message.content
            elif (.message.content | type) == "array" then
              ([.message.content[] | select(.type == "text") | .text] | join(" "))
            else
              empty
            end
          | select(. != null and . != "")]
    | .[0] // empty
  ' "$transcript" 2>/dev/null \
    | sed '/<system-reminder>/,/<\/system-reminder>/d' \
    | grep -Ev '^<(local-)?command-' \
    | _flatten_oneline \
    | head -c "$MAX_INPUT_CHARS"
}

# ── AI Context Extraction ──

# Return the raw text of the last assistant text block in the transcript.
# No paragraph split, no truncation — sanitize_ai_text handles cleanup.
# Empty when no assistant text exists.
extract_last_ai_text() {
  local transcript="$1"
  jq -rs '
    [.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text]
    | .[-1] // empty
  ' "$transcript" 2>/dev/null
}

# Clean an AI text block so it's safe to feed as title-generation context.
# Pipeline (see 2026-04-23-title-balance-design.md):
#   1. Strip fenced code blocks
#   2. Strip inline backticks (keep the content between them)
#   3. Strip pure-output, stack-frame, and stdout/stderr label lines
#   4. Collapse multiple blank lines, trim leading blanks
#   5. Substance check: <30 non-whitespace bytes remaining → return empty
#   6. Cap at 300 characters, append "..." on truncation
#
# Note: step 5 counts bytes (via wc -c on whitespace-stripped input) while
# step 6 caps by bash characters (${var:0:N}). The units intentionally differ:
# the substance floor is "enough bytes to be meaningful" (30 bytes ≈ 10 CJK
# chars ≈ 30 ASCII chars), while the ceiling is "enough characters of reading
# material for Haiku" regardless of encoding.
sanitize_ai_text() {
  local raw="$1"
  [[ -z "$raw" ]] && return 0
  local cleaned
  # Step 1: strip fenced code blocks (whole fence including delimiters)
  cleaned=$(printf '%s' "$raw" | awk '
    /^[[:space:]]*```/ { in_fence = !in_fence; next }
    !in_fence
  ')
  # Step 2: remove inline backticks (keep content)
  cleaned=$(printf '%s' "$cleaned" | sed 's/`//g')
  # Step 3: strip pure-output / stack-frame lines
  cleaned=$(printf '%s' "$cleaned" | sed -E '
    /^[[:space:]]*Traceback/d
    /^[[:space:]]*File "[^"]+", line [0-9]+/d
    /^[[:space:]]*at [A-Za-z_][A-Za-z0-9_.]*[[:space:]]*\([^)]*\)/d
    /^[[:space:]]*\$[[:space:]]+/d
    /^[[:space:]]*>[[:space:]]+/d
    /^[[:space:]]*stderr:/d
    /^[[:space:]]*stdout:/d
  ')
  # Step 4: collapse multiple blank lines to one; trim leading blanks
  cleaned=$(printf '%s\n' "$cleaned" \
    | awk 'NF { blank = 0; print; next } !blank { print; blank = 1 }' \
    | awk '/./ { found = 1 } found')
  # Step 5: substance check (bytes, whitespace excluded)
  local substance
  substance=$(printf '%s' "$cleaned" | tr -d '[:space:]' | wc -c | tr -d ' ')
  if [[ "$substance" -lt 30 ]]; then
    return 0
  fi
  # Step 6: 300-char cap (bash ${var:0:N} slices by chars under UTF-8)
  if [[ ${#cleaned} -gt 300 ]]; then
    cleaned="${cleaned:0:300}..."
  fi
  printf '%s' "$cleaned"
}

# Compose a labeled dialog from GOAL (single line), USER messages (one per
# line, blank lines dropped), and an optional STATE line. When a field is
# empty, its label is omitted — no empty "STATE:" line, etc.
#
# Output shape:
#   GOAL: ...
#   USER: ...
#   USER: ...
#   STATE: ...
format_dialog() {
  local goal="$1" user_msgs="$2" state="$3"
  local parts=()
  if [[ -n "$goal" ]]; then
    local flat_goal
    flat_goal=$(printf '%s' "$goal" | _flatten_oneline)
    [[ -n "$flat_goal" ]] && parts+=("GOAL: $flat_goal")
  fi
  if [[ -n "$user_msgs" ]]; then
    local user_block
    user_block=$(printf '%s' "$user_msgs" | awk 'NF { print "USER: " $0 }')
    [[ -n "$user_block" ]] && parts+=("$user_block")
  fi
  if [[ -n "$state" ]]; then
    local flat_state
    flat_state=$(printf '%s' "$state" | _flatten_oneline)
    [[ -n "$flat_state" ]] && parts+=("STATE: $flat_state")
  fi
  local IFS=$'\n'
  printf '%s' "${parts[*]}"
}

# ── Title Generation ──

generate_title() {
  local user_msgs="$1"
  local system_prompt='You are a title generator. Output ONLY the title. No other text.'

  local lang_instr
  if [[ "$LANGUAGE" == "auto" ]]; then
    lang_instr="Write the title in the main language of the conversation."
  else
    local lang_name
    case "$LANGUAGE" in
      zh) lang_name="Chinese" ;;
      en) lang_name="English" ;;
      ja) lang_name="Japanese" ;;
      ko) lang_name="Korean" ;;
      fr) lang_name="French" ;;
      de) lang_name="German" ;;
      es) lang_name="Spanish" ;;
      *)  lang_name="$LANGUAGE" ;;
    esac
    lang_instr="Write the title in ${lang_name}."
  fi

  local task_prompt="Generate a concrete title for the following Claude Code session.

Budget: target roughly 70% of ${MAX_LENGTH} display columns (CJK=2, Latin=1). Don't exceed. Don't go overly terse.

Labels:
- GOAL: the session's original intent (first user message).
- USER: later user messages in chronological order.
- STATE: the assistant's latest substantive output (already sanitized, supplementary context only).

How to pick the topic:
1. GOAL anchors the session's frame — what the session is fundamentally about.
2. The LAST substantive USER message anchors the current focus — weight it most heavily when it's non-trivial.
3. Earlier USER messages show how the conversation evolved; use them to disambiguate or refine.
4. STATE is topic-source ONLY when the last USER is a short filler reply (ok, 好, continue, 嗯, go, yes, 行, sure, do it). Otherwise STATE is background context — do not derive the topic from it.
5. Prefer SPECIFIC nouns/verbs (file names, function names, concrete actions) over abstract ones.
6. Do NOT merge unrelated topics into a compound phrase.
7. ${lang_instr}"

  log "Generating title: model=$MODEL language=$LANGUAGE"

  local title_raw
  # CLAUDE_LIVE_TITLE_INTERNAL=1 is inherited by the hooks `claude -p` spawns,
  # letting them detect and skip the subsession to avoid recursion + wasted calls.
  title_raw=$(printf '<task>%s</task>\n<dialog>\n%s\n</dialog>' "$task_prompt" "$user_msgs" \
    | CLAUDE_LIVE_TITLE_INTERNAL=1 claude -p --no-session-persistence --model "$MODEL" --system-prompt "$system_prompt" \
        --output-format stream-json --verbose 2>/dev/null \
    | jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' 2>/dev/null \
    | tail -1 || true)

  # Sanity check: multi-line or very long response means model is chatting, not titling
  if [[ $(printf '%s' "$title_raw" | wc -l) -gt 2 ]] || [[ ${#title_raw} -gt 200 ]]; then
    log "Title sanity check failed: lines=$(printf '%s' "$title_raw" | wc -l) len=${#title_raw}"
    return 1
  fi

  [[ -z "$title_raw" ]] && return 1
  echo "$title_raw"
}

# ── Title Post-Processing ──

clean_title() {
  local raw="$1"
  # Strip prefixes, quotes, trailing punctuation.
  # Length is controlled by the AI prompt + generate_title sanity check (200 chars),
  # so no hard truncation here — avoids locale-dependent cut -c issues with CJK.
  printf '%s' "$raw" | tr -d '\n' \
    | sed 's/^[[:space:]]*//' \
    | sed 's/^[Tt]itle[：:][[:space:]]*//' \
    | sed 's/^[Ss]ession [Tt]itle[：:][[:space:]]*//' \
    | sed 's/^标题[：:][[:space:]]*//' \
    | sed 's/^会话标题[：:][[:space:]]*//' \
    | sed 's/^タイトル[：:][[:space:]]*//' \
    | sed 's/^제목[：:][[:space:]]*//' \
    | sed 's/^["'"'"'「《]//; s/["'"'"'」》]$//' \
    | sed 's/[。！？，、；：.!?,;:]$//' \
    | sed 's/[[:space:]]*$//'
}

# ── Write Title to Transcript ──

write_title() {
  local transcript="$1"
  local title="$2"
  local session_id="$3"

  get_file_times "$transcript"

  local record
  record=$(jq -nc --arg title "$title" --arg sid "$session_id" \
    '{type: "custom-title", customTitle: $title, sessionId: $sid}')
  echo "$record" >> "$transcript"

  restore_file_times "$transcript"
  log "Title written: '$title'"
}
