#!/usr/bin/env bash
# Tests for setup.sh `check` action — Claude Code CLI 安装状态检测。
#
# 覆盖:
#   - claude 存在: 版本/路径/安装方式
#   - claude doctor 健康检查 (输出/退出码)
#   - claude auth status 认证状态 (JSON 解析)
#   - 缺失 claude → 明确报错 exit 非零
#   - DRY_RUN 下不实际执行 claude doctor (只提示)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/home" "$fixture/bin"
export HOME="$fixture/home"
export CLAUDE_CONFIG_DIR="$fixture/home/.claude"

# fake claude: 记录 argv，doctor/auth/version 输出可编程
cat > "$fixture/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >> "${EXEC_LOG:?}"
case "$1" in
    --version) echo "2.1.207 (Claude Code)" ;;
    doctor)
        if [[ -n "${DOCTOR_EXIT:-}" ]]; then
            echo "Claude Code doctor"
            echo "No installation issues found."
            exit "$DOCTOR_EXIT"
        fi
        echo "Claude Code doctor"
        echo "No installation issues found."
        exit 0
        ;;
    auth)
        if [[ "$2" == "status" ]]; then
            if [[ -n "${AUTH_EXIT:-}" ]]; then
                echo '{"loggedIn": false, "authMethod": null, "apiProvider": null}'
                exit "$AUTH_EXIT"
            fi
            echo '{"loggedIn": true, "authMethod": "oauth_token", "apiProvider": "firstParty"}'
            exit 0
        fi
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$fixture/bin/claude"
# 只含 fixture/bin，排除系统 PATH，避免泄漏真实 claude（command -v fallback 到系统）
export PATH="$fixture/bin:/usr/bin:/bin"
export EXEC_LOG="$fixture/exec.log"

fail() { echo "FAIL: $*" >&2; exit 1; }

# source setup.sh（复用 ensure_claude_code 等 helper），不触发 main
source "$REPO_ROOT/setup.sh"
REPO_ROOT="$REPO_ROOT"   # 保持真实仓库路径，list 等不需要
DRY_RUN=false; CI_MODE=true; FORCE=false

# ---- 1) claude 存在: check 应检测到并输出版本/路径 ----
: > "$EXEC_LOG"
out="$(run_check_flow 2>&1)" || fail "run_check_flow 应成功，实际 exit $?"
grep -q "Claude Code 已安装" <<<"$out" || fail "check 应报告 claude 已安装: $out"
grep -q "claude --version" "$EXEC_LOG" || fail "check 应执行 claude --version"
echo "PASS: check 检测 claude 存在并报告版本"

# ---- 2) doctor: 应执行 claude doctor 且成功 ----
: > "$EXEC_LOG"
out="$(run_check_flow 2>&1)" || fail "doctor 健康时 check 应成功"
grep -q "claude doctor" "$EXEC_LOG" || fail "check 应执行 claude doctor"
grep -q "无安装问题" <<<"$out" || fail "check 应报告 doctor 通过: $out"
echo "PASS: check 执行 claude doctor 并报告健康"

# ---- 3) doctor 失败: check 应报错并 exit 非零 ----
DOCTOR_EXIT=1; export DOCTOR_EXIT
set +e
out="$(run_check_flow 2>&1)"
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "doctor 失败时 check 应 exit 非零"
unset DOCTOR_EXIT
echo "PASS: doctor 失败 → check exit 非零"

# ---- 4) auth: 应执行 claude auth status --json 并报告认证 ----
: > "$EXEC_LOG"
out="$(run_check_flow 2>&1)" || fail "auth 正常时 check 应成功"
grep -q "claude auth status --json" "$EXEC_LOG" || fail "check 应执行 claude auth status --json: $(cat "$EXEC_LOG")"
grep -qi "已登录\|loggedIn" <<<"$out" || fail "check 应报告已登录: $out"
echo "PASS: check 执行 claude auth status 并报告认证"

# ---- 5) auth 失败: check 应报告但可能不阻断 ----
AUTH_EXIT=1; export AUTH_EXIT
set +e
out="$(run_check_flow 2>&1)"
rc=$?
set -e
unset AUTH_EXIT
grep -qi "未登录\|认证" <<<"$out" || fail "auth 失败应报告认证状态: $out"
echo "PASS: auth 失败时 check 报告认证状态"

# ---- 6) claude 缺失: 明确报错 exit 非零 ----
mv "$fixture/bin/claude" "$fixture/bin/claude.saved"
hash -r  # 清除 bash 对 claude 的命令缓存
set +e
out="$(run_check_flow 2>&1)"
rc=$?
set -e
mv "$fixture/bin/claude.saved" "$fixture/bin/claude"
[[ $rc -ne 0 ]] || fail "claude 缺失时 check 应 exit 非零"
echo "PASS: claude 缺失 → check 明确报错 exit 非零"

echo "ALL Claude-check tests passed."
