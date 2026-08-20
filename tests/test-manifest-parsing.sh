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
PARSER="$SCRIPT_DIR/../script/parse-manifests.py"

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
# 声明 mattpocock/skills 仓库的 npx source（grilling / grill-me），以及 humanizer；
# repo 指向仓库本体，skill 用 basename。空清单用例由下方临时清单单独验证。
assert_ok "skills.toml 解析成功" python3 "$PARSER" skills --file "$REPO_ROOT/configs/skills.toml"
skills_out="$(python3 "$PARSER" skills --file "$REPO_ROOT/configs/skills.toml")"
[[ "$(awk 'NF { count++ } END { print count + 0 }' <<< "$skills_out")" -ge 3 ]] \
    || fail "skills.toml 应至少有 3 行，实际 $(awk 'NF { count++ } END { print count + 0 }' <<< "$skills_out")"
[[ "$skills_out" == *$'grilling\tmattpocock/skills\tgrilling\tclaude-code\tglobal'* ]] \
    || fail "skills.toml 缺少 grilling 条目（repo 应为仓库本体、skill 为 basename）"
[[ "$skills_out" == *$'grill-me\tmattpocock/skills\tgrill-me\tclaude-code\tglobal'* ]] \
    || fail "skills.toml 缺少 grill-me 条目（repo 应为仓库本体、skill 为 basename）"
[[ "$skills_out" == *$'humanizer\tblader/humanizer\thumanizer\tclaude-code\tglobal'* ]] \
    || fail "skills.toml 缺少 humanizer 条目"

# --- 真实 plugins.toml ---
# 验证结构不变量，不硬编码数量：claude-plugin 条目的 marketplace 正确，
# npx method 的手动安装条目存在。
assert_ok "plugins.toml 解析成功" python3 "$PARSER" plugins --file "$REPO_ROOT/configs/plugins.toml"
plugins_out="$(python3 "$PARSER" plugins --file "$REPO_ROOT/configs/plugins.toml")"
[[ -n "$plugins_out" ]] || fail "plugins.toml 不应为空"
[[ "$plugins_out" == *$'superpowers\tobra/superpowers\tclaude-plugin\tsuperpowers-dev'* ]] \
    || fail "plugins superpowers marketplace 应为 superpowers-dev"
[[ "$plugins_out" == *$'CodeGraph\tcolbymchenry/codegraph\tnpx'* ]] \
    || fail "plugins 缺少 CodeGraph (method=npx) 条目"
[[ "$plugins_out" == *$'OpenSpec\tFission-AI/OpenSpec\tnpx'* ]] \
    || fail "plugins 缺少 OpenSpec (method=npx) 条目"

# --- tsv-safe：bash IFS 折叠连续 tab 会把 npx 插件的空 marketplace 列折叠，
#     导致 command 列错位成 note。--tsv-safe 用 <nil> 占位空字段，保证 bash
#     read 后 command 仍指向安装命令。 ---
npx_safe="$(python3 "$PARSER" plugins --tsv-safe --file "$REPO_ROOT/configs/plugins.toml")"
# 用与 setup.sh 相同的 IFS=$'\t' read 列序消费，验证 command 列 = 安装命令
while IFS=$'\t' read -r name repo method marketplace command note; do
    if [[ "$name" == "CodeGraph" ]]; then
        [[ "$command" == "npm i -g @colbymchenry/codegraph" ]] \
            || fail "tsv-safe: CodeGraph command 错位为 [$command]（应为安装命令）"
        [[ "$marketplace" == "<nil>" ]] \
            || fail "tsv-safe: CodeGraph 空 marketplace 应为 <nil>，实际 [$marketplace]"
    elif [[ "$name" == "OpenSpec" ]]; then
        [[ "$command" == "npm i -g @fission-ai/openspec@latest" ]] \
            || fail "tsv-safe: OpenSpec command 错位为 [$command]"
    fi
done <<< "$npx_safe"
echo "PASS: tsv-safe 保留空字段，bash read 后 command 列不折叠错位"

# --- 3.10 回退路径：确认系统解释器无 tomllib 时仍能解析 ---
if python3 -c 'import tomllib' 2>/dev/null; then
    echo "SKIP: 系统 Python 自带 tomllib，无法在当前解释器验证 3.10 回退路径"
else
    assert_ok "3.10 回退路径（无 tomllib）解析成功" python3 "$PARSER" skills --file "$REPO_ROOT/configs/skills.toml"

    # --- 3.10 回退路径：空清单（只有注释，无任何 [[sources]] 表）应解析为 0 行 ---
    # 移除全部双源 source 后 skills.toml 只留注释，解析必须成功（0 行），
    # 不能因"清单中没有 [[sources]] 表"报错——否则 setup.sh 主流程与 TUI 在 3.10 下崩。
    empty_manifest="$(mktemp)"
    cat > "$empty_manifest" <<'TOML'
# 空清单：只有注释，无双源 source
# [[sources]]
# name = "commented-out-example"
TOML
    empty_out="$(python3 "$PARSER" skills --file "$empty_manifest")"
    [[ -z "$empty_out" ]] || fail "空 skills.toml 应解析为 0 行，实际输出: $empty_out"
    echo "PASS: 3.10 回退路径（空清单）解析为 0 行"
    rm -f "$empty_manifest"
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
