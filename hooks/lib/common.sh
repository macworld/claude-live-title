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
  local config_dir="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/claude-live-title}"
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

  # Get all real user message lines — use jq to match top-level .type only
  local all_user_lines
  all_user_lines=$(jq -c 'select(.type == "user")' "$transcript" 2>/dev/null || true)
  [[ -z "$all_user_lines" ]] && return 1

  # Sample: first N + last N, deduplicated preserving order
  local first_lines last_lines selected
  first_lines=$(echo "$all_user_lines" | head -"$HEAD_MESSAGES")
  last_lines=$(echo "$all_user_lines" | tail -"$TAIL_MESSAGES")
  selected=$(printf '%s\n%s' "$first_lines" "$last_lines" | awk '!seen[$0]++')

  # Extract text content, filter system noise, truncate
  local msgs
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
    | sed '/^[[:space:]]*$/d' \
    | head -c "$MAX_INPUT_CHARS")

  [[ -z "$msgs" ]] && return 1
  echo "$msgs"
}

# ── Title Generation ──

generate_title() {
  local user_msgs="$1"
  local system_prompt='You are a title generator. Output ONLY the title. No other text.'

  local task_prompt
  if [[ "$LANGUAGE" == "auto" ]]; then
    task_prompt="Generate a concise title within ${MAX_LENGTH} display columns for the following conversation. CJK characters count as 2 columns, Latin characters as 1. Be brief but descriptive. The messages are in chronological order; focus more on the latest messages as they reflect the current direction. Use the same language the user is writing in."
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
    task_prompt="Generate a concise title within ${MAX_LENGTH} display columns for the following conversation. CJK characters count as 2 columns, Latin characters as 1. Be brief but descriptive. The messages are in chronological order; focus more on the latest messages as they reflect the current direction. Write the title in ${lang_name}."
  fi

  log "Generating title: model=$MODEL language=$LANGUAGE"

  local title_raw
  title_raw=$(printf '<task>%s</task>\n<dialog>\n%s\n</dialog>' "$task_prompt" "$user_msgs" \
    | claude -p --model "$MODEL" --system-prompt "$system_prompt" \
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
