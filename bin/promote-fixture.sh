#!/usr/bin/env bash
# bin/promote-fixture.sh
#
# Promote a logged dialog+title pair from the plugin's debug log into a
# reusable test fixture under tests/fixtures/transcripts/. Requires the
# plugin's debug option to have been on while the bad title was generated
# (otherwise no replay event was logged).
#
# Usage:
#   bin/promote-fixture.sh <slug>           # promote the most recent event
#   bin/promote-fixture.sh <slug> <index>   # 1-based from end (1 = newest)
#   bin/promote-fixture.sh <slug> --grep <substring>
#                                            # promote the most recent event
#                                            # whose dialog or title contains
#                                            # the substring
#
# The debug log is read from $CLAUDE_LIVE_TITLE_DEBUG_LOG, else the newest of
# ~/.claude/plugins/data/live-title*/debug.log (claude-live-title* before
# 2.0), else the pre-1.4 /tmp/claude-live-title-debug.log.
#
# Outputs:
#   tests/fixtures/transcripts/bad-YYYYMMDD-<slug>.jsonl
#   tests/fixtures/transcripts/bad-YYYYMMDD-<slug>.expected.yaml (stub)
#
# After promotion, edit the expected.yaml file to fill in the assertions
# (left empty by default).
set -eu

usage() {
  sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \?//'
  exit 1
}

[[ $# -lt 1 ]] && usage

SLUG="$1"; shift
INDEX=1
GREP=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --grep) GREP="${2-}"; shift 2 ;;
    -h|--help) usage ;;
    *) INDEX="$1"; shift ;;
  esac
done

if [[ ! "$SLUG" =~ ^[a-zA-Z0-9-]+$ ]]; then
  echo "ERROR: slug must be hyphenated alphanumeric (got '$SLUG')" >&2
  exit 1
fi

find_log() {
  if [[ -n "${CLAUDE_LIVE_TITLE_DEBUG_LOG-}" ]]; then
    printf '%s' "$CLAUDE_LIVE_TITLE_DEBUG_LOG"
    return
  fi
  local newest="" f
  for f in "$HOME"/.claude/plugins/data/live-title*/debug.log \
           "$HOME"/.claude/plugins/data/claude-live-title*/debug.log /tmp/claude-live-title-debug.log; do
    [[ -f "$f" ]] || continue
    if [[ -z "$newest" || "$f" -nt "$newest" ]]; then newest="$f"; fi
  done
  printf '%s' "${newest:-$HOME/.claude/plugins/data/live-title/debug.log}"
}
LOG=$(find_log)
if [[ ! -f "$LOG" ]]; then
  echo "ERROR: debug log not found at $LOG" >&2
  echo "       Turn on debug via /live-title:config and reproduce first." >&2
  exit 1
fi

# Find the target event line. Each event is a single JSON line with
# "event":"title-generated".
if [[ -n "$GREP" ]]; then
  EVENT=$(grep -F '"event":"title-generated"' "$LOG" 2>/dev/null \
    | grep -F -- "$GREP" \
    | tail -1)
else
  EVENT=$(grep -F '"event":"title-generated"' "$LOG" 2>/dev/null \
    | tail -"$INDEX" | head -1)
fi

if [[ -z "$EVENT" ]]; then
  echo "ERROR: no matching title-generated event found in $LOG" >&2
  exit 1
fi

# Validate JSON and extract fields
if ! printf '%s' "$EVENT" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: matched line is not valid JSON:" >&2
  echo "       $EVENT" >&2
  exit 1
fi

DIALOG=$(printf '%s' "$EVENT" | jq -r '.dialog')
TITLE=$(printf '%s' "$EVENT" | jq -r '.title')
STYLE_EV=$(printf '%s' "$EVENT" | jq -r '.style // empty')
SID=$(printf '%s' "$EVENT" | jq -r '.session_id // ""')

if [[ -z "$DIALOG" ]]; then
  echo "ERROR: event has empty dialog field" >&2
  exit 1
fi

# Parse the dialog. Current format (1.4+):
#   CURRENT_TITLE / FIRST / EARLIER... / LATEST / CLAUDE
# Older logs: GOAL / USER... / STATE.
CURRENT=$(printf '%s\n' "$DIALOG" | sed -n 's/^CURRENT_TITLE: //p' | head -1)
CLAUDE=$(printf '%s\n' "$DIALOG" | sed -n -e 's/^CLAUDE: //p' -e 's/^STATE: //p' | head -1)
USERS=()
while IFS= read -r u; do
  [[ -n "$u" ]] && USERS+=("$u")
done < <(printf '%s\n' "$DIALOG" | sed -n -E 's/^(FIRST|EARLIER|LATEST|GOAL|USER): //p')

# Resolve repo root and fixture paths
REPO_ROOT=$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel 2>/dev/null \
  || (cd "$(dirname "$0")/.." && pwd))
FIX_DIR="$REPO_ROOT/tests/fixtures/transcripts"
DATE=$(date +%Y%m%d)
TX="$FIX_DIR/bad-$DATE-$SLUG.jsonl"
EXP="$FIX_DIR/bad-$DATE-$SLUG.expected.yaml"

if [[ -e "$TX" || -e "$EXP" ]]; then
  echo "ERROR: fixture already exists for this slug+date:" >&2
  echo "       $TX" >&2
  echo "       $EXP" >&2
  echo "       Pick a different slug or remove the existing files first." >&2
  exit 1
fi

mkdir -p "$FIX_DIR"

# The title shown at the time goes in as a custom-title record before the
# latest message, which is where Claude Code would have had it.
{
  n=${#USERS[@]}
  for (( i = 0; i < n; i++ )); do
    if (( i == n - 1 )) && [[ -n "$CURRENT" ]]; then
      jq -nc --arg t "$CURRENT" '{type:"custom-title", customTitle:$t}'
    fi
    jq -nc --arg c "${USERS[$i]}" '{type:"user", origin:{kind:"human"}, message:{role:"user", content:$c}}'
  done
  if [[ -n "$CLAUDE" ]]; then
    jq -nc --arg t "$CLAUDE" '{type:"assistant", message:{content:[{type:"text", text:$t}]}}'
  fi
} > "$TX"

cat > "$EXP" <<EOF
# Fixture promoted from $LOG on $DATE.
# Original session id: ${SID:-(unknown)}
# Title that was generated (review and decide what assertions matter):
#   observed_title: "$TITLE"
#
# tests/test-fixtures.sh checks must_not_contain against the dialog the
# model sees. With RUN_LIVE=1 it also calls the real model and checks the
# title against all four keys.
must_contain_any: []
must_not_contain: []
title_must_not_contain: []
max_display_columns: 30
EOF
# The naming rules in effect, as a JSON string (newlines escaped).
if [[ -n "$STYLE_EV" ]]; then
  printf 'style: %s\n' "$(jq -n --arg s "$STYLE_EV" '$s')" >> "$EXP"
fi

echo "Wrote: $TX"
echo "Wrote: $EXP"
echo ""
echo "Observed title was: $TITLE"
echo "Now edit $EXP to fill in the assertions."
