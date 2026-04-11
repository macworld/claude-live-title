#!/usr/bin/env bash
# common.sh — claude-live-title shared function library
# Sourced by live-title.sh and stop-title.sh

# ── Internal Constants ──
MAX_INPUT_CHARS=8000
HEAD_MESSAGES=3
TAIL_MESSAGES=5
DEBUG_LOG="/tmp/claude-live-title-debug.log"

# ── Config Defaults (overridden by load_config) ──
MODEL="haiku"
LANGUAGE="auto"
MAX_LENGTH=20
THROTTLE_INTERVAL=300
THROTTLE_MESSAGES=3
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
  local config_file="$HOME/.claude/plugins/claude-live-title/config.json"
  if [[ -f "$config_file" ]]; then
    MODEL=$(jq -r '.model // "haiku"' "$config_file")
    LANGUAGE=$(jq -r '.language // "auto"' "$config_file")
    MAX_LENGTH=$(jq -r '.maxLength // 20' "$config_file")
    THROTTLE_INTERVAL=$(jq -r '.throttleInterval // 300' "$config_file")
    THROTTLE_MESSAGES=$(jq -r '.throttleMessages // 3' "$config_file")
    LIVE_UPDATE=$(jq -r '.liveUpdate // true' "$config_file")
    DEBUG=$(jq -r '.debug // false' "$config_file")
  fi
  log "Config loaded: model=$MODEL lang=$LANGUAGE maxLen=$MAX_LENGTH throttle=${THROTTLE_INTERVAL}s/${THROTTLE_MESSAGES}msgs live=$LIVE_UPDATE"
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
    echo $$ > "$lock_dir/pid"
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
      echo $$ > "$lock_dir/pid"
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

  # Get all real user message lines (exclude progress records that embed user messages)
  local all_user_lines
  all_user_lines=$(grep '"type":"user"' "$transcript" 2>/dev/null | grep -v '"type":"progress"' || true)
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
