#!/usr/bin/env bash
# Tests for the unified resource resolver in setup.sh.
#
# Covers:
#   - --update-resource / --uninstall-resource resolve via resource-plan.py
#   - old typed flags convert into the unified resource list
#   - local/remote conflict is detected; --choose resolves it
#   - non-interactive unresolved conflict fails non-zero (no silent source)
#   - update executes update_skill/update_local_skill/update_plugin
#   - uninstall executes uninstall_skill/uninstall_plugin/uninstall_local_skill
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- 隔离环境：fake npx/claude 记录执行的命令 ----
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/repo/skills/local-one" \
         "$fixture/repo/skills/local-two" \
         "$fixture/repo/skills/same" \
         "$fixture/repo/configs"
printf '%s\n' '---' 'name: local-one' 'description: test' '---' > "$fixture/repo/skills/local-one/SKILL.md"
printf '%s\n' '---' 'name: local-two' 'description: test' '---' > "$fixture/repo/skills/local-two/SKILL.md"
printf '%s\n' '---' 'name: same' 'description: test' '---' > "$fixture/repo/skills/same/SKILL.md"
# remote skill 源：source alias=remote-source，skill=remote-a；
# remote-same 与本地 skills/same 同名，构成 local/remote 冲突
cat > "$fixture/repo/configs/skills.toml" <<'TOML'
[[sources]]
name = "remote-source"
repo = "owner/repo"
skill = "remote-a"
agent = "claude-code"
scope = "global"
note = "test"

[[sources]]
name = "remote-same"
repo = "owner/repo"
skill = "same"
agent = "claude-code"
scope = "global"
note = "test"

[[sources]]
name = "wildcard-src"
repo = "owner/wildcard"
skill = "*"
agent = "claude-code"
scope = "global"
note = "wildcard 整源（无 inventory → 集合资源）"
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

# fake npx / claude：把 argv 记录到执行日志，退出码可配置
mkdir -p "$fixture/bin"
cat >"$fixture/bin/npx" <<'EOF'
#!/usr/bin/env bash
printf 'npx %s\n' "$*" >> "${EXEC_LOG:?}"
[[ -n "${EXEC_EXIT:-}" ]] && exit "$EXEC_EXIT"
exit 0
EOF
cat >"$fixture/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >> "${EXEC_LOG:?}"
[[ -n "${EXEC_EXIT:-}" ]] && exit "$EXEC_EXIT"
exit 0
EOF
chmod +x "$fixture/bin/npx" "$fixture/bin/claude"
export PATH="$fixture/bin:$PATH"
export EXEC_LOG="$fixture/exec.log"

fail() { echo "FAIL: $*" >&2; exit 1; }

# source setup.sh：覆盖 REPO_ROOT 指向 fixture，parser/planner 用仓库真实脚本
source "$REAL_REPO_ROOT/setup.sh"
REPO_ROOT="$fixture/repo"
SKILLS_CONFIG="$REPO_ROOT/configs/skills.toml"
PLUGINS_CONFIG="$REPO_ROOT/configs/plugins.toml"
RESOURCE_PLANNER="$REAL_REPO_ROOT/script/resource-plan.py"
MANIFEST_PARSER="$REAL_REPO_ROOT/script/parse-manifests.py"

DRY_RUN=false; CI_MODE=false; FORCE=false

# ---- 1) 唯一 local skill：自动计划 local ----
: > "$EXEC_LOG"
UPDATE_RESOURCES=(); RESOURCE_CHOICES=()
UPDATE_RESOURCES+=("skill:local-one")
resource_update
grep -q 'symlink' "$EXEC_LOG" 2>/dev/null || true  # update_local_skill 走 ensure_symlink，不 exec
[[ -L "$CLAUDE_HOME/skills/local-one" ]] || fail "唯一 local skill 更新后应有软链接"
pass "唯一 local skill 自动计划并软链接"

# ---- 2) remote skill 更新走 npx skills update（用 source alias 作 exec 键）----
: > "$EXEC_LOG"
UPDATE_RESOURCES=(); RESOURCE_CHOICES=()
UPDATE_RESOURCES+=("skill:remote-source")
resource_update
grep -q 'npx .*skills.*update.*remote-source' "$EXEC_LOG" || fail "remote skill 更新应调用 npx skills update: $(<"$EXEC_LOG")"
pass "remote skill 更新走 npx skills update"

# ---- 3) plugin 更新走 claude plugin update ----
: > "$EXEC_LOG"
UPDATE_RESOURCES=(); RESOURCE_CHOICES=()
UPDATE_RESOURCES+=("plugin:plug")
resource_update
grep -q 'claude .*plugin.*update' "$EXEC_LOG" || fail "plugin 更新应调用 claude plugin update: $(<"$EXEC_LOG")"
pass "plugin 更新走 claude plugin update"

# ---- 4) 同名 local/remote 冲突：非交互未决应失败 ----
UPDATE_RESOURCES=(); RESOURCE_CHOICES=()
UPDATE_RESOURCES+=("skill:same")
CI_MODE=true
set +e
resource_update >/tmp/resolver-conflict.out 2>&1
rc=$?
set -e
CI_MODE=false
[[ "$rc" -eq 2 ]] || fail "非交互未决冲突应 exit 2，实际 $rc"
grep -q '冲突' /tmp/resolver-conflict.out || fail "冲突应输出候选信息: $(</tmp/resolver-conflict.out)"
pass "非交互未决冲突 exit 2"

# ---- 5) --choose 解决冲突 ----
: > "$EXEC_LOG"
UPDATE_RESOURCES=(); RESOURCE_CHOICES=()
UPDATE_RESOURCES+=("skill:same")
RESOURCE_CHOICES+=("skill:same=remote")
resource_update
grep -q 'npx .*skills.*update' "$EXEC_LOG" || fail "choose remote 应更新远程: $(<"$EXEC_LOG")"
pass "choose=remote 解决冲突"

# ---- 6) uninstall：remote skill ----
: > "$EXEC_LOG"
UNINSTALL_RESOURCES=(); RESOURCE_CHOICES=()
UNINSTALL_RESOURCES+=("skill:remote-source")
resource_uninstall
grep -q 'npx .*skills.*remove' "$EXEC_LOG" || fail "uninstall remote skill 应调用 npx skills remove: $(<"$EXEC_LOG")"
pass "uninstall remote skill 走 npx skills remove"

# ---- 7) uninstall：plugin ----
: > "$EXEC_LOG"
UNINSTALL_RESOURCES=(); RESOURCE_CHOICES=()
UNINSTALL_RESOURCES+=("plugin:plug")
resource_uninstall
grep -q 'claude .*plugin.*uninstall' "$EXEC_LOG" || fail "uninstall plugin 应调用 claude plugin uninstall: $(<"$EXEC_LOG")"
pass "uninstall plugin 走 claude plugin uninstall"

# ---- 8) uninstall：local skill 只删软链接 ----
# 先安装 local-two
: > "$EXEC_LOG"
UPDATE_RESOURCES=(); RESOURCE_CHOICES=()
UPDATE_RESOURCES+=("skill:local-two")
resource_update
[[ -L "$CLAUDE_HOME/skills/local-two" ]] || fail "安装 local-two 失败"
: > "$EXEC_LOG"
UNINSTALL_RESOURCES=(); RESOURCE_CHOICES=()
UNINSTALL_RESOURCES+=("skill:local-two")
resource_uninstall
[[ ! -L "$CLAUDE_HOME/skills/local-two" ]] || fail "local skill 卸载后软链接应删除"
[[ -f "$fixture/repo/skills/local-two/SKILL.md" ]] || fail "仓库源文件不应被删除"
pass "uninstall local skill 只删软链接保留仓库源"

# ---- 9) wildcard 集合资源（skill="*" 无 inventory）：按 source alias 整源更新 ----
: > "$EXEC_LOG"
UPDATE_RESOURCES=(); RESOURCE_CHOICES=()
UPDATE_RESOURCES+=("skill:wildcard-src")
resource_update
grep -q 'npx .*skills.*update.*wildcard-src' "$EXEC_LOG" || fail "wildcard 集合资源更新应调用 npx skills update wildcard-src: $(<"$EXEC_LOG")"
pass "wildcard 集合资源整源更新"

# ---- 10) 旧参数路径回归：--update-skill 按 source alias 整源更新 ----
: > "$EXEC_LOG"
UPDATE_SKILLS+=("remote-source")
update_failed=0
for s in "${UPDATE_SKILLS[@]}"; do
    if [[ "$s" == core || "$s" == all ]]; then
        update_all_skills || update_failed=1
    else
        update_skill "$s" || update_failed=1
    fi
done
[[ "$update_failed" == 0 ]] || fail "旧参数整源更新失败"
grep -q 'npx .*skills.*update.*remote-source' "$EXEC_LOG" || fail "旧参数应调 npx skills update: $(<"$EXEC_LOG")"
pass "旧参数整源更新仍工作"

# ---- 11) --skill 单项安装完成后不继续 plugins/最终验证 ----
FLOW_LOG="$fixture/install-flow.log"
: > "$FLOW_LOG"
phase() { printf 'phase %s\n' "$1" >> "$FLOW_LOG"; }
ensure_claude_code() { echo ensure-claude >> "$FLOW_LOG"; }
ensure_core_config() { echo ensure-core >> "$FLOW_LOG"; }
ensure_settings_json() { echo ensure-settings >> "$FLOW_LOG"; }
install_external_skills() { printf 'skills %s\n' "$*" >> "$FLOW_LOG"; }
install_third_party_plugins() { echo plugins >> "$FLOW_LOG"; }
verify_core_config() { echo verify-core >> "$FLOW_LOG"; }
run_final_doctor() { echo doctor >> "$FLOW_LOG"; }
SELECTED_SKILLS=(humanizer)
SELECTED_PLUGINS=()
SKIP_SKILLS=false
SKIP_PLUGINS=false
run_install_flow
grep -q 'skills humanizer' "$FLOW_LOG" || fail "--skill 应安装指定 skill"
! grep -q 'Phase 4\|plugins\|verify-core\|doctor' "$FLOW_LOG" || fail "--skill 不应继续 plugins/最终验证: $(<"$FLOW_LOG")"
pass "--skill 单项安装完成后立即退出"

echo "All setup resolver tests passed."
