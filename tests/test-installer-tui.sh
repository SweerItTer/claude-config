#!/usr/bin/env bash
# Tests for tools/installer-tui — the C++17 + FTXUI interactive installer.
#
# Covers:
#   - --help works without TTY
#   - no-TTY stdin exits 2 without blocking
#   - --print-selection prints machine-readable record
#   - real manifest parses to 3 skills / 8 plugins
#   - fixture/mock setup.sh: verify argv protocol (install/update/uninstall,
#     typed flags, skip-* categories, --ci) and exit-code propagation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# tests/ 位于仓库根下，上移一级即仓库根
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

# ---- 3) --print-selection 纯打印模式：输出统一资源计划 TSV（CLI/TUI 共享同一资源语义）----
sel="$(timeout 5 "$BIN" --repo-root "$REPO_ROOT" --print-selection </dev/null 2>/dev/null)" ||
    fail "--print-selection 失败"
python3 -c 'import sys
rows=[l.split("\t") for l in sys.stdin.read().splitlines() if l]
assert rows, "空计划"
assert all(len(r)>=9 for r in rows), "列数不足 9"
assert any(r[0]=="skill" and r[2]=="local" for r in rows), "缺少本地 skill 资源"
print("PASS: --print-selection 输出统一资源计划 TSV")' <<<"$sel" ||
    fail "--print-selection 应输出统一资源计划 TSV: $sel"
pass "--print-selection 输出统一资源计划 TSV"

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

# ---- 4) 真实清单解析：外部 skills + plugins（走 parser + LoadManifests）----
# 断言结构不变量而非硬编码数量：skills.toml 至少含 grilling/grill-me，
# plugins.toml 至少含 claude-plugin 与 npx 两类；TUI 应能完整解析真实清单。
skills_out="$(python3 "$REPO_ROOT/script/parse-manifests.py" skills --file "$REPO_ROOT/configs/skills.toml")"
plugins_out="$(python3 "$REPO_ROOT/script/parse-manifests.py" plugins --file "$REPO_ROOT/configs/plugins.toml")"
[[ "$(awk 'NF { count++ } END { print count + 0 }' <<< "$skills_out")" -ge 2 ]] \
    || fail "skills parser 应至少输出 2 行（grilling/grill-me），实际: $skills_out"
[[ "$(awk 'NF { count++ } END { print count + 0 }' <<< "$plugins_out")" -ge 10 ]] \
    || fail "plugins parser 应至少输出 10 行"
[[ "$plugins_out" == *$'CodeGraph\t'* && "$plugins_out" == *$'OpenSpec\t'* ]] \
    || fail "plugins parser 应含 CodeGraph/OpenSpec (method=npx)"
set +e
timeout 5 "$BIN" --repo-root "$REPO_ROOT" --print-selection >/dev/null 2>/tmp/tui-manifest.err
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { cat /tmp/tui-manifest.err >&2; fail "真实清单解析失败 (exit $rc)"; }
pass "真实清单解析成功（结构不变量：≥2 skills, ≥10 plugins）"

# ---- 5) setup.sh --tui fast-path：任意 argv 位置均转发并移除 --tui ----
for tui_args in \
    "--tui --print-selection" \
    "--ci --tui --print-selection"; do
    # shellcheck disable=SC2086
    tui_selection="$(timeout 5 "$REPO_ROOT/setup.sh" $tui_args </dev/null 2>/dev/null)" ||
        fail "setup.sh fast-path 失败: $tui_args"
    python3 -c 'import sys
rows=[l.split("\t") for l in sys.stdin.read().splitlines() if l]
assert rows and all(len(r)>=9 for r in rows), "不是统一资源计划 TSV"' <<<"$tui_selection" ||
        fail "setup.sh fast-path 输出错误 ($tui_args): $tui_selection"
done
pass "setup.sh --tui 与 --ci --tui fast-path"

# ---- 6) fixture/mock setup.sh：argv 协议 ----
fixture="$(mktemp -d)"
# 独立冲突 fixture：本地 skill + 远程同名清单 → local/remote 冲突。
# 在同一个 $fixture 下（cleanup 一并清理），不污染主 fixture 的"无本地 skill"假设。
CONFLICT_REPO="$fixture/conflict-repo"
mkdir -p "$CONFLICT_REPO/configs" "$CONFLICT_REPO/script" "$CONFLICT_REPO/skills/oh-my-claudecode"
# 自造 skills.toml：远程声明同名 oh-my-claudecode source，与本地 skills/oh-my-claudecode 冲突。
# （真实 configs/skills.toml 双源冲突后已空清单，冲突 fixture 用独立清单保持语义。）
cat >"$CONFLICT_REPO/configs/skills.toml" <<'TOML'
[[sources]]
name = "oh-my-claudecode"
repo = "owner/oh-my-claudecode"
skill = "*"
agent = "claude-code"
scope = "global"
TOML
cp "$REPO_ROOT/configs/plugins.toml" "$CONFLICT_REPO/configs/"
cp "$REPO_ROOT/script/parse-manifests.py" "$REPO_ROOT/script/resource-plan.py" "$CONFLICT_REPO/script/"
cat >"$CONFLICT_REPO/skills/oh-my-claudecode/SKILL.md" <<'EOF'
---
name: oh-my-claudecode
description: 本地同名 skill（冲突 fixture）
---
EOF
# 冲突 fixture 也要 mock setup.sh，否则解析冲突后执行找不到 setup.sh（返回 1，无 argv）
cat >"$CONFLICT_REPO/setup.sh" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0")|$*" >> "$MOCK_LOGFILE"
[[ -n "${MOCK_EXIT:-}" ]] && exit "$MOCK_EXIT"
exit 0
EOF
chmod +x "$CONFLICT_REPO/setup.sh"
# 独立无冲突 uninstall fixture：本地 skill foo-local 与 manifest 不同名，不产生冲突。
# 用于验证 uninstall 页勾选本地 skill 正确进记录与 argv（不经过冲突块）。
UNINST_REPO="$fixture/uninst-repo"
mkdir -p "$UNINST_REPO/configs" "$UNINST_REPO/script" "$UNINST_REPO/skills/foo-local"
# 自造 skills.toml：远程声明与本地 foo-local 不同名的 remote-skill，确保无冲突
# （uninstall fixture 的前提是本地 skill 不与清单条目同名）。
cat >"$UNINST_REPO/configs/skills.toml" <<'TOML'
[[sources]]
name = "uninst-src"
repo = "owner/uninst-repo"
skill = "remote-skill"
agent = "claude-code"
scope = "global"
TOML
cp "$REPO_ROOT/configs/plugins.toml" "$UNINST_REPO/configs/"
cp "$REPO_ROOT/script/parse-manifests.py" "$REPO_ROOT/script/resource-plan.py" "$UNINST_REPO/script/"
cat >"$UNINST_REPO/skills/foo-local/SKILL.md" <<'EOF'
---
name: foo-local
description: 唯一本地 skill（uninstall fixture）
---
EOF
cat >"$UNINST_REPO/setup.sh" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0")|$*" >> "$MOCK_LOGFILE"
[[ -n "${MOCK_EXIT:-}" ]] && exit "$MOCK_EXIT"
exit 0
EOF
chmod +x "$UNINST_REPO/setup.sh"
# 主 fixture 仓库
# 真实安装 e2e fixture：真实 setup.sh + 本地路径源 → 真实装进隔离 HOME → claude /context 读取。
# 用本地 git 仓库路径作 npx skills 的 repo（真实安装、零网络、可重复、完全隔离）。
E2E_SRC="$fixture/e2e-src"
mkdir -p "$E2E_SRC/real-skill"
cat >"$E2E_SRC/real-skill/SKILL.md" <<'EOF'
---
name: real-skill
description: 真实安装 e2e 测试 skill
---
EOF
printf '# e2e source\n' >"$E2E_SRC/README.md"
git -C "$E2E_SRC" init -q
git -C "$E2E_SRC" config user.email e2e@test
git -C "$E2E_SRC" config user.name e2e
git -C "$E2E_SRC" add -A
git -C "$E2E_SRC" commit -qm init

E2E_REPO="$fixture/e2e-repo"
mkdir -p "$E2E_REPO/configs" "$E2E_REPO/script"
cp "$REPO_ROOT/setup.sh" "$E2E_REPO/setup.sh"
chmod +x "$E2E_REPO/setup.sh"
# setup.sh source script/install-common.sh，补齐使真实 setup.sh 可执行
cp "$REPO_ROOT/script/install-common.sh" "$E2E_REPO/script/"
cp "$REPO_ROOT/script/parse-manifests.py" "$REPO_ROOT/script/resource-plan.py" "$E2E_REPO/script/"
cat >"$E2E_REPO/configs/skills.toml" <<TOML
[[sources]]
name = "e2e-source"
repo = "$E2E_SRC"
skill = "real-skill"
agent = "claude-code"
scope = "global"
note = "本地路径真实安装 e2e"
TOML
# e2e 隔离 HOME：npx 用 \$HOME 展开 ~，必须同时设 CLAUDE_CONFIG_DIR 与 HOME 指向隔离目录
E2E_HOME="$fixture/e2e-home"
mkdir -p "$E2E_HOME/.claude"

cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT

# fixture 仓库：自造 configs/skills.toml + 真实 plugins.toml + script/(parse-manifests.py + resource-plan.py) + mock setup.sh
# 自造 3 个 source，别名即 skill 名（skill="*" 无 inventory 时降级为集合资源，alias 作为 skill 行/argv 名）。
# 替代真实清单（双源冲突后已空清单）：omc-a/omc-b 供 multi-skill 用例，pony-skill 供 update/uninstall all 的第三 skill。
mkdir -p "$fixture/repo/configs" "$fixture/repo/script"
cat >"$fixture/repo/configs/skills.toml" <<'TOML'
[[sources]]
name = "omc-a"
repo = "owner/omc-repo"
skill = "*"
agent = "claude-code"
scope = "global"
note = "omc 集合 A"

[[sources]]
name = "omc-b"
repo = "owner/omc-repo"
skill = "*"
agent = "claude-code"
scope = "global"
note = "omc 集合 B"

[[sources]]
name = "pony-skill"
repo = "owner/pony-repo"
skill = "*"
agent = "claude-code"
scope = "global"
note = "ponytail 集合"
TOML
cp "$REPO_ROOT/configs/plugins.toml" "$fixture/repo/configs/"
cp "$REPO_ROOT/script/parse-manifests.py" "$fixture/repo/script/"
cp "$REPO_ROOT/script/resource-plan.py" "$fixture/repo/script/"
# fixture 仓库无本地 skills 目录（清单全 wildcard → 集合资源，无冲突）

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

# 新增用例的隔离输出目录与 session 记录（cleanup 统一清理）
SCENARIO_DIR="$fixture/scenarios"
mkdir -p "$SCENARIO_DIR"
SCENARIO_SESSIONS=()

# ---- 通用 screen 场景运行器 ----
# 用法：run_tui_case <case名> <期望退出码> <期望argv子串|-> <期望stdout模式|-> <按键...>
# 每个 case 用唯一命名 screen 会话与隔离日志；只清理本次创建的 session。
run_tui_case() {
    local case_name="$1" expect_rc="$2" expect_argv="$3" expect_stdout="$4"; shift 4
    local base="$SCENARIO_DIR/$case_name"
    local stdout="$base-stdout.log" stderr="$base-stderr.log" exitf="$base-exit.log"
    local sname="installer-tui-$case_name-$$-$RANDOM"
    : > "$MOCK_LOGFILE"
    screen -dmS "$sname" bash -c '"$1" --repo-root "$2" >"$3" 2>"$4"; rc=$?; printf "%s\\n" "$rc" >"$5"; exit "$rc"' _ \
        "$BIN" "$fixture/repo" "$stdout" "$stderr" "$exitf" || fail "启动 screen 失败: $case_name"
    SCENARIO_SESSIONS+=("$sname")
    sleep 1
    local k
    for k in "$@"; do
        screen -S "$sname" -X stuff "$k" || fail "$case_name: 发送按键 '$k' 失败"
        sleep 0.1
    done
    for _ in {1..100}; do
        [[ -s "$MOCK_LOGFILE" ]] && break
        sleep 0.1
    done
    [[ -s "$MOCK_LOGFILE" ]] || fail "$case_name: 等待 mock argv 超时"
    if [[ "$expect_argv" != "-" ]]; then
        grep -qF -- "$expect_argv" "$MOCK_LOGFILE" || fail "$case_name: argv 未按预期: $(<"$MOCK_LOGFILE")"
    fi
    if [[ "$expect_stdout" != "-" ]]; then
        grep -q -- "$expect_stdout" "$stdout" || fail "$case_name: stdout 机器可读记录缺失: $(<"$stdout")"
    fi
    screen -S "$sname" -X stuff 'q' || fail "$case_name: 无法发送 q"
    for _ in {1..100}; do
        [[ -s "$exitf" ]] && break
        sleep 0.1
    done
    [[ "$(<"$exitf")" == "$expect_rc" ]] || fail "$case_name: 退出码应 $expect_rc，实际 $(<"$exitf" 2>/dev/null || true)"
    for _ in {1..100}; do
        screen -ls 2>/dev/null | grep -q "\.${sname}[[:space:]]" || break
        sleep 0.1
    done
    screen -ls 2>/dev/null | grep -q "\.${sname}[[:space:]]" && fail "$case_name: TUI shell 进程未结束"
    screen -S "$sname" -X quit >/dev/null 2>&1 || true
    SCENARIO_SESSIONS=("${SCENARIO_SESSIONS[@]/$sname}")
    pass "TUI case: $case_name"
}

# 用法：run_repo_case <repo> <case名> <期望退出码> <期望argv子串|-> <期望stdout模式|-> <按键...>
# 与 run_tui_case 相同，但指定 repo 根（用于无冲突 uninstall fixture）。
run_repo_case() {
    local repo="$1" case_name="$2" expect_rc="$3" expect_argv="$4" expect_stdout="$5"; shift 5
    local base="$SCENARIO_DIR/$case_name"
    local stdout="$base-stdout.log" stderr="$base-stderr.log" exitf="$base-exit.log"
    local sname="installer-tui-$case_name-$$-$RANDOM"
    : > "$MOCK_LOGFILE"
    screen -dmS "$sname" bash -c '"$1" --repo-root "$2" >"$3" 2>"$4"; rc=$?; printf "%s\\n" "$rc" >"$5"; exit "$rc"' _ \
        "$BIN" "$repo" "$stdout" "$stderr" "$exitf" || fail "启动 screen 失败: $case_name"
    SCENARIO_SESSIONS+=("$sname")
    sleep 1
    local k
    for k in "$@"; do
        screen -S "$sname" -X stuff "$k" || fail "$case_name: 发送按键 '$k' 失败"
        sleep 0.1
    done
    for _ in {1..100}; do
        [[ -s "$MOCK_LOGFILE" ]] && break
        sleep 0.1
    done
    [[ -s "$MOCK_LOGFILE" ]] || fail "$case_name: 等待 mock argv 超时"
    if [[ "$expect_argv" != "-" ]]; then
        grep -qF -- "$expect_argv" "$MOCK_LOGFILE" || fail "$case_name: argv 未按预期: $(<"$MOCK_LOGFILE")"
    fi
    if [[ "$expect_stdout" != "-" ]]; then
        grep -q -- "$expect_stdout" "$stdout" || fail "$case_name: stdout 机器可读记录缺失: $(<"$stdout")"
    fi
    screen -S "$sname" -X stuff 'q' || fail "$case_name: 无法发送 q"
    for _ in {1..100}; do
        [[ -s "$exitf" ]] && break
        sleep 0.1
    done
    [[ "$(<"$exitf")" == "$expect_rc" ]] || fail "$case_name: 退出码应 $expect_rc，实际 $(<"$exitf" 2>/dev/null || true)"
    for _ in {1..100}; do
        screen -ls 2>/dev/null | grep -q "\.${sname}[[:space:]]" || break
        sleep 0.1
    done
    screen -ls 2>/dev/null | grep -q "\.${sname}[[:space:]]" && fail "$case_name: TUI shell 进程未结束"
    screen -S "$sname" -X quit >/dev/null 2>&1 || true
    SCENARIO_SESSIONS=("${SCENARIO_SESSIONS[@]/$sname}")
    pass "TUI case: $case_name"
}

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
    local s
    for s in "${SCENARIO_SESSIONS[@]:-}"; do
        [[ -n "$s" ]] && screen -S "$s" -X quit >/dev/null 2>&1 || true
    done
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
grep -q '^setup.sh|install --ci --skill omc-a --skip-plugins$' "$MOCK_LOGFILE" ||
    fail "argv 未按预期: $(argv_line)"
grep -q $'^install\tskill:omc-a$' "$TUI_STDOUT" ||
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
grep -q '^setup.sh|install --ci --skill omc-a --skip-plugins$' "$MOCK_LOGFILE" ||
    fail "exit=7 argv 未按预期: $(argv_line)"
screen -S "$failure_session" -X quit >/dev/null 2>&1 || true
failure_session_created=0
pass "GNU screen 真实 TUI 透传 setup.sh 退出码 7 与 argv"

# ---- 9) Update/Uninstall 场景：GNU screen 端到端，覆盖 Radiobox 模式导航 ----
export MOCK_EXIT=0

# update all：切 Update 页（mode 0=全部，默认），确认
# 统一资源语义：逐资源 --update-resource（fixture 无本地 skill，外部 skills + plugins 全覆盖）
run_tui_case update-all 0 "--ci --update-resource skill:omc-a --update-resource skill:omc-b --update-resource skill:pony-skill --update-resource plugin:claude-code-setup --update-resource plugin:code-review --update-resource plugin:feature-dev --update-resource plugin:skill-creator --update-resource plugin:oh-my-claudecode --update-resource plugin:context-mode --update-resource plugin:ponytail --update-resource plugin:superpowers" \
    "update	all" '2' 'e' $'\r'

# update selected：Install 页勾选首个 skill → 切 Update → 下箭头 + 空格选中「选中的项目」
#（Radiobox 的 ArrowDown 只移高亮，需空格才把 selected 设为高亮项）→ 确认
# 勾选的外部 skill 走统一 resolver（--update-resource skill:X）
run_tui_case update-selected 0 "--ci --update-resource skill:omc-a" "update	skill:omc-a" \
    ' ' '2' $'\x1b[B' ' ' 'e' $'\r'

# uninstall all：切 Uninstall 页（mode 0=完全卸载，默认），确认
run_tui_case uninstall-all 0 "--uninstall all --ci" "uninstall	all" '3' 'e' $'\r'

# uninstall core：切 Uninstall 页，下箭头 + 空格选中「仅 core」，确认
run_tui_case uninstall-core 0 "--uninstall core --ci" "uninstall	core" '3' $'\x1b[B' ' ' 'e' $'\r'

# uninstall selected：切 Uninstall 页，全选（a），下箭头×2 + 空格选中「选中的项目」，确认
# 统一资源语义：全选后逐资源 --uninstall-resource（fixture 无本地 skill）
run_tui_case uninstall-selected 0 "--ci --uninstall-resource skill:omc-a --uninstall-resource skill:omc-b --uninstall-resource skill:pony-skill --uninstall-resource plugin:claude-code-setup --uninstall-resource plugin:code-review --uninstall-resource plugin:feature-dev --uninstall-resource plugin:skill-creator --uninstall-resource plugin:oh-my-claudecode --uninstall-resource plugin:context-mode --uninstall-resource plugin:ponytail --uninstall-resource plugin:superpowers" \
    "uninstall	skill:omc-a" \
    '3' 'a' $'\x1b[B' $'\x1b[B' ' ' 'e' $'\r'

# ---- 10) 冲突资源：GNU screen 三选一（local/remote/skip）与 argv/记录 ----
# 统一资源语义：同名 local+remote 才冲突；用户必须逐项选择，不得静默默认。
# 冲突 fixture：本地 skills/oh-my-claudecode + 远程清单同名 → skill:oh-my-claudecode 冲突。
# 注意：冲突时未选择来源（直接确认）应被拦截，不产生 argv。
export MOCK_EXIT=0
run_conflict_case() {
    local name="$1" expect_argv="$2" expect_stdout="$3"; shift 3
    local base="$SCENARIO_DIR/cf-$name"
    local stdout="$base-stdout.log" stderr="$base-stderr.log" exitf="$base-exit.log"
    local sname="installer-tui-cf-$name-$$-$RANDOM"
    : > "$MOCK_LOGFILE"
    screen -dmS "$sname" bash -c '"$1" --repo-root "$2" >"$3" 2>"$4"; rc=$?; printf "%s\\n" "$rc" >"$5"; exit "$rc"' _ \
        "$BIN" "$CONFLICT_REPO" "$stdout" "$stderr" "$exitf" || fail "启动冲突 screen 失败: $name"
    SCENARIO_SESSIONS+=("$sname")
    # 初始等 FTXUI 事件循环就绪；空格是最先的按键，若提前会被吞
    sleep 1.5
    local k
    for k in "$@"; do
        screen -S "$sname" -X stuff "$k" || fail "$name: 发送按键 '$k' 失败"
        sleep 0.25
    done
    for _ in {1..100}; do
        [[ -s "$MOCK_LOGFILE" ]] && break
        sleep 0.1
    done
    if [[ "$expect_argv" == "-" ]]; then
        [[ ! -s "$MOCK_LOGFILE" ]] || fail "$name: 未决冲突不应产生 argv: $(<"$MOCK_LOGFILE")"
    else
        [[ -s "$MOCK_LOGFILE" ]] || {
            echo "--- $name stderr ---" >&2
            cat "$stderr" >&2
            fail "$name: 等待 mock argv 超时"
        }
        grep -qF -- "$expect_argv" "$MOCK_LOGFILE" || fail "$name: argv 未按预期: $(<"$MOCK_LOGFILE")"
        # --choose 只出现一次（冲突 identity 去重）
        [[ "$(grep -o -- '--choose skill:oh-my-claudecode=[a-z]*' "$MOCK_LOGFILE" | wc -l)" -eq 1 ]] ||
            fail "$name: --choose 应恰好一次: $(<"$MOCK_LOGFILE")"
    fi
    if [[ "$expect_stdout" != "-" ]]; then
        grep -q -- "$expect_stdout" "$stdout" || fail "$name: stdout 机器记录缺失: $(<"$stdout")"
    fi
    screen -S "$sname" -X stuff 'q' || fail "$name: 无法发送 q"
    for _ in {1..100}; do
        [[ -s "$exitf" ]] && break
        sleep 0.1
    done
    [[ "$(<"$exitf")" == "0" ]] || fail "$name: 退出码应 0，实际 $(<"$exitf" 2>/dev/null || true)"
    for _ in {1..100}; do
        screen -ls 2>/dev/null | grep -q "\.${sname}[[:space:]]" || break
        sleep 0.1
    done
    screen -ls 2>/dev/null | grep -q "\.${sname}[[:space:]]" && fail "$name: TUI shell 进程未结束"
    screen -S "$sname" -X quit >/dev/null 2>&1 || true
    SCENARIO_SESSIONS=("${SCENARIO_SESSIONS[@]/$sname}")
    pass "冲突 case: $name"
}

# 未决冲突拦截：直接确认不产生 argv（焦点在冲突 radiobox，空格才选来源）。
# modal 打开后 OK 被拦、modal 不关；按 Esc 关闭 modal，函数末尾再统一发 q 退出。
run_conflict_case unresolved "-" "-" 'e' $'\r' $'\x1b'
# 空格选 local（焦点 radiobox 默认 local 高亮）→ 确认
run_conflict_case local "install --ci --choose skill:oh-my-claudecode=local" "install	all" \
    ' ' 'e' $'\r'
# 下箭头+空格选 remote → 确认
run_conflict_case remote "install --ci --choose skill:oh-my-claudecode=remote" "install	all" \
    $'\x1b[B' ' ' 'e' $'\r'
# 下箭头×2+空格选 skip → 确认（install 仍执行，冲突项跳过）
run_conflict_case skip "install --ci --choose skill:oh-my-claudecode=skip" "install	all" \
    $'\x1b[B' $'\x1b[B' ' ' 'e' $'\r'

# ---- 11) Uninstall selected：本地 skill 也进机器记录与 argv ----
# 用无冲突 UNINST_REPO：本地 skill foo-local 与 manifest 不同名，不产生冲突。
# uninstall 页全选（含本地）→ 选「选中的项目」→ 执行，argv 与机器记录都含 skill:foo-local。
# 3(uninstall) → a 全选 → 下箭头×2 + 空格(选「选中的项目」) → e → 回车
run_repo_case "$UNINST_REPO" uninstall-local-skill 0 \
    "--uninstall-resource skill:foo-local" "uninstall	skill:foo-local" \
    '3' 'a' $'\x1b[B' $'\x1b[B' ' ' 'e' $'\r'

# ---- 12) 冲突资源跨来源同选被拦：本地+远程同名条目不可同时卸载 ----
# CONFLICT_REPO 的 skill:oh-my-claudecode 既有本地又有远程条目；uninstall 页全选会同时勾两个，
# 来源矛盾，必须在确认时报错，不产生 argv（避免静默覆盖 --choose 来源）。
# 按键：3(uninstall) → a 全选 → 选「选中的项目」→ e → 回车(modal OK)。
# 拦截发生在 modal OK：报「同时勾选本地与远程」，不 Spawn。Esc 关闭 modal，末尾统一 q。
: > "$MOCK_LOGFILE"
local_base="$SCENARIO_DIR/cf-uninstall-conflict"
local_stdout="$local_base-stdout.log"; local_stderr="$local_base-stderr.log"; local_exitf="$local_base-exit.log"
local_sname="installer-tui-cf-uninstcf-$$-$RANDOM"
screen -dmS "$local_sname" bash -c '"$1" --repo-root "$2" >"$3" 2>"$4"; rc=$?; printf "%s\\n" "$rc" >"$5"; exit "$rc"' _ \
    "$BIN" "$CONFLICT_REPO" "$local_stdout" "$local_stderr" "$local_exitf" || fail "启动 uninstall-conflict screen 失败"
SCENARIO_SESSIONS+=("$local_sname")
sleep 1.5
for k in '3' 'a' $'\x1b[B' $'\x1b[B' ' ' 'e' $'\r' $'\x1b'; do
    screen -S "$local_sname" -X stuff "$k"; sleep 0.25
done
for _ in {1..50}; do [[ -s "$local_exitf" ]] && break; sleep 0.1; done
[[ ! -s "$MOCK_LOGFILE" ]] || fail "uninstall-conflict: 跨来源同选应被拦，不产生 argv: $(<"$MOCK_LOGFILE")"
grep -aq "同时勾选" "$local_stderr" ||
    fail "uninstall-conflict: 应提示来源冲突: $(grep -a '同时勾选' "$local_stderr" | head -1)"
screen -S "$local_sname" -X stuff 'q' || fail "uninstall-conflict: 无法发送 q"
for _ in {1..100}; do [[ -s "$local_exitf" ]] && break; sleep 0.1; done
[[ "$(<"$local_exitf")" == "0" ]] || fail "uninstall-conflict: 退出码应 0，实际 $(<"$local_exitf" 2>/dev/null || true)"
for _ in {1..100}; do screen -ls 2>/dev/null | grep -q "\.${local_sname}[[:space:]]" || break; sleep 0.1; done
screen -S "$local_sname" -X quit >/dev/null 2>&1 || true
SCENARIO_SESSIONS=("${SCENARIO_SESSIONS[@]/$local_sname}")
pass "uninstall 冲突资源跨来源同选被拦"

# ---- 13) 诊断页：verify/status/doctor 三选一执行对应 CLI action ----
# TUI 第 4 个 tab 暴露 CLI 的 verify/status/doctor 能力（三者共享同一 inspection flow）。
# 按键：4(诊断) → ↓↓ 空格（radiobox 选 doctor）→ e(打开 modal) → 回车(确认)。
# 期望 setup.sh 收到 doctor --ci，stdout 机器记录 doctor<TAB>all。
run_tui_case diagnose-doctor 0 "doctor --ci" "^doctor" \
    '4' $'\x1b[B' $'\x1b[B' ' ' 'e' $'\r'

# ---- 14) 批量安装：勾选多个 skill 生成逐项 --skill ----
# Install 页空格勾选第一个 skill → 下箭头 → 空格勾选第二个 → e → 回车。
# 期望 setup.sh 收到 install --ci --skill omc-a --skill omc-b --skip-plugins，
# stdout 机器记录 install<TAB>skill:omc-a<TAB>skill:omc-b。
run_tui_case install-multi-skill 0 "install --ci --skill omc-a --skill omc-b --skip-plugins" \
    "install	skill:omc-a	skill:omc-b" \
    ' ' $'\x1b[B' ' ' 'e' $'\r'

# ---- 15) 安装单个 plugin：右箭头跨列勾选首个 plugin ----
# Install 页右箭头从 skill 列跨到 plugin 列 → 空格勾选第一个 plugin → e → 回车。
# 期望 setup.sh 收到 install --ci --skip-skills --plugin claude-code-setup，
# stdout 机器记录 install<TAB>plugin:claude-code-setup。
run_tui_case install-single-plugin 0 "install --ci --skip-skills --plugin claude-code-setup" \
    "install	plugin:claude-code-setup" \
    $'\x1b[C' ' ' 'e' $'\r'

# ---- 16) 卸载单个外部 skill：选「选中的项目」勾选一项 ----
# Uninstall 页 ↓↓ 空格选「选中的项目」→ 下箭头进 checks → 空格勾选第一个外部 skill → e → 回车。
# 期望 setup.sh 收到 --ci --uninstall-resource skill:omc-a，
# stdout 机器记录 uninstall<TAB>skill:omc-a。
run_tui_case uninstall-single-skill 0 "--ci --uninstall-resource skill:omc-a" \
    "uninstall	skill:omc-a" \
    '3' $'\x1b[B' $'\x1b[B' ' ' $'\x1b[B' ' ' 'e' $'\r'

# ---- 17) 更新多选：勾选多个 skill 后走统一 resolver 逐项更新 ----
# Install 页勾选 2 个 skill → 切 Update 页 → ↓ 空格选「选中的项目」→ e → 回车。
# 期望 setup.sh 收到 --ci --update-resource skill:omc-a --update-resource skill:omc-b，
# stdout 机器记录 update<TAB>skill:omc-a<TAB>skill:omc-b。
run_tui_case update-multi-skill 0 "--ci --update-resource skill:omc-a --update-resource skill:omc-b" \
    "update	skill:omc-a	skill:omc-b" \
    ' ' $'\x1b[B' ' ' '2' $'\x1b[B' ' ' 'e' $'\r'

# ---- 18) 真实安装 + claude /context 读取（端到端）----
# 这是「真实验证」核心：TUI 勾选 → TUI 生成的 argv 对应真实命令（npx skills add 本地源）
# → 真实装进隔离 CLAUDE_CONFIG_DIR/skills/ → claude -p /context 的 Skills 表真实读到。
# 即「TUI 操作 → 真实安装 → claude 能读到」闭环；不依赖完整 setup.sh 流程的仓库级检查。
# 隔离 HOME 同时设 CLAUDE_CONFIG_DIR 与 HOME（npx 用 $HOME 展开 ~），不碰真实 ~/.claude。
# 与 setup.sh ensure_claude_code 一致：缺啥装啥（claude 不在 PATH 则 npm 装），
# 且 CLAUDE_HOME 未初始化时后台启动 claude 完成初始化（不阻塞 CI），等就绪后再继续。
# 真实验证必须在 CI 真实跑，不静默跳过——装不上或 npx 装失败就是环境问题，fail loudly。
if ! command -v claude >/dev/null 2>&1; then
    command -v npm >/dev/null 2>&1 || fail "真实安装 e2e: claude 与 npm 都不可用"
    echo "真实安装 e2e: claude 不在 PATH，npm install -g @anthropic-ai/claude-code" >&2
    npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 ||
        fail "真实安装 e2e: 无法自动安装 claude"
fi
command -v claude >/dev/null 2>&1 || fail "真实安装 e2e: claude 仍不可用"
command -v npx >/dev/null 2>&1 || fail "真实安装 e2e 需要 npx"
command -v git >/dev/null 2>&1 || fail "真实安装 e2e 需要 git"
# CLAUDE_HOME 未初始化：后台启动 claude 完成初始化（首次需生成配置/凭据），等就绪。
# 注意：fixture 会预建空的 .claude 目录，因此「空目录」也必须视为未初始化，不能据此跳过。
if [[ ! -d "$E2E_HOME/.claude" ]] || [[ -z "$(ls -A "$E2E_HOME/.claude" 2>/dev/null || true)" ]]; then
    echo "真实安装 e2e: CLAUDE_HOME 未初始化，后台启动 claude 完成初始化" >&2
    env CLAUDE_CONFIG_DIR="$E2E_HOME/.claude" HOME="$E2E_HOME" \
        claude </dev/null >/dev/null 2>&1 &
    e2e_bootstrap_pid=$!
    # 等待初始化就绪：最多 60s，.claude.json 出现即认为 CLAUDE_HOME 可用
    #（实测首次 claude </dev/null 生成 .claude.json/backups/sessions，不写 settings.json）
    for _ in {1..60}; do
        [[ -s "$E2E_HOME/.claude/.claude.json" ]] && break
        kill -0 "$e2e_bootstrap_pid" 2>/dev/null || break
        sleep 1
    done
fi

# (a) 真实 npx 安装到隔离 HOME：与 setup.sh install_external_skills 完全一致的命令。
# 注意 add 后必须再传 -y：第一个 -y 是 npx 的（自动确认下载包），add -y 才是 skills CLI 的
#（跳过 "Proceed with installation?" 交互确认）。缺 add -y 时，非 agent 环境（无 AI_AGENT/CLAUDE_* env）
# 且无 TTY 下 skills CLI 会卡在确认提示、不真正安装——CI 实测踩过这个坑。
# 不静默跳过——npx skills add 失败就是真实验证失败。捕获 npx 输出，失败时打印，
# 让 CI 能暴露「装到哪了 / 探测到什么」，避免输出被吞掉无法诊断（fail loudly）。
e2e_npx_out=""
if ! e2e_npx_out="$(timeout 180 env CLAUDE_CONFIG_DIR="$E2E_HOME/.claude" HOME="$E2E_HOME" \
    npx -y skills@latest add -y "$E2E_SRC" -s real-skill -a claude-code -g 2>&1)"; then
    printf '%s\n' "$e2e_npx_out" >&2
    fail "真实安装 e2e: npx skills add 失败"
fi
[[ -f "$E2E_HOME/.claude/skills/real-skill/SKILL.md" ]] || {
    echo "--- 隔离 skills 目录 ---" >&2
    ls -R "$E2E_HOME/.claude/skills/" >&2 2>/dev/null || true
    echo "--- npx 输出（尾部 40 行）---" >&2
    printf '%s\n' "$e2e_npx_out" | tail -40 >&2
    echo "--- 隔离 HOME 结构 ---" >&2
    find "$E2E_HOME" -maxdepth 4 \( -name 'SKILL.md' -o -name 'skills' \) 2>/dev/null | head -20 >&2
    echo "--- 真实 HOME 是否被污染 ---" >&2
    ls -d "$HOME/.claude/skills/real-skill" "$HOME/.agents/skills/real-skill" 2>/dev/null || echo "真实 HOME 无 real-skill" >&2
    fail "真实安装 e2e: real-skill 未装进隔离 HOME"
}
pass "真实 npx 安装到隔离 HOME (real-skill)"

# (b) 核心验证：claude -p /context 真实读到（grep "| real-skill |" 精确匹配 Skills 表行）
e2e_ctx=$(timeout 150 env CLAUDE_CONFIG_DIR="$E2E_HOME/.claude" HOME="$E2E_HOME" \
    claude -p "/context" </dev/null 2>/dev/null)
printf '%s\n' "$e2e_ctx" | grep -Fq "| real-skill |" ||
    fail "真实安装 e2e: real-skill 未出现在 claude /context 的 Skills 表"
pass "claude /context 真实读到 real-skill"

# (c) 隔离验证：真实 HOME 未被污染
[[ ! -e "$HOME/.claude/skills/real-skill" ]] ||
    fail "真实安装 e2e: 污染了真实 ~/.claude/skills/real-skill"
pass "真实 HOME 无 real-skill（隔离生效）"

echo "ALL TESTS PASSED"


