#!/usr/bin/env bash
# bin/promote-fixture.sh
#
# Promote a logged dialog+title pair from /tmp/claude-live-title-debug.log
# into a reusable test fixture under tests/fixtures/transcripts/. Requires
# the plugin's DEBUG=true to have been on while the bad title was generated
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
# Outputs:
#   tests/fixtures/transcripts/bad-YYYYMMDD-<slug>.jsonl
#   tests/fixtures/transcripts/bad-YYYYMMDD-<slug>.expected.yaml (stub)
#
# After promotion, edit the expected.yaml file to fill in must_contain_any
# and must_not_contain assertions (left empty by default).
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

LOG="${CLAUDE_LIVE_TITLE_DEBUG_LOG:-/tmp/claude-live-title-debug.log}"
if [[ ! -f "$LOG" ]]; then
  echo "ERROR: debug log not found at $LOG" >&2
  echo "       Set DEBUG=true via /claude-live-title:config and reproduce first." >&2
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
SID=$(printf '%s' "$EVENT" | jq -r '.session_id // ""')

if [[ -z "$DIALOG" ]]; then
  echo "ERROR: event has empty dialog field" >&2
  exit 1
fi

# Parse dialog: GOAL: line, USER: lines, STATE: line
GOAL=$(printf '%s\n' "$DIALOG" | sed -n 's/^GOAL: //p' | head -1)
STATE=$(printf '%s\n' "$DIALOG" | sed -n 's/^STATE: //p' | head -1)
USERS=()
while IFS= read -r u; do
  [[ -n "$u" ]] && USERS+=("$u")
done < <(printf '%s\n' "$DIALOG" | sed -n 's/^USER: //p')

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

{
  if [[ -n "$GOAL" ]]; then
    jq -nc --arg c "$GOAL" '{type:"user", message:{content:$c}}'
  fi
  for u in "${USERS[@]}"; do
    jq -nc --arg c "$u" '{type:"user", message:{content:$c}}'
  done
  if [[ -n "$STATE" ]]; then
    jq -nc --arg t "$STATE" '{type:"assistant", message:{content:[{type:"text", text:$t}]}}'
  fi
} > "$TX"

cat > "$EXP" <<EOF
# Fixture promoted from /tmp/claude-live-title-debug.log on $DATE.
# Original session id: ${SID:-(unknown)}
# Title that was generated (review and decide what assertions matter):
#   observed_title: "$TITLE"
#
# Edit must_contain_any and must_not_contain below. Test harness in
# tests/test-fixtures.sh enforces these against the dialog Haiku sees by
# default; with RUN_LIVE=1 it also runs the real model and asserts on the
# title.
must_contain_any: []
must_not_contain: []
max_display_columns: 30
EOF

echo "Wrote: $TX"
echo "Wrote: $EXP"
echo ""
echo "Observed title was: $TITLE"
echo "Now edit $EXP to fill in must_contain_any / must_not_contain."
