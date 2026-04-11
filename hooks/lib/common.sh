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
