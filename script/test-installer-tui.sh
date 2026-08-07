#!/usr/bin/env bash
# Tests for tools/installer-tui — the C++17 + FTXUI interactive installer.
#
# Covers:
#   - --help works without TTY
#   - no-TTY stdin exits 2 without blocking
#   - --print-selection prints machine-readable record
#   - real manifest parses to 4 skills / 8 plugins
#   - fixture/mock setup.sh: verify argv protocol (install/update/uninstall,
#     typed flags, skip-* categories, --ci) and exit-code propagation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$REPO_ROOT/build/installer-tui/installer-tui"

[[ -x "$BIN" ]] || { echo "FAIL: $BIN 未构建，先 cmake 构建" >&2; exit 1; }

show_diagnostics() {
    for file in "${TUI_STDOUT:-}" "${TUI_STDERR:-}" "${MOCK_LOGFILE:-}"; do
        [[ -n "$file" && -f "$file" ]] || continue
        printf '%s\n' "--- $file ---" >&2
        cat "$file" >&2
    done
}
fail() {
    echo "FAIL: $*" >&2
    show_diagnostics
    exit 1
}
pass() { echo "PASS: $*"; }

# ---- 1) --help 无 TTY 可工作 ----
help_out="$("$BIN" --help </dev/null 2>&1)"
[[ "$help_out" == *"Claude Config Installer TUI"* ]] || fail "--help 输出不完整"
pass "--help 无 TTY 可工作"

# ---- 2) 无 TTY stdin 退出 2 不阻塞 ----
set +e
timeout 5 "$BIN" --repo-root "$REPO_ROOT" </dev/null >/tmp/tui-nottty.out 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || fail "无 TTY 应退出 2，实际 $rc"
grep -q "需要交互终端" /tmp/tui-nottty.out || fail "无 TTY 提示缺失"
pass "无 TTY stdin 退出 2 且不阻塞"

# ---- 3) --print-selection 纯打印模式 ----
sel="$("$BIN" --repo-root "$REPO_ROOT" --print-selection </dev/null 2>/dev/null)"
[[ "$sel" == "install	all" ]] || fail "--print-selection 应输出 'install<tab>all'，实际: $sel"
pass "--print-selection 输出机器可读记录"

# ---- 3b) 未知参数与 --repo-root 缺值必须失败 ----
set +e
timeout 5 "$BIN" --definitely-unknown </dev/null >/tmp/tui-unknown.out 2>&1
rc=$?
timeout 5 "$BIN" --repo-root </dev/null >/tmp/tui-missing-root.out 2>&1
missing_root_rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "未知参数应失败"
[[ "$missing_root_rc" -ne 0 ]] || fail "--repo-root 缺值应失败"
pass "未知参数与 --repo-root 缺值失败"

# ---- 4) 真实清单解析：4 skills / 8 plugins（走 parser + LoadManifests）----
skills_count="$(python3 "$REPO_ROOT/script/parse-manifests.py" skills --file "$REPO_ROOT/configs/skills.toml" | awk 'NF { count++ } END { print count + 0 }')"
plugins_count="$(python3 "$REPO_ROOT/script/parse-manifests.py" plugins --file "$REPO_ROOT/configs/plugins.toml" | awk 'NF { count++ } END { print count + 0 }')"
[[ "$skills_count" -eq 4 ]] || fail "skills parser 应输出 4 行，实际 $skills_count"
[[ "$plugins_count" -eq 8 ]] || fail "plugins parser 应输出 8 行，实际 $plugins_count"
set +e
timeout 5 "$BIN" --repo-root "$REPO_ROOT" --print-selection >/dev/null 2>/tmp/tui-manifest.err
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { cat /tmp/tui-manifest.err >&2; fail "真实清单解析失败 (exit $rc)"; }
pass "真实清单解析成功 (skills=4, plugins=8)"

# ---- 5) setup.sh --tui fast-path：任意 argv 位置均转发并移除 --tui ----
for tui_args in \
    "--tui --print-selection" \
    "--ci --tui --print-selection"; do
    # shellcheck disable=SC2086
    tui_selection="$(timeout 5 "$REPO_ROOT/setup.sh" $tui_args </dev/null 2>/dev/null)" ||
        fail "setup.sh fast-path 失败: $tui_args"
    [[ "$tui_selection" == $'install\tall' ]] ||
        fail "setup.sh fast-path 输出错误 ($tui_args): $tui_selection"
done
pass "setup.sh --tui 与 --ci --tui fast-path"

# ---- 6) fixture/mock setup.sh：argv 协议 ----
fixture="$(mktemp -d)"
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT

# fixture 仓库：真实 configs/ + script/parse-manifests.py + mock setup.sh
mkdir -p "$fixture/repo/configs" "$fixture/repo/script"
cp "$REPO_ROOT/configs/skills.toml" "$fixture/repo/configs/"
cp "$REPO_ROOT/configs/plugins.toml" "$fixture/repo/configs/"
cp "$REPO_ROOT/script/parse-manifests.py" "$fixture/repo/script/"

# mock setup.sh：记录 argv 到 setup-argv.log，退出码可配置
cat >"$fixture/repo/setup.sh" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0")|$*" >> "$MOCK_LOGFILE"
[[ -n "${MOCK_EXIT:-}" ]] && exit "$MOCK_EXIT"
exit 0
EOF
chmod +x "$fixture/repo/setup.sh"
export MOCK_LOGFILE="$fixture/setup-argv.log"
export MOCK_EXIT=0

# 辅助：清空日志、运行、返回 argv
run_bin() {
    : > "$MOCK_LOGFILE"
    local rc
    set +e
    timeout 5 "$BIN" --repo-root "$fixture/repo" "$@" </dev/null >/dev/null 2>&1
    rc=$?
    set -e
    return "$rc"
}
argv_line() { cat "$MOCK_LOGFILE"; }

# 5a) install 全量：--print-selection 不 exec setup（先验证不调 mock）
run_bin --print-selection
[[ ! -s "$MOCK_LOGFILE" ]] || fail "--print-selection 不应触发 setup.sh"
pass "--print-selection 不触发 setup.sh"

# 5b) 校验 mock 仓库能解析（同名 skill/plugin fixture 走真实清单；此处用 mock 的 manifest）
: > "$MOCK_LOGFILE"
timeout 5 "$BIN" --repo-root "$fixture/repo" --print-selection >/dev/null 2>&1 || fail "fixture 清单解析失败"
pass "fixture 清单可解析"

# ---- 6) GNU screen 真实交互：勾选首个 skill → modal 确认 → setup argv ----
command -v screen >/dev/null 2>&1 || fail "需要 GNU screen"
TUI_STDOUT="$fixture/tui-stdout.log"
TUI_STDERR="$fixture/tui-stderr.log"
session="installer-tui-test-success-$$-$RANDOM"
session_created=0
failure_session="installer-tui-test-exit7-$$-$RANDOM"
failure_session_created=0
SUCCESS_EXIT="$fixture/success-exit.log"
FAILURE_STDOUT="$fixture/failure-stdout.log"
FAILURE_STDERR="$fixture/failure-stderr.log"
FAILURE_EXIT="$fixture/failure-exit.log"
hang_session="installer-tui-test-cancel-$$-$RANDOM"
hang_session_created=0
HANG_STDOUT="$fixture/hang-stdout.log"
HANG_STDERR="$fixture/hang-stderr.log"
HANG_EXIT="$fixture/hang-exit.log"
HANG_PIDFILE="$fixture/hang.pid"
cleanup() {
    if [[ "$session_created" -eq 1 ]]; then
        screen -S "$session" -X quit >/dev/null 2>&1 || true
    fi
    if [[ "$failure_session_created" -eq 1 ]]; then
        screen -S "$failure_session" -X quit >/dev/null 2>&1 || true
    fi
    if [[ "$hang_session_created" -eq 1 ]]; then
        screen -S "$hang_session" -X quit >/dev/null 2>&1 || true
    fi
    rm -rf "$fixture"
}
trap cleanup EXIT

: > "$MOCK_LOGFILE"
# screen 为唯一的隔离会话；仅 cleanup 自己创建的 session。
screen -dmS "$session" bash -c '"$1" --repo-root "$2" >"$3" 2>"$4"; rc=$?; printf "%s\\n" "$rc" >"$5"; exit "$rc"' _ \
    "$BIN" "$fixture/repo" "$TUI_STDOUT" "$TUI_STDERR" "$SUCCESS_EXIT" || fail "screen 启动失败"
session_created=1
sleep 1
screen -S "$session" -X stuff ' ' || fail "无法发送空格"
screen -S "$session" -X stuff 'e' || fail "无法发送 e"
screen -S "$session" -X stuff $'\r' || fail "无法发送回车"

for _ in {1..100}; do
    [[ -s "$MOCK_LOGFILE" ]] && break
    sleep 0.1
done
[[ -s "$MOCK_LOGFILE" ]] || fail "等待 mock setup.sh argv 超时"
grep -q '^setup.sh|install --ci --skill context-mode --skip-plugins$' "$MOCK_LOGFILE" ||
    fail "argv 未按预期: $(argv_line)"
grep -q $'^install\tskill:context-mode$' "$TUI_STDOUT" ||
    fail "stdout 机器可读记录缺失"
screen -S "$session" -X stuff 'q' || fail "无法发送 q"
for _ in {1..100}; do
    [[ -s "$SUCCESS_EXIT" ]] && break
    sleep 0.1
done
[[ "$(<"$SUCCESS_EXIT")" == "0" ]] || fail "成功 screen TUI 应退出 0，实际 $(<"$SUCCESS_EXIT" 2>/dev/null || true)"
for _ in {1..100}; do
    screen -ls 2>/dev/null | grep -q "\\.${session}[[:space:]]" || break
    sleep 0.1
done
screen -ls 2>/dev/null | grep -q "\\.${session}[[:space:]]" && fail "成功 TUI shell 进程未结束"
screen -S "$session" -X quit >/dev/null 2>&1 || true
session_created=0
pass "GNU screen 真实交互与 argv/机器可读记录"

# ---- 7) q 取消长运行 setup：screen wrapper 与本次 mock 均应结束 ----
cat >"$fixture/repo/setup.sh" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0")|$*" >> "$MOCK_LOGFILE"
echo "$BASHPID" > "$MOCK_PIDFILE"
while :; do sleep 1; done
EOF
chmod +x "$fixture/repo/setup.sh"
export MOCK_PIDFILE="$HANG_PIDFILE"
export MOCK_EXIT=0
: > "$MOCK_LOGFILE"
screen -dmS "$hang_session" bash -c '"$1" --repo-root "$2" >"$3" 2>"$4"; rc=$?; printf "%s\\n" "$rc" >"$5"; exit "$rc"' _ \
    "$BIN" "$fixture/repo" "$HANG_STDOUT" "$HANG_STDERR" "$HANG_EXIT" || fail "cancel screen 启动失败"
hang_session_created=1
sleep 1
screen -S "$hang_session" -X stuff ' ' || fail "cancel 无法发送空格"
screen -S "$hang_session" -X stuff 'e' || fail "cancel 无法发送 e"
screen -S "$hang_session" -X stuff $'\r' || fail "cancel 无法发送回车"
for _ in {1..100}; do
    [[ -s "$HANG_PIDFILE" ]] && break
    sleep 0.1
done
[[ -s "$HANG_PIDFILE" ]] || fail "等待长运行 mock setup 超时"
hang_pid="$(<"$HANG_PIDFILE")"
screen -S "$hang_session" -X stuff 'q' || fail "cancel 无法发送 q"
for _ in {1..50}; do
    screen -ls 2>/dev/null | grep -q "\\.${hang_session}[[:space:]]" || break
    sleep 0.1
done
screen -ls 2>/dev/null | grep -q "\\.${hang_session}[[:space:]]" && fail "q 后 screen wrapper 未在有限时间退出"
if kill -0 "$hang_pid" 2>/dev/null; then
    fail "q 后长运行 mock 仍存活 (pid=$hang_pid)"
fi
hang_session_created=0
pass "GNU screen q 取消长运行 setup 并清理子进程"

# ---- 8) GNU screen 真实交互：setup.sh 退出码 7 透传到 RunUi/main ----
cat >"$fixture/repo/setup.sh" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0")|$*" >> "$MOCK_LOGFILE"
[[ -n "${MOCK_EXIT:-}" ]] && exit "$MOCK_EXIT"
exit 0
EOF
chmod +x "$fixture/repo/setup.sh"
export MOCK_EXIT=7
: > "$MOCK_LOGFILE"
screen -dmS "$failure_session" bash -c '"$1" --repo-root "$2" >"$3" 2>"$4"; rc=$?; printf "%s\\n" "$rc" >"$5"; exit "$rc"' _ \
    "$BIN" "$fixture/repo" "$FAILURE_STDOUT" "$FAILURE_STDERR" "$FAILURE_EXIT" || fail "exit=7 screen 启动失败"
failure_session_created=1
sleep 1
screen -S "$failure_session" -X stuff ' ' || fail "exit=7 无法发送空格"
screen -S "$failure_session" -X stuff 'e' || fail "exit=7 无法发送 e"
screen -S "$failure_session" -X stuff $'\r' || fail "exit=7 无法发送回车"
for _ in {1..100}; do
    [[ -s "$MOCK_LOGFILE" ]] && break
    sleep 0.1
done
[[ -s "$MOCK_LOGFILE" ]] || fail "等待 exit=7 mock setup.sh 超时"
screen -S "$failure_session" -X stuff 'q' || fail "exit=7 无法发送 q"
for _ in {1..100}; do
    [[ -s "$FAILURE_EXIT" ]] && break
    sleep 0.1
done
[[ "$(<"$FAILURE_EXIT")" == "7" ]] || fail "setup.sh 退出码应透传 7，实际 $(<"$FAILURE_EXIT" 2>/dev/null || true)"
for _ in {1..100}; do
    screen -ls 2>/dev/null | grep -q "\\.${failure_session}[[:space:]]" || break
    sleep 0.1
done
screen -ls 2>/dev/null | grep -q "\\.${failure_session}[[:space:]]" && fail "exit=7 TUI shell 进程未结束"
grep -q '^setup.sh|install --ci --skill context-mode --skip-plugins$' "$MOCK_LOGFILE" ||
    fail "exit=7 argv 未按预期: $(argv_line)"
screen -S "$failure_session" -X quit >/dev/null 2>&1 || true
failure_session_created=0
pass "GNU screen 真实 TUI 透传 setup.sh 退出码 7 与 argv"

echo "ALL TESTS PASSED"


