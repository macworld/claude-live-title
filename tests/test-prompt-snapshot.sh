#!/usr/bin/env bash
# test-prompt-snapshot.sh — Guard against unintended drift in the
# title-generation prompt by diffing the dry-run output of generate_title
# against the committed snapshot at tests/snapshots/prompt.txt.
#
# When the prompt is edited on purpose, regenerate the snapshot with:
#   UPDATE_SNAPSHOT=1 bash tests/test-prompt-snapshot.sh
set -eu

PASS=0
FAIL=0
report() {
  local status="$1" desc="$2"
  if [[ "$status" == "PASS" ]]; then
    echo "  ✓ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"
    FAIL=$((FAIL + 1))
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/hooks/lib/common.sh"

# Pin config so the rendering is deterministic.
MAX_LENGTH=30
LANGUAGE=auto

DIALOG=$(cat <<'EOF'
CURRENT_TITLE: Refactor auth module
FIRST: refactor the auth module
EARLIER: split jwt parsing into its own helper
LATEST: also rename verify_signature to verify_jwt_sig
CLAUDE: extracted parse_jwt to lib/auth/jwt.py and updated callers
EOF
)

echo "=== prompt snapshot (LANGUAGE=auto) ==="

ACTUAL=$(CLAUDE_LIVE_TITLE_PRINT_DIALOG=1 generate_title "$DIALOG")
SNAP="$SCRIPT_DIR/tests/snapshots/prompt.txt"
if [[ -n "${UPDATE_SNAPSHOT-}" ]]; then
  printf '%s' "$ACTUAL" > "$SNAP"
  echo "  snapshot written to $SNAP"
fi
EXPECTED=$(cat "$SNAP")

if [[ "$ACTUAL" == "$EXPECTED" ]]; then
  report PASS "auto-language rendering matches snapshot"
else
  echo "    diff (expected ↔ actual):"
  diff -u "$SNAP" <(printf '%s' "$ACTUAL") | sed 's/^/    /' | head -30 || true
  report FAIL "snapshot drift in $SNAP — see diff above; update procedure in this file's header"
fi

echo ""
echo "=== language instruction substitution ==="

LANGUAGE=zh
ACT=$(CLAUDE_LIVE_TITLE_PRINT_DIALOG=1 generate_title "$DIALOG")
[[ "$ACT" == *"Write the title in Chinese."* ]] \
  && report PASS "LANGUAGE=zh → Chinese instruction" \
  || report FAIL "zh instruction missing"

LANGUAGE=ja
ACT=$(CLAUDE_LIVE_TITLE_PRINT_DIALOG=1 generate_title "$DIALOG")
[[ "$ACT" == *"Write the title in Japanese."* ]] \
  && report PASS "LANGUAGE=ja → Japanese instruction" \
  || report FAIL "ja instruction missing"

LANGUAGE=de
ACT=$(CLAUDE_LIVE_TITLE_PRINT_DIALOG=1 generate_title "$DIALOG")
[[ "$ACT" == *"Write the title in German."* ]] \
  && report PASS "LANGUAGE=de → German instruction" \
  || report FAIL "de instruction missing"

LANGUAGE=auto
ACT=$(CLAUDE_LIVE_TITLE_PRINT_DIALOG=1 generate_title "$DIALOG")
[[ "$ACT" == *"Use the language the user writes in"* ]] \
  && report PASS "LANGUAGE=auto → follow the user's language" \
  || report FAIL "auto instruction missing"

MAX_LENGTH=50
ACT=$(CLAUDE_LIVE_TITLE_PRINT_DIALOG=1 generate_title "$DIALOG")
[[ "$ACT" == *"about 35 columns, never more than 50."* ]] \
  && report PASS "maxLength 50 → target 35, hard cap 50" \
  || report FAIL "length line not rendered from maxLength"
MAX_LENGTH=30

echo ""
echo "=== style (custom naming rules) ==="

STYLE=""
ACT=$(CLAUDE_LIVE_TITLE_PRINT_DIALOG=1 generate_title "$DIALOG")
[[ "$ACT" != *"<rules>"* ]] \
  && report PASS "no style → no rules section" \
  || report FAIL "rules section rendered without a style"

STYLE=$'Start with the ticket ID, like PROJ-123.\nThen a short summary.'
ACT=$(CLAUDE_LIVE_TITLE_PRINT_DIALOG=1 generate_title "$DIALOG")
[[ "$ACT" == *$'<rules>\nStart with the ticket ID, like PROJ-123.\nThen a short summary.\n</rules>'* ]] \
  && report PASS "style → rules section with the user's text, lines kept" \
  || report FAIL "rules section missing or altered"
RULES_AT=${ACT%%<rules>*}
LENGTH_AT=${ACT%%Length: aim for*}
(( ${#RULES_AT} < ${#LENGTH_AT} )) \
  && report PASS "rules come before the length limit, which still applies" \
  || report FAIL "rules placed after the length line"
STYLE=""

echo ""
echo "=== dry-run does not invoke claude ==="

# Strip PATH so any actual `claude` invocation would fail; dry-run must
# short-circuit before the model call and still produce the rendered prompt.
ACT=$(PATH="" CLAUDE_LIVE_TITLE_PRINT_DIALOG=1 generate_title "$DIALOG" 2>&1 || true)
if [[ "$ACT" == *"<task>"* && "$ACT" == *"<dialog>"* ]]; then
  report PASS "dry-run short-circuits before claude is reached"
else
  report FAIL "dry-run reached claude or produced no prompt: '$ACT'"
fi

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && echo "All tests passed!" || exit 1
