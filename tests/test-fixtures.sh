#!/usr/bin/env bash
# test-fixtures.sh — Validate transcript fixtures under
# tests/fixtures/transcripts/. Lint-mode by default (no model calls);
# RUN_LIVE=1 also calls the real `claude -p` to verify title properties.
#
# Lint mode checks (always):
#   - .jsonl parses as JSONL
#   - matching .expected.yaml exists
#   - the hooks' pipeline (human messages + last custom-title as the
#     current title + sanitized Claude reply → build_dialog) produces a
#     non-empty dialog
#   - must_not_contain strings do not appear in the dialog
#
# Live mode adds (when RUN_LIVE=1):
#   - generate_title (real model) + clean_title produce a non-empty title
#   - must_contain_any: at least one needle is in the title
#   - must_not_contain, title_must_not_contain: no needle is in the title
#   - max_display_columns: title width (CJK = 2) stays within it
#   - keep_current_title: true → the title equals the fixture's last
#     custom-title (stability)
#   - expect_skip: true → the model answers SKIP (no task yet); any other
#     fixture fails on SKIP unless allow_skip: true
#   - style: "<JSON string>" → naming rules in effect for this fixture
#
# SAMPLES=N (with RUN_LIVE=1) runs every fixture N times, since the model
# doesn't answer the same way every time.
#
# Config is pinned to the defaults so results don't depend on the local
# config file.
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
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PLUGIN_DATA="$TMP/data"
source "$REPO/hooks/lib/common.sh"
detect_platform

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

read_yaml_scalar() {
  grep "^$2:" "$1" 2>/dev/null | sed "s/^$2:[[:space:]]*//" | head -1 || true
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

SAMPLES="${SAMPLES:-1}"
[[ "$SAMPLES" =~ ^[1-9][0-9]*$ ]] || SAMPLES=1

# live_check <name> <expected.yaml> <current title> <dialog>
# One real model call for a fixture, checked like the hooks would use it.
live_check() {
  local name="$1" exp="$2" current="$3" dialog="$4" label="$1 [live]"
  (( SAMPLES > 1 )) && label="$1 [live $sample/$SAMPLES]"
  local title_raw title
  title_raw=$(generate_title "$dialog" 2>/dev/null || true)
  title=$(clean_title "$title_raw")

  # SKIP means "no task yet"; with a current title the hooks keep that one.
  if [[ -n "$title" ]] && is_skip_reply "$title"; then
    if [[ "$(read_yaml_scalar "$exp" expect_skip)" == "true" ]]; then
      report PASS "$label: skipped, no task yet"
      return 0
    elif [[ -n "$current" ]]; then
      title="$current"
    elif [[ "$(read_yaml_scalar "$exp" allow_skip)" == "true" ]]; then
      report PASS "$label: skipped (allowed)"
      return 0
    else
      report FAIL "$label: model answered SKIP for a session with a task"
      return 0
    fi
  fi
  [[ -n "$title" ]] && title=$(fit_title "$title")
  if [[ -z "$title" ]]; then
    report FAIL "$label: empty title from model"
    return 0
  fi
  echo "    → live title: $title"
  if [[ "$(read_yaml_scalar "$exp" expect_skip)" == "true" ]]; then
    report FAIL "$label: expected SKIP, got '$title'"
    return 0
  fi

  local must_any matched needle
  must_any=$(read_yaml_array "$exp" must_contain_any)
  if [[ "$(printf '%s' "$must_any" | jq -r 'length')" -gt 0 ]]; then
    matched=0
    while IFS= read -r needle; do
      [[ -z "$needle" ]] && continue
      [[ "$title" == *"$needle"* ]] && matched=1
    done < <(printf '%s' "$must_any" | jq -r '.[]?' 2>/dev/null)
    if [[ "$matched" -eq 1 ]]; then
      report PASS "$label: title contains one of must_contain_any"
    else
      report FAIL "$label: title='$title' lacks all of $must_any"
    fi
  fi

  assert_no_needles_in "$name title" "$title" "$(read_yaml_array "$exp" must_not_contain)"
  assert_no_needles_in "$name title" "$title" "$(read_yaml_array "$exp" title_must_not_contain)"

  local max_cols width
  max_cols=$(read_yaml_scalar "$exp" max_display_columns)
  if [[ "$max_cols" =~ ^[0-9]+$ ]]; then
    width=$(display_width "$title")
    if (( width <= max_cols )); then
      report PASS "$label: width $width ≤ $max_cols"
    else
      report FAIL "$label: width $width > $max_cols"
    fi
  fi

  if [[ "$(read_yaml_scalar "$exp" keep_current_title)" == "true" ]]; then
    if [[ "$title" == "$current" ]]; then
      report PASS "$label: current title kept"
    else
      report FAIL "$label: '$current' was reworded to '$title'"
    fi
  fi
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

  CURRENT=$(last_custom_title "$tx")
  HUMANS=$(extract_human_messages "$tx")
  AI=$(sanitize_ai_text "$(extract_last_ai_text "$tx")")
  DIALOG=$(build_dialog "$CURRENT" "$HUMANS" "$AI")

  if [[ -z "$DIALOG" ]]; then
    report FAIL "$name: dialog empty after pipeline"
    continue
  fi
  report PASS "$name: dialog non-empty"

  must_not=$(read_yaml_array "$exp" must_not_contain)
  assert_no_needles_in "$name dialog" "$DIALOG" "$must_not"

  if [[ -n "${RUN_LIVE-}" ]]; then
    STYLE=$(read_yaml_scalar "$exp" style)
    [[ "$STYLE" == \"* ]] && STYLE=$(printf '%s' "$STYLE" | jq -r . 2>/dev/null || true)
    for ((sample = 1; sample <= SAMPLES; sample++)); do
      live_check "$name" "$exp" "$CURRENT" "$DIALOG"
    done
  fi
done

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && echo "All tests passed!" || exit 1
