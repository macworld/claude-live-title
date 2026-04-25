#!/usr/bin/env bash
# test-fixtures.sh — Validate transcript fixtures under
# tests/fixtures/transcripts/. Lint-mode by default (no model calls);
# RUN_LIVE=1 also calls the real `claude -p` to verify title properties.
#
# Lint mode checks (always):
#   - .jsonl parses as JSONL
#   - matching .expected.yaml exists
#   - extract_goal + extract_user + sanitize + format_dialog produces a
#     non-empty dialog
#   - must_not_contain strings do not appear in the dialog
#
# Live mode adds (when RUN_LIVE=1):
#   - generate_title (real model) + clean_title produce a non-empty title
#   - must_contain_any: at least one needle is in the title
#   - must_not_contain: no needle is in the title
set -eu

PASS=0
FAIL=0
report() {
  local s="$1" d="$2"
  if [[ "$s" == "PASS" ]]; then
    echo "  ✓ $d"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $d"
    FAIL=$((FAIL + 1))
  fi
}

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/hooks/lib/common.sh"
detect_platform
load_config

FIX_DIR="$REPO/tests/fixtures/transcripts"

shopt -s nullglob
FIXTURES=("$FIX_DIR"/*.jsonl)
shopt -u nullglob

if [[ ${#FIXTURES[@]} -eq 0 ]]; then
  echo "(no fixtures yet under $FIX_DIR; promote one with bin/promote-fixture.sh)"
  echo "================================"
  echo "Results: 0 passed, 0 failed"
  exit 0
fi

# Read a YAML array value as a JSON string. Returns "[]" if the key is
# absent or the value isn't a JSON-shaped array.
read_yaml_array() {
  local file="$1" key="$2" raw
  raw=$(grep "^${key}:" "$file" 2>/dev/null \
    | sed "s/^${key}:[[:space:]]*//" \
    | head -1 || true)
  if [[ -z "$raw" ]] || ! printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s' '[]'
  else
    printf '%s' "$raw"
  fi
}

assert_no_needles_in() {
  local label="$1" haystack="$2" json_array="$3"
  local needle
  while IFS= read -r needle; do
    [[ -z "$needle" ]] && continue
    if [[ "$haystack" == *"$needle"* ]]; then
      report FAIL "$label contains forbidden '$needle'"
    else
      report PASS "$label lacks '$needle'"
    fi
  done < <(printf '%s' "$json_array" | jq -r '.[]?' 2>/dev/null)
}

for tx in "${FIXTURES[@]}"; do
  name=$(basename "${tx%.jsonl}")
  exp="${tx%.jsonl}.expected.yaml"
  echo ""
  echo "=== $name ==="

  if ! jq -e . "$tx" >/dev/null 2>&1; then
    report FAIL "$name: JSONL parse failed"
    continue
  fi
  if [[ ! -f "$exp" ]]; then
    report FAIL "$name: missing $exp"
    continue
  fi
  report PASS "$name: fixture files present"

  GOAL=$(extract_goal_message "$tx")
  USERS=$(extract_user_messages "$tx" "" "$GOAL" || true)
  AI_RAW=$(extract_last_ai_text "$tx")
  AI=$(sanitize_ai_text "$AI_RAW")
  DIALOG=$(format_dialog "$GOAL" "$USERS" "$AI")

  if [[ -z "$DIALOG" ]]; then
    report FAIL "$name: dialog empty after pipeline"
    continue
  fi
  report PASS "$name: dialog non-empty"

  must_not=$(read_yaml_array "$exp" must_not_contain)
  assert_no_needles_in "$name dialog" "$DIALOG" "$must_not"

  if [[ -n "${RUN_LIVE-}" ]]; then
    TITLE_RAW=$(generate_title "$DIALOG" 2>/dev/null || true)
    TITLE=$(clean_title "$TITLE_RAW")
    if [[ -z "$TITLE" ]]; then
      report FAIL "$name [live]: empty title from model"
      continue
    fi
    echo "    → live title: $TITLE"

    must_any=$(read_yaml_array "$exp" must_contain_any)
    if [[ "$(printf '%s' "$must_any" | jq -r 'length')" -gt 0 ]]; then
      matched=0
      while IFS= read -r needle; do
        [[ -z "$needle" ]] && continue
        [[ "$TITLE" == *"$needle"* ]] && matched=1
      done < <(printf '%s' "$must_any" | jq -r '.[]?' 2>/dev/null)
      if [[ "$matched" -eq 1 ]]; then
        report PASS "$name [live]: title contains one of must_contain_any"
      else
        report FAIL "$name [live]: title='$TITLE' lacks all of $must_any"
      fi
    fi

    assert_no_needles_in "$name title" "$TITLE" "$must_not"
  fi
done

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && echo "All tests passed!" || exit 1
