#!/usr/bin/env bash
# Tests for --agents=pi: install skills to ~/.pi/agent/skills/ only.
#
# Covers:
#   - full install: external skills via `npx skills add ... -a pi -g`,
#     repo-local skills symlinked into ~/.pi/agent/skills/
#   - specified install (--skill / --update-local-skill) installs only the
#     chosen items; the other category is skipped
#   - no claude-specific flow runs (no ensure_claude_code / plugins / verify)
#   - CLI-level: --agents=pi with update/uninstall params is rejected
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# ---- fixture repo: skills.toml (2 external) + repo-local skills/ ----
mkdir -p "$fixture/repo/skills/local-one" "$fixture/repo/skills/local-two" \
         "$fixture/repo/configs"
printf '%s\n' '---' 'name: local-one' 'description: test' '---' > "$fixture/repo/skills/local-one/SKILL.md"
printf '%s\n' '---' 'name: local-two' 'description: test' '---' > "$fixture/repo/skills/local-two/SKILL.md"
cat > "$fixture/repo/configs/skills.toml" <<'TOML'
[[sources]]
name = "grilling"
repo = "mattpocock/skills"
skill = "grilling"
agent = "claude-code"
scope = "global"
note = "test"

[[sources]]
name = "humanizer"
repo = "blader/humanizer"
skill = "humanizer"
agent = "claude-code"
scope = "global"
note = "test"
TOML
cat > "$fixture/repo/configs/plugins.toml" <<'TOML'
[[plugins]]
name = "plug"
repo = "owner/plugin"
method = "claude-plugin"
marketplace = "market"
command = ""
note = "test"
TOML

CLAUDE_HOME="$fixture/home"
mkdir -p "$CLAUDE_HOME"
export CLAUDE_CONFIG_DIR="$CLAUDE_HOME"
export HOME="$fixture/home"
# pi 安装目标独立于 CLAUDE_HOME，隔离验证 symlink 落点
PI_TARGET="$HOME/.pi/agent/skills"
export PI_SKILLS_HOME="$PI_TARGET"

# fake npx：记录 argv
mkdir -p "$fixture/bin"
cat > "$fixture/bin/npx" <<'EOF'
#!/usr/bin/env bash
printf 'npx %s\n' "$*" >> "${EXEC_LOG:?}"
exit 0
EOF
chmod +x "$fixture/bin/npx"
export PATH="$fixture/bin:$PATH"
export EXEC_LOG="$fixture/exec.log"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# source setup.sh，覆盖 REPO_ROOT 指向 fixture
source "$REAL_REPO_ROOT/setup.sh"
REPO_ROOT="$fixture/repo"
SKILLS_CONFIG="$REPO_ROOT/configs/skills.toml"
PLUGINS_CONFIG="$REPO_ROOT/configs/plugins.toml"
RESOURCE_PLANNER="$REAL_REPO_ROOT/script/resource-plan.py"
MANIFEST_PARSER="$REAL_REPO_ROOT/script/parse-manifests.py"

DRY_RUN=false; CI_MODE=false; FORCE=false
AGENTS_TARGET="claude-code"

# ---- 1) 全量：外部走 -a pi，仓库自有 symlink 到 PI_TARGET ----
: > "$EXEC_LOG"
AGENTS_TARGET="pi"
SELECTED_SKILLS=()
UPDATE_RESOURCES=()
run_pi_flow
# 外部：两次 npx add 均带 -a pi -g
[[ "$(grep -c 'add -y .* -a pi -g' "$EXEC_LOG")" -eq 2 ]] || \
    fail "全量外部应调用 2 次 npx add -a pi -g: $(<"$EXEC_LOG")"
grep -q 'add -y mattpocock/skills -s grilling -a pi -g' "$EXEC_LOG" || fail "grilling 缺 -a pi -g"
grep -q 'add -y blader/humanizer -s humanizer -a pi -g' "$EXEC_LOG" || fail "humanizer 缺 -a pi -g"
# 仓库自有：symlink 到 PI_TARGET（而非 ~/.claude/skills）
[[ -L "$PI_TARGET/local-one" ]] || fail "local-one 未 symlink 到 PI_TARGET"
[[ -L "$PI_TARGET/local-two" ]] || fail "local-two 未 symlink 到 PI_TARGET"
[[ -e "$CLAUDE_HOME/skills/local-one" ]] && fail "不应写 ~/.claude/skills"
# 非 skills 流程不跑：没有 claude 命令、没有 plugins
grep -q 'claude ' "$EXEC_LOG" && fail "pi 模式不应调用 claude: $(<"$EXEC_LOG")"
pass "全量安装：外部 -a pi + 仓库自有 symlink 到 ~/.pi/agent/skills"

# ---- 2) 指定外部 skill：只装 grilling，跳过仓库自有 ----
: > "$EXEC_LOG"
AGENTS_TARGET="pi"
SELECTED_SKILLS=(grilling)
UPDATE_RESOURCES=()
rm -f "$PI_TARGET/local-one" "$PI_TARGET/local-two"
run_pi_flow
[[ "$(grep -c '^npx ' "$EXEC_LOG")" -eq 1 ]] || fail "指定外部只应调用 1 次 npx: $(<"$EXEC_LOG")"
grep -q 'add -y mattpocock/skills -s grilling -a pi -g' "$EXEC_LOG" || fail "应装 grilling"
[[ -L "$PI_TARGET/local-one" ]] && fail "指定外部时不应装仓库自有 local-one"
pass "指定外部 skill：只装指定项"

# ---- 3) 指定仓库自有 skill：只装它，跳过外部 ----
: > "$EXEC_LOG"
AGENTS_TARGET="pi"
SELECTED_SKILLS=()
UPDATE_RESOURCES=(skill:local-two)
run_pi_flow
[[ -s "$EXEC_LOG" ]] && fail "指定本地时不应调用外部 npx: $(<"$EXEC_LOG")"
[[ -L "$PI_TARGET/local-two" ]] || fail "应装仓库自有 local-two"
[[ -L "$PI_TARGET/local-one" ]] && fail "指定 local-two 时不应装 local-one"
pass "指定仓库自有 skill：只装指定项"

# ---- 4) CLI 级：--agents=pi 与 update/uninstall 参数冲突被拒 ----
set +e
HOME="$fixture/home" PATH="$fixture/bin:$PATH" \
  bash "$REAL_REPO_ROOT/setup.sh" --agents=pi --update-all >"$fixture/out" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "--agents=pi --update-all 应被拒，实际 exit 0"
grep -q "不支持 update/uninstall" "$fixture/out" || fail "拒绝信息缺失: $(<"$fixture/out")"
pass "CLI: --agents=pi 拒绝 update/uninstall 参数"

# ---- 5) CLI 级：--agents=pi --dry-run 全量走通，外部 dry-run 显示 -a pi ----
set +e
HOME="$fixture/home" PATH="$fixture/bin:$PATH" \
  bash "$REAL_REPO_ROOT/setup.sh" --agents=pi --dry-run --ci >"$fixture/out2" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "--agents=pi --dry-run 应成功，实际 exit $rc: $(<"$fixture/out2")"
grep -q -- '-a pi -g' "$fixture/out2" || fail "dry-run 应显示 -a pi -g"
grep -q 'Pi agents skills 安装完成' "$fixture/out2" || fail "缺少完成横幅"
pass "CLI: --agents=pi --dry-run 全量流程"

echo "All pi-agents tests passed."
