#!/usr/bin/env bash
# Tests for parse-manifests.py — the TOML manifest parser replacing the old
# awk pseudo-parsers in setup.sh.
#
# Covers: real-manifest parsing (both skills + plugins), schema validation
# failures, and the Python 3.10 fallback path (no tomllib) when the system
# interpreter lacks it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARSER="$SCRIPT_DIR/parse-manifests.py"

python3 -m py_compile "$PARSER"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_ok() {
    local desc="$1"
    shift
    local out rc
    out="$("$@" 2>&1)" || { echo "$out" >&2; fail "$desc (exit $?)"; }
    echo "PASS: $desc"
}

assert_fail() {
    local desc="$1"
    shift
    local out rc
    set +e
    out="$("$@" 2>&1)"
    rc=$?
    set -e
    [[ $rc -ne 0 ]] || { echo "$out" >&2; fail "$desc (预期失败却成功)"; }
    echo "PASS: $desc (exit $rc)"
}

# --- 真实 skills.toml ---
assert_ok "skills.toml 解析成功" python3 "$PARSER" skills --file "$REPO_ROOT/configs/skills.toml"
skills_out="$(python3 "$PARSER" skills --file "$REPO_ROOT/configs/skills.toml")"
[[ "$(wc -l <<< "$skills_out")" -eq 4 ]] || fail "skills.toml 应有 4 行，实际 $(wc -l <<< "$skills_out")"
[[ "$skills_out" == *$'context-mode\tmksglu/context-mode\t*\tclaude-code\tglobal'* ]] \
    || fail "skills 首行字段不符: ${skills_out%%$'\n'*}"

# --- 真实 plugins.toml ---
assert_ok "plugins.toml 解析成功" python3 "$PARSER" plugins --file "$REPO_ROOT/configs/plugins.toml"
plugins_out="$(python3 "$PARSER" plugins --file "$REPO_ROOT/configs/plugins.toml")"
[[ "$(wc -l <<< "$plugins_out")" -eq 8 ]] || fail "plugins.toml 应有 8 行，实际 $(wc -l <<< "$plugins_out")"
[[ "$plugins_out" == *$'superpowers\tobra/superpowers\tclaude-plugin\tsuperpowers-dev'* ]] \
    || fail "plugins superpowers marketplace 应为 superpowers-dev"

# --- 3.10 回退路径：确认系统解释器无 tomllib 时仍能解析 ---
if python3 -c 'import tomllib' 2>/dev/null; then
    echo "SKIP: 系统 Python 自带 tomllib，无法在当前解释器验证 3.10 回退路径"
else
    assert_ok "3.10 回退路径（无 tomllib）解析成功" python3 "$PARSER" skills --file "$REPO_ROOT/configs/skills.toml"
fi

# --- 校验失败：缺必填字段 ---
bad_missing="$(mktemp)"
cleanup() { rm -f "$bad_missing"; }
trap cleanup EXIT
cat > "$bad_missing" <<'TOML'
[[sources]]
name = "missing-repo"
TOML
assert_fail "缺 repo 字段应报错" python3 "$PARSER" skills --file "$bad_missing"

# --- 校验失败：未知 method ---
cat > "$bad_missing" <<'TOML'
[[plugins]]
name = "x"
repo = "owner/x"
method = "unknown-method"
TOML
assert_fail "未知 method 应报错" python3 "$PARSER" plugins --file "$bad_missing"

# --- 参数错误：缺 --file ---
assert_fail "缺 --file 应报错" python3 "$PARSER" skills

echo "All manifest parsing tests passed."
