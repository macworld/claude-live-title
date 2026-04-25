#!/usr/bin/env bash
# test-sanitize.sh — Verify sanitize_ai_text pipeline
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

# Locale-independent UTF-8 char counter (mirrors _cap_chars's byte-mode logic).
# `wc -m` is locale-aware and reports BYTES under LC_ALL=C, breaking CJK
# assertions when the test runner doesn't have a UTF-8 locale exported.
_test_count_chars() {
  LC_ALL=C awk '
    BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i }
    { buf = (NR > 1 ? buf "\n" : "") $0 }
    END {
      L = length(buf); n = 0
      for (i = 1; i <= L; i++) {
        v = ord[substr(buf, i, 1)]
        if (v < 0x80 || v >= 0xC0) n++
      }
      print n
    }
  '
}

echo "=== sanitize_ai_text ==="

# Case 1: Fenced code block stripped
IN=$'开头\n```python\nx=1\n```\n结尾内容足够长的总结部分这里'
R=$(sanitize_ai_text "$IN")
if [[ "$R" == *"开头"* && "$R" == *"结尾内容足够长的总结部分这里"* && "$R" != *"x=1"* ]]; then
  report PASS "fenced python block stripped"
else
  report FAIL "fenced python: got '$R'"
fi

# Case 2: Language-tagged fence with shell content stripped
IN=$'修了 bug\n```bash\n$ ls\n```\n把路径从 /tmp 改成 /var 了\n补充说明'
R=$(sanitize_ai_text "$IN")
if [[ "$R" == *"修了 bug"* && "$R" == *"把路径从 /tmp 改成 /var 了"* && "$R" != *'$ ls'* ]]; then
  report PASS "language-tagged fence stripped"
else
  report FAIL "language-tagged fence: got '$R'"
fi

# Case 3: Inline backticks removed, content kept
IN="改了 \`login.py\` 里的 token 校验顺序和过期判断"
R=$(sanitize_ai_text "$IN")
if [[ "$R" == *"login.py"* && "$R" != *'`'* ]]; then
  report PASS "inline backticks removed, content kept"
else
  report FAIL "inline backticks: got '$R'"
fi

# Case 4: Python stack frame lines stripped
IN=$'出错了我看看：\nTraceback (most recent call last):\n  File "x.py", line 5, in foo\nKeyError: \'db\'\n已经修复配置加载问题'
R=$(sanitize_ai_text "$IN")
if [[ "$R" == *"出错了我看看"* && "$R" == *"已经修复配置加载问题"* && "$R" != *"Traceback"* && "$R" != *'File "x.py"'* ]]; then
  report PASS "python stack frame stripped"
else
  report FAIL "python stack: got '$R'"
fi

# Case 5: Shell prompt line stripped
IN=$'运行了测试验证一下\n$ npm test\n结果 5 个 pass 0 个 fail'
R=$(sanitize_ai_text "$IN")
if [[ "$R" == *"运行了测试验证一下"* && "$R" == *"5 个 pass 0 个 fail"* && "$R" != *'$ npm test'* ]]; then
  report PASS "shell prompt line stripped"
else
  report FAIL "shell prompt: got '$R'"
fi

# Case 6: Preamble + fence + summary with blank lines — both prose paragraphs survive
IN=$'好，我看一下问题在哪。\n\n```python\ndef foo(): pass\n```\n\n问题在 foo() 里调用了未初始化的 config，挪到模块加载时了'
R=$(sanitize_ai_text "$IN")
if [[ "$R" == *"好，我看一下问题在哪"* && "$R" == *"问题在 foo() 里调用了未初始化的 config，挪到模块加载时了"* && "$R" != *"def foo"* ]]; then
  report PASS "preamble + fence + summary preserved without code"
else
  report FAIL "preamble+fence+summary: got '$R'"
fi

# Case 7: Substance < 30 bytes → empty (STATE dropped)
IN="好"
R=$(sanitize_ai_text "$IN")
[[ -z "$R" ]] && report PASS "substance<30 → empty" || report FAIL "substance<30: got '$R'"

# Case 8: Only a fenced block → empty after strip
IN=$'```\nsome code\n```'
R=$(sanitize_ai_text "$IN")
[[ -z "$R" ]] && report PASS "only code fence → empty" || report FAIL "only-fence: got '$R'"

# Case 9: Input > 300 bytes after sanitize → truncated with ...
IN=$(python3 -c "print('x' * 400)")
R=$(sanitize_ai_text "$IN")
if [[ ${#R} -eq 303 && "${R: -3}" == "..." ]]; then
  report PASS "long sanitized text truncated to 300+..."
else
  report FAIL "long-sanitize: got length ${#R}, tail '${R: -3}'"
fi

# Case 10: Indented fence (GFM allows up to 3 leading spaces; lists often nest fences this way)
IN=$'列表里的代码块：\n  ```python\n  x = 1\n  ```\n代码外的修复说明写得足够长触发实质检查'
R=$(sanitize_ai_text "$IN")
if [[ "$R" == *"列表里的代码块"* && "$R" == *"代码外的修复说明写得足够长触发实质检查"* && "$R" != *"x = 1"* ]]; then
  report PASS "indented fence stripped"
else
  report FAIL "indented fence: got '$R'"
fi

# Case 11: 300-char cap with CJK input (validates char-based, not byte-based, slicing)
IN=$(python3 -c "print('中文' * 200)")  # 400 CJK chars = 1200 bytes
R=$(sanitize_ai_text "$IN")
CHAR_LEN=$(printf '%s' "$R" | _test_count_chars)
if [[ "$CHAR_LEN" -eq 303 && "${R: -3}" == "..." ]]; then
  report PASS "CJK input capped to 300 chars + ..."
else
  report FAIL "CJK cap: got ${CHAR_LEN} chars, tail '${R: -3}'"
fi

# Case 12: CRLF line endings (Windows-origin transcripts) — fence stripped,
# no \r leaks to downstream consumers
IN=$'preamble line\r\n```bash\r\n$ ls\r\nfile1\r\n```\r\nclosing summary long enough to pass the substance gate threshold\r\n'
R=$(sanitize_ai_text "$IN")
if [[ "$R" == *"preamble line"* && "$R" == *"closing summary"* \
   && "$R" != *'$ ls'* && "$R" != *'```'* && "$R" != *$'\r'* ]]; then
  report PASS "CRLF fence stripped, no carriage returns leak"
else
  report FAIL "CRLF fence: got '$R'"
fi

echo ""
echo "=== sanitize-line-rules.tsv (data-driven catalog) ==="

RULES="$SCRIPT_DIR/hooks/lib/sanitize-line-rules.tsv"
if [[ ! -r "$RULES" ]]; then
  report FAIL "TSV catalog not readable at $RULES"
else
  while IFS=$'\t' read -r id pattern matches no_match; do
    case "${id-}" in '' | '#'*) continue ;; esac
    [[ -z "$pattern" ]] && continue
    R=$(printf '%s\n' "$matches" | sed -E "/${pattern}/d")
    if [[ -z "$R" ]]; then
      report PASS "[$id] match-example dropped"
    else
      report FAIL "[$id] match-example kept: '$R'"
    fi
    R=$(printf '%s\n' "$no_match" | sed -E "/${pattern}/d")
    if [[ "$R" == "$no_match" ]]; then
      report PASS "[$id] non-match preserved"
    else
      report FAIL "[$id] non-match dropped"
    fi
  done < "$RULES"
fi

echo ""
echo "=== sanitize_ai_text integration with new noise shapes ==="

# Rust panic line stripped, prose surrounding survives the substance gate
IN=$(cat <<'EOF'
修了 Cargo 项目的入口模块
thread 'main' panicked at src/main.rs:42:5
note: run with RUST_BACKTRACE=1
看了下是 unwrap 用错了已经修复
EOF
)
R=$(sanitize_ai_text "$IN")
if [[ "$R" == *"修了 Cargo"* && "$R" == *"unwrap 用错了"* && "$R" != *"panicked at"* ]]; then
  report PASS "Rust panic stripped, summary survives"
else
  report FAIL "Rust integration: '$R'"
fi

# Go panic stripped, surrounding prose survives
IN=$(cat <<'EOF'
帮我看了下服务为什么挂
panic: runtime error: invalid memory address
goroutine 1 [running]:
问题是空指针解引用，已加了 nil 检查保护
EOF
)
R=$(sanitize_ai_text "$IN")
if [[ "$R" == *"帮我看了下服务"* && "$R" == *"已加了 nil 检查保护"* && "$R" != *"panic: runtime"* ]]; then
  report PASS "Go panic stripped, summary survives"
else
  report FAIL "Go integration: '$R'"
fi

# Ruby backtrace lines stripped
IN=$(cat <<'EOF'
调试 Rails 控制器的渲染问题
from app/controllers/users.rb:42:in 'show'
from config/routes.rb:10:in 'block in routes'
是 strong params 漏了 :avatar 字段
EOF
)
R=$(sanitize_ai_text "$IN")
if [[ "$R" == *"调试 Rails 控制器"* && "$R" == *"strong params 漏了"* && "$R" != *"app/controllers"* ]]; then
  report PASS "Ruby backtrace stripped, summary survives"
else
  report FAIL "Ruby integration: '$R'"
fi

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && echo "All tests passed!" || exit 1
