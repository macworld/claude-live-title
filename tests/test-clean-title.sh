#!/usr/bin/env bash
# test-clean-title.sh — Verify clean_title prefix/quote/punctuation stripping
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

assert_clean() {
  local desc="$1" input="$2" expected="$3"
  local actual
  actual=$(clean_title "$input")
  if [[ "$actual" == "$expected" ]]; then
    report PASS "$desc"
  else
    report FAIL "$desc — input=[$input] expected=[$expected] got=[$actual]"
  fi
}

echo "=== clean_title prefix stripping ==="

assert_clean "English Title: prefix"     'Title: Fix Login'                'Fix Login'
assert_clean "lowercase title: prefix"   'title: lower case'               'lower case'
assert_clean "Session Title: prefix"     'Session Title: db.py 连接池'      'db.py 连接池'
assert_clean "session title: lowercase"  'session title: foo bar'          'foo bar'
assert_clean "Chinese 标题： prefix"      '标题：修 bug'                     '修 bug'
assert_clean "Chinese 会话标题： prefix"  '会话标题：修登录'                  '修登录'
assert_clean "Japanese タイトル： prefix" 'タイトル：修复'                    '修复'
assert_clean "Korean 제목： prefix"       '제목：수정'                        '수정'

echo ""
echo "=== clean_title quote stripping ==="

assert_clean "ASCII double quotes"       '"my title"'                      'my title'
assert_clean "ASCII single quotes"       "'my title'"                      'my title'
assert_clean "CJK 「 」 brackets"         '「修复 token 校验」'                '修复 token 校验'
assert_clean "CJK 《 》 brackets"         '《重要更新》'                       '重要更新'
assert_clean "leading quote only"        '"unclosed'                       'unclosed'
assert_clean "trailing quote only"       'unopened"'                       'unopened'

echo ""
echo "=== clean_title trailing punctuation ==="

assert_clean "trailing ASCII period"     'Fix login bug.'                  'Fix login bug'
assert_clean "trailing ASCII !"          'Fix it!'                         'Fix it'
assert_clean "trailing ASCII ?"          'is it broken?'                   'is it broken'
assert_clean "trailing CJK 。"            '修登录。'                          '修登录'
assert_clean "trailing CJK ！"            '紧急！'                            '紧急'
assert_clean "trailing CJK ？"            '怎么办？'                          '怎么办'
assert_clean "multiple trailing punct"   '修登录。！'                        '修登录'
assert_clean "trailing comma"            'Fix login,'                      'Fix login'

echo ""
echo "=== clean_title whitespace and combos ==="

assert_clean "leading whitespace"        '   leading spaces'               'leading spaces'
assert_clean "trailing whitespace"       'trailing spaces   '              'trailing spaces'
assert_clean "newlines become spaces"    $'multi\nline\ntitle'             'multi line title'
assert_clean "trailing newline dropped"  $'Fix login\n'                    'Fix login'
assert_clean "Title: + punct + quotes"   '"Title: Fix bug."'               'Fix bug'
assert_clean "标题: + 「」 + 。"          '标题：「修登录」。'                  '修登录'
assert_clean "no transformation needed"  '修复 logout 流程'                  '修复 logout 流程'
assert_clean "tab becomes a space"       $'Fix\tlogin'                     'Fix login'

echo ""
echo "=== clean_title control characters ==="

# The title ends up in the terminal tab; escape sequences must not reach it.
assert_clean "ESC and BEL removed"       $'\e]0;Owned\aFix login'          ']0;OwnedFix login'
assert_clean "ANSI color codes removed"  $'\e[31mFix login\e[0m'           '[31mFix login[0m'
assert_clean "DEL removed"               $'Fix\x7f login'                  'Fix login'
assert_clean "CJK bytes survive"         $'修复\x01登录'                     '修复登录'

echo ""
echo "=== clean_title markdown wrapping ==="

assert_clean "markdown heading"          '# Fix login'                     'Fix login'
assert_clean "markdown h2 + quotes"      '## "Fix login"'                  'Fix login'
assert_clean "bold wrapping"             '**修复登录**'                      '修复登录'
assert_clean "curly quotes"              '“Fix login”'                     'Fix login'
assert_clean "bold + Title: + 。"         '**Title: 修复登录。**'              '修复登录'

echo ""
echo "=== display_width ==="

assert_width() {
  local desc="$1" input="$2" expected="$3" actual
  actual=$(display_width "$input")
  if [[ "$actual" == "$expected" ]]; then
    report PASS "$desc"
  else
    report FAIL "$desc — input=[$input] expected=$expected got=$actual"
  fi
}
assert_width "ASCII"                   'Fix flaky checkout test'   23
assert_width "Chinese = 2 each"        '优化后台总览页布局'          18
assert_width "mixed"                   '修复 logout 流程'           16
assert_width "Japanese kana"           'ログイン修正'                12
assert_width "Hangul + space"          '한국어 제목'                 11
assert_width "fullwidth letters"       'ｆｕｌｌ'                    8
assert_width "accented Latin = 1"      'Café menü'                 9
assert_width "emoji = 2"               '🚀 ship it'                 10
assert_width "empty"                   ''                          0

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && echo "All tests passed!" || exit 1
