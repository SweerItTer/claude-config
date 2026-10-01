#!/usr/bin/env bash
# Tests for --agents=<非 claude>：只安装 skills 到 ~/.agents/skills，且已安装且最新则跳过。
#
# Covers:
#   - full install: external skills via `npx skills add ... -a universal -g`（universal 的全局
#     目录就是 ~/.agents/skills），repo-local skills symlinked into ~/.agents/skills/
#   - 最新版比对：lock 的 skillFolderHash 与远端 tree oid 一致 → 跳过；不一致 → 重装；
#     目标目录缺失 → 重装；远端不可达 → unknown 仍安装（绝不误跳过）
#   - specified install (--skill / --update-local-skill) installs only the
#     chosen items; the other category is skipped
#   - no claude-specific flow runs (no ensure_claude_code / plugins / verify)
#   - CLI-level: --agents=<非 claude> 拒绝 update/uninstall；--agents=claude 保持完整流程
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fixture="$(mktemp -d)"
api_pid=""
cleanup() {
    [[ -n "$api_pid" ]] && kill "$api_pid" 2>/dev/null || true
    rm -rf "$fixture"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# ---- fixture repo: skills.toml (2 external) + repo-local skills/ + plugins.toml ----
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

[[sources]]
name = "humanizer"
repo = "blader/humanizer"
skill = "humanizer"
agent = "claude-code"
scope = "global"
TOML
cat > "$fixture/repo/configs/plugins.toml" <<'TOML'
[[plugins]]
name = "claude-code-setup"
repo = "anthropics/claude-plugins-official"
method = "claude-plugin"
marketplace = "claude-plugins-official"
command = ""
note = "fixture"
TOML

CLAUDE_HOME="$fixture/home"
mkdir -p "$CLAUDE_HOME"
export CLAUDE_CONFIG_DIR="$CLAUDE_HOME"
export HOME="$fixture/home"
# 非 claude 模式安装目标独立于 CLAUDE_HOME，隔离验证 symlink 落点
AGENTS_TARGET_DIR="$HOME/.agents/skills"
export AGENTS_SKILLS_HOME="$AGENTS_TARGET_DIR"
export SKILLS_LOCK_FILE="$HOME/.agents/.skill-lock.json"

# fake npx：记录 argv；可选模拟 skills CLI 的全局 lock "读-改-写"（无文件锁）、
# 失败注入，以及 start/end 打点（用于验证并发度）。
mkdir -p "$fixture/bin"
cat > "$fixture/bin/npx" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "npx $*" >> "$EXEC_LOG"
[[ -n "${FAKE_NPX_INTERVAL_LOG:-}" ]] && \
    printf 'start %s %s\n' "$$" "$(date +%s%3N)" >> "$FAKE_NPX_INTERVAL_LOG"

if [[ "${FAKE_NPX_LOCK:-0}" == 1 ]]; then
    repo=""
    skills=()
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
        case "${args[i]}" in
            -s) skills+=("${args[i + 1]}") ;;
            add) repo="${args[i + 2]}" ;;
        esac
    done
    lock_dir="${XDG_STATE_HOME:-$HOME/.local/state}/skills"
    mkdir -p "$lock_dir"
    sleep "${FAKE_NPX_DELAY:-0}"
    if [[ -n "${FAKE_NPX_FAIL_REPO:-}" && "$repo" == "$FAKE_NPX_FAIL_REPO" ]]; then
        [[ -n "${FAKE_NPX_INTERVAL_LOG:-}" ]] && \
            printf 'end %s %s\n' "$$" "$(date +%s%3N)" >> "$FAKE_NPX_INTERVAL_LOG"
        exit 1
    fi
    # 真实 CLI 会把该次调用里所有 -s 都装上并逐条写入 lock
    python3 - "$lock_dir/.skill-lock.json" "$repo" "${skills[@]}" <<'PY'
import json, os, sys

path, repo, *skills = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as fp:
        data = json.load(fp)
except Exception:
    data = {"version": 3, "skills": {}}
for skill in skills:
    data.setdefault("skills", {})[skill] = {"source": repo, "skillFolderHash": "emulated"}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fp:
    json.dump(data, fp)
os.replace(tmp, path)
PY
fi

[[ -n "${FAKE_NPX_INTERVAL_LOG:-}" ]] && \
    printf 'end %s %s\n' "$$" "$(date +%s%3N)" >> "$FAKE_NPX_INTERVAL_LOG"
exit 0
EOF
chmod +x "$fixture/bin/npx"
export PATH="$fixture/bin:$PATH"
export EXEC_LOG="$fixture/exec.log"

# ---- fixture GitHub API：远端 tree（sha = 该 skill 目录的 tree oid）----
# grilling 已装且最新（远端 sha == lock 记录）；humanizer 有新版（远端 sha ≠ lock 记录）。
GRILLING_HASH="f0732035b8b1b60ae39454e4191caef32fa91903"
HUMANIZER_OLD="1111111111111111111111111111111111111111"
HUMANIZER_NEW="2222222222222222222222222222222222222222"
mkdir -p "$fixture/api/repos/mattpocock/skills/git/trees" \
         "$fixture/api/repos/blader/humanizer/git/trees"
cat > "$fixture/api/repos/mattpocock/skills/git/trees/HEAD" <<EOF
{"sha": "$GRILLING_HASH", "tree": [
  {"type": "tree", "path": "skills/productivity/grilling", "sha": "$GRILLING_HASH"}
]}
EOF
cat > "$fixture/api/repos/blader/humanizer/git/trees/HEAD" <<EOF
{"sha": "$HUMANIZER_NEW", "tree": [{"type": "blob", "path": "SKILL.md", "sha": "0"}]}
EOF

api_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "$api_port" --bind 127.0.0.1 --directory "$fixture/api" >/dev/null 2>&1 &
api_pid=$!
api_ready=false
for _ in $(seq 1 50); do
    if python3 -c "import socket,sys; s=socket.socket(); sys.exit(0 if s.connect_ex(('127.0.0.1',$api_port))==0 else 1)"; then
        api_ready=true
        break
    fi
    sleep 0.1
done
[[ "$api_ready" == true ]] || fail "fixture API server 未就绪"
export SKILLS_API_BASE="http://127.0.0.1:$api_port"

install_fixture_skill_dir() {
    local name="$1"
    mkdir -p "$AGENTS_TARGET_DIR/$name"
    printf '%s\n' '---' "name: $name" 'description: test' '---' > "$AGENTS_TARGET_DIR/$name/SKILL.md"
}

# lock：两个 skill 都已安装（含 skillPath + skillFolderHash）
write_fixture_lock() {
    mkdir -p "$HOME/.agents"
    cat > "$SKILLS_LOCK_FILE" <<EOF
{
  "version": 3,
  "skills": {
    "grilling": {
      "source": "mattpocock/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/mattpocock/skills.git",
      "skillPath": "skills/productivity/grilling/SKILL.md",
      "skillFolderHash": "$GRILLING_HASH"
    },
    "humanizer": {
      "source": "blader/humanizer",
      "sourceType": "github",
      "sourceUrl": "https://github.com/blader/humanizer.git",
      "skillPath": "SKILL.md",
      "skillFolderHash": "$HUMANIZER_OLD"
    }
  }
}
EOF
}

install_fixture_skill_dir grilling
install_fixture_skill_dir humanizer
write_fixture_lock

# source setup.sh，覆盖 REPO_ROOT 指向 fixture
source "$REAL_REPO_ROOT/setup.sh"
REPO_ROOT="$fixture/repo"
SKILLS_CONFIG="$REPO_ROOT/configs/skills.toml"
PLUGINS_CONFIG="$REPO_ROOT/configs/plugins.toml"
RESOURCE_PLANNER="$REAL_REPO_ROOT/script/resource-plan.py"
MANIFEST_PARSER="$REAL_REPO_ROOT/script/parse-manifests.py"
SKILL_FRESHNESS_CHECK="$REAL_REPO_ROOT/script/check-skill-freshness.py"

DRY_RUN=false; CI_MODE=false; FORCE=false; VERBOSE=true
SELECTED_SKILLS=(); UPDATE_RESOURCES=()
AGENTS_TARGET="claude-code"

# ---- 1) 最新版比对：grilling 最新跳过，humanizer 有新版重装 ----
: > "$EXEC_LOG"
AGENTS_TARGET="universal"
install_external_skills >"$fixture/out1" 2>&1
[[ "$(grep -c '^npx ' "$EXEC_LOG")" -eq 1 ]] || \
    fail "应只重装 1 个（humanizer）: $(<"$EXEC_LOG")"
grep -q 'add -y blader/humanizer -s humanizer -a universal -g' "$EXEC_LOG" || \
    fail "humanizer 应带 -a universal -g: $(<"$EXEC_LOG")"
grep -q 'mattpocock/skills' "$EXEC_LOG" && fail "最新的 grilling 不应重装: $(<"$EXEC_LOG")"
grep -q "已是最新，跳过 1 个 skill: grilling" "$fixture/out1" || \
    fail "grilling 应报跳过: $(<"$fixture/out1")"
pass "最新版比对：最新的跳过、有更新的重装"

# ---- 2) 目标目录缺失：lock 有记录但目录没了 → 重装 ----
: > "$EXEC_LOG"
rm -rf "$AGENTS_TARGET_DIR/grilling"
install_external_skills >"$fixture/out2" 2>&1
grep -q 'add -y mattpocock/skills -s grilling -a universal -g' "$EXEC_LOG" || \
    fail "目录缺失的 grilling 应重装: $(<"$EXEC_LOG")"
grep -q "skill 'grilling' 未安装" "$fixture/out2" || fail "应报未安装: $(<"$fixture/out2")"
pass "目标目录缺失：判定为未安装并重装"

# ---- 3) 全量（非 claude）：外部 -a universal，仓库自有 symlink 到 ~/.agents/skills ----
: > "$EXEC_LOG"
rm -rf "$AGENTS_TARGET_DIR/grilling" "$AGENTS_TARGET_DIR/humanizer"
rm -f "$SKILLS_LOCK_FILE"
AGENTS_TARGET="pi"
run_agents_flow
[[ "$(grep -c 'add -y .* -a universal -g' "$EXEC_LOG")" -eq 2 ]] || \
    fail "全量外部应调用 2 次 npx add -a universal -g: $(<"$EXEC_LOG")"
grep -q 'add -y mattpocock/skills -s grilling -a universal -g' "$EXEC_LOG" || \
    fail "grilling 缺 -a universal -g"
grep -q 'add -y blader/humanizer -s humanizer -a universal -g' "$EXEC_LOG" || \
    fail "humanizer 缺 -a universal -g"
[[ -L "$AGENTS_TARGET_DIR/local-one" ]] || fail "local-one 未 symlink 到 ~/.agents/skills"
[[ -L "$AGENTS_TARGET_DIR/local-two" ]] || fail "local-two 未 symlink 到 ~/.agents/skills"
[[ -e "$CLAUDE_HOME/skills/local-one" ]] && fail "不应写 ~/.claude/skills"
grep -q 'claude ' "$EXEC_LOG" && fail "非 claude 模式不应调用 claude: $(<"$EXEC_LOG")"
pass "全量安装：外部 -a universal + 仓库自有 symlink 到 ~/.agents/skills"

# ---- 4) 指定外部 skill：只装 grilling，跳过仓库自有 ----
: > "$EXEC_LOG"
AGENTS_TARGET="universal"
SELECTED_SKILLS=(grilling)
UPDATE_RESOURCES=()
rm -f "$AGENTS_TARGET_DIR/local-one" "$AGENTS_TARGET_DIR/local-two"
run_agents_flow
[[ "$(grep -c '^npx ' "$EXEC_LOG")" -eq 1 ]] || fail "指定外部只应调用 1 次 npx: $(<"$EXEC_LOG")"
grep -q 'add -y mattpocock/skills -s grilling -a universal -g' "$EXEC_LOG" || fail "应装 grilling"
[[ -L "$AGENTS_TARGET_DIR/local-one" ]] && fail "指定外部时不应装仓库自有 local-one"
pass "指定外部 skill：只装指定项"

# ---- 5) 指定仓库自有 skill：只装它，跳过外部 ----
: > "$EXEC_LOG"
AGENTS_TARGET="codex"
SELECTED_SKILLS=()
UPDATE_RESOURCES=(skill:local-two)
run_agents_flow
[[ -s "$EXEC_LOG" ]] && fail "指定本地时不应调用外部 npx: $(<"$EXEC_LOG")"
[[ -L "$AGENTS_TARGET_DIR/local-two" ]] || fail "应装仓库自有 local-two"
[[ -L "$AGENTS_TARGET_DIR/local-one" ]] && fail "指定 local-two 时不应装 local-one"
pass "指定仓库自有 skill：只装指定项（任意非 claude 取值同落点）"

# ---- 6) 幂等：全量重跑时已就绪且最新的 skill 被跳过 ----
: > "$EXEC_LOG"
AGENTS_TARGET="universal"
SELECTED_SKILLS=(); UPDATE_RESOURCES=()
install_fixture_skill_dir grilling
install_fixture_skill_dir humanizer
write_fixture_lock
install_external_skills >"$fixture/out6" 2>&1
grep -q "已是最新，跳过 1 个 skill: grilling" "$fixture/out6" || \
    fail "grilling 应报跳过: $(<"$fixture/out6")"
grep -q 'mattpocock/skills' "$EXEC_LOG" && fail "grilling 不应重装: $(<"$EXEC_LOG")"
pass "幂等：已就绪且最新的 skill 再次运行被跳过"

# ---- 7) 远端不可达：unknown 仍安装（绝不因查不到就误跳过）----
: > "$EXEC_LOG"
SKILLS_API_BASE="http://127.0.0.1:1"
install_external_skills >"$fixture/out7" 2>&1
SKILLS_API_BASE="http://127.0.0.1:$api_port"
[[ "$(grep -c '^npx ' "$EXEC_LOG")" -eq 2 ]] || \
    fail "远端不可达时应照常安装全部: $(<"$EXEC_LOG")"
grep -q '无法比对远端版本' "$fixture/out7" || fail "缺少无法比对提示: $(<"$fixture/out7")"
pass "远端不可达：unknown 照常安装"

# ---- 8) --force：跳过比对，全部重装 ----
: > "$EXEC_LOG"
FORCE=true
install_external_skills >"$fixture/out8" 2>&1
FORCE=false
[[ "$(grep -c '^npx ' "$EXEC_LOG")" -eq 2 ]] || fail "--force 应重装全部: $(<"$EXEC_LOG")"
pass "--force：忽略比对，全部重装"

# ---- 9) DRY-RUN：显示 -a universal -g 且不调用 npx ----
: > "$EXEC_LOG"
DRY_RUN=true
install_external_skills >"$fixture/out9" 2>&1
DRY_RUN=false
[[ -s "$EXEC_LOG" ]] && fail "DRY-RUN 不应调用 npx: $(<"$EXEC_LOG")"
grep -q -- '-a universal -g' "$fixture/out9" || fail "DRY-RUN 应显示 -a universal -g"
pass "DRY-RUN：只预览不安装"
# ---- 10) CLI 级：非 claude 目标与 update/uninstall 参数冲突被拒 ----
set +e
HOME="$fixture/home" PATH="$fixture/bin:$PATH" \
  bash "$REAL_REPO_ROOT/setup.sh" --agents=codex --update-all >"$fixture/out10" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "--agents=codex --update-all 应被拒，实际 exit 0"
grep -q "不支持 update/uninstall" "$fixture/out10" || fail "拒绝信息缺失: $(<"$fixture/out10")"
pass "CLI: 非 claude 目标拒绝 update/uninstall 参数"

# ---- 11) CLI 级：--agents=claude 仍是完整 claude 流程（不被截胡）----
set +e
HOME="$fixture/home" PATH="$fixture/bin:$PATH" \
  bash "$REAL_REPO_ROOT/setup.sh" --agents=claude --update-all --dry-run >"$fixture/out11" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "--agents=claude --dry-run 应走 claude 流程，实际 exit $rc: $(<"$fixture/out11")"
grep -q "不支持 update/uninstall" "$fixture/out11" && fail "--agents=claude 不应被截胡"
pass "CLI: --agents=claude 保持完整 claude 流程"

# ---- 12) CLI 级：非 claude 目标 --dry-run 全量走通，显示 -a universal -g ----
set +e
HOME="$fixture/home" PATH="$fixture/bin:$PATH" \
  bash "$REAL_REPO_ROOT/setup.sh" --agents=universal --dry-run --ci >"$fixture/out12" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "--agents=universal --dry-run 应成功，实际 exit $rc: $(<"$fixture/out12")"
grep -q -- '-a universal -g' "$fixture/out12" || fail "dry-run 应显示 -a universal -g"
grep -q 'Agents skills 安装完成' "$fixture/out12" || fail "缺少完成横幅"
grep -q -- '--agents=universal' "$fixture/out12" || fail "缺少 --agents=universal 标识"
pass "CLI: 非 claude 目标 --dry-run 全量流程"

# ---- 并行安装相关的 fixture：多仓库清单 + 并发度测量 ----
# fake npx 模拟真实 CLI 的 lock 读-改-写（读→sleep→写）：若多个 worker 共写同一 lock，
# 后写者会覆盖先写者（真实实测 4 并行只剩 3 条），合并后条目数即可暴露该缺陷。
SKILL_LOCK_MERGER="$REAL_REPO_ROOT/script/merge-skill-locks.py"

mkdir -p "$fixture/repo-par/configs"
cat > "$fixture/repo-par/configs/skills.toml" <<'TOML'
[[sources]]
name = "alpha"
repo = "org-a/repo-a"
skill = "alpha"
agent = "claude-code"
scope = "global"

[[sources]]
name = "beta"
repo = "org-b/repo-b"
skill = "beta"
agent = "claude-code"
scope = "global"

[[sources]]
name = "gamma"
repo = "org-c/repo-c"
skill = "gamma"
agent = "claude-code"
scope = "global"

[[sources]]
name = "delta"
repo = "org-d/repo-d"
skill = "delta"
agent = "claude-code"
scope = "global"
TOML

# 解析 start/end 打点（按 pid 配对），打印最大并发数
max_concurrency() {
    python3 - "$1" <<'PY'
import sys

starts, intervals = {}, []
with open(sys.argv[1], encoding="utf-8") as fp:
    for line in fp:
        parts = line.split()
        if len(parts) != 3:
            continue
        kind, pid, ms = parts[0], parts[1], int(parts[2])
        if kind == "start":
            starts[pid] = ms
        elif kind == "end" and pid in starts:
            intervals.append((starts.pop(pid), ms))
points = []
for begin, end in intervals:
    points += [(begin, 1), (end, -1)]
points.sort()
cur = peak = 0
for _, delta in points:
    cur += delta
    peak = max(peak, cur)
print(peak)
PY
}

reset_parallel_case() {
    SKILLS_CONFIG="$fixture/repo-par/configs/skills.toml"
    AGENTS_TARGET="universal"
    SELECTED_SKILLS=(); UPDATE_RESOURCES=()
    FORCE=true
    export FAKE_NPX_LOCK=1 FAKE_NPX_DELAY=0.3
    export FAKE_NPX_INTERVAL_LOG="$fixture/intervals"
    : > "$EXEC_LOG"
    : > "$FAKE_NPX_INTERVAL_LOG"
}

lock_skill_names() {
    python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fp:
    print(" ".join(sorted(json.load(fp).get("skills", {}))))
' "$SKILLS_LOCK_FILE" 2>/dev/null || echo "(no lock)"
}

# ---- 13) 并发安装：4 组并行（默认 SKILLS_INSTALL_JOBS=3），lock 合并后无丢失 ----
reset_parallel_case
rm -f "$SKILLS_LOCK_FILE"
install_external_skills >"$fixture/out13" 2>&1
[[ "$(grep -c '^npx ' "$EXEC_LOG")" -eq 4 ]] || fail "应调用 4 次 npx: $(<"$EXEC_LOG")"
[[ "$(lock_skill_names)" == "alpha beta delta gamma" ]] || \
    fail "并行安装后 lock 条目不全: $(lock_skill_names)"
peak="$(max_concurrency "$FAKE_NPX_INTERVAL_LOG")"
[[ "$peak" -ge 2 ]] || fail "应观察到并发（峰值 $peak），实为串行"
pass "并行安装：多组并发执行，lock 合并后 4 条齐全（峰值 $peak）"

# ---- 14) 并发度可调：SKILLS_INSTALL_JOBS=1 时退化为串行 ----
reset_parallel_case
rm -f "$SKILLS_LOCK_FILE"
old_jobs="$SKILLS_INSTALL_JOBS"
SKILLS_INSTALL_JOBS=1
install_external_skills >"$fixture/out14" 2>&1
SKILLS_INSTALL_JOBS="$old_jobs"
[[ "$(max_concurrency "$FAKE_NPX_INTERVAL_LOG")" -eq 1 ]] || \
    fail "SKILLS_INSTALL_JOBS=1 应串行: $(max_concurrency "$FAKE_NPX_INTERVAL_LOG")"
[[ "$(lock_skill_names)" == "alpha beta delta gamma" ]] || \
    fail "串行模式 lock 条目不全: $(lock_skill_names)"
pass "并发度可调：SKILLS_INSTALL_JOBS=1 退化为串行"

# ---- 15) 同仓库多 skill 合并为一次 add（一次 clone、一次 lock 写入）----
reset_parallel_case
SKILLS_CONFIG="$fixture/repo/configs/skills-grouped.toml"
cat > "$SKILLS_CONFIG" <<'TOML'
[[sources]]
name = "grill-me"
repo = "mattpocock/skills"
skill = "grill-me"
agent = "claude-code"
scope = "global"

[[sources]]
name = "grilling"
repo = "mattpocock/skills"
skill = "grilling"
agent = "claude-code"
scope = "global"
TOML
rm -f "$SKILLS_LOCK_FILE"
install_external_skills >"$fixture/out15" 2>&1
[[ "$(grep -c '^npx ' "$EXEC_LOG")" -eq 1 ]] || \
    fail "同仓库多 skill 应合并为 1 次 add: $(<"$EXEC_LOG")"
grep -q -- '-s grill-me' "$EXEC_LOG" || fail "合并调用缺 -s grill-me: $(<"$EXEC_LOG")"
grep -q -- '-s grilling' "$EXEC_LOG" || fail "合并调用缺 -s grilling: $(<"$EXEC_LOG")"
[[ "$(lock_skill_names)" == "grill-me grilling" ]] || \
    fail "合并安装 lock 条目不全: $(lock_skill_names)"
grep -q "skill 'grilling' 已安装" "$fixture/out15" || fail "缺少安装成功汇报"
grep -q "skill 'grill-me' 已安装" "$fixture/out15" || fail "缺少安装成功汇报"
pass "同仓库多 skill：合并为一次 add，逐项汇报"

# ---- 16) 失败隔离：一组失败不阻塞其它组，整体 rc=1 ----
reset_parallel_case
rm -f "$SKILLS_LOCK_FILE"
export FAKE_NPX_FAIL_REPO="org-b/repo-b"
set +e
install_external_skills >"$fixture/out16" 2>&1
rc16=$?
set -e
unset FAKE_NPX_FAIL_REPO
[[ "$rc16" -ne 0 ]] || fail "有组失败时 rc 应为非 0，实际 $rc16"
grep -q "外部 skill 安装失败: beta" "$fixture/out16" || \
    fail "失败组未点名: $(<"$fixture/out16")"
[[ "$(lock_skill_names)" == "alpha delta gamma" ]] || \
    fail "失败组不应污染其它组结果: $(lock_skill_names)"
pass "失败隔离：失败组 rc=1，其它组照常安装并入 lock"

# ---- 17) lock 合并：既有条目与顶层字段不被覆盖 ----
reset_parallel_case
mkdir -p "$HOME/.agents"
cat > "$SKILLS_LOCK_FILE" <<'EOF'
{
  "version": 3,
  "lastSelectedAgents": ["universal"],
  "skills": {
    "unrelated": {
      "source": "someone/else",
      "skillFolderHash": "keep-me"
    }
  }
}
EOF
install_external_skills >"$fixture/out17" 2>&1
[[ "$(lock_skill_names)" == "alpha beta delta gamma unrelated" ]] || \
    fail "合并应保留既有条目: $(lock_skill_names)"
python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fp:
    data = json.load(fp)
assert data["skills"]["unrelated"]["skillFolderHash"] == "keep-me", "既有条目被覆盖"
assert data["lastSelectedAgents"] == ["universal"], "顶层字段被覆盖"
' "$SKILLS_LOCK_FILE" || fail "合并破坏了既有 lock 内容"
pass "lock 合并：保留既有条目与顶层字段，仅覆盖本次安装项"

# ---- 18) 跨仓库重名：只保留首个并告警（同名并发写同一目录是数据竞争）----
reset_parallel_case
SKILLS_CONFIG="$fixture/repo-par/configs/skills.toml"
cat > "$SKILLS_CONFIG" <<'TOML'
[[sources]]
name = "dup-first"
repo = "org-a/repo-a"
skill = "dup-skill"
agent = "claude-code"
scope = "global"

[[sources]]
name = "dup-second"
repo = "org-b/repo-b"
skill = "dup-skill"
agent = "claude-code"
scope = "global"
TOML
rm -f "$SKILLS_LOCK_FILE"
install_external_skills >"$fixture/out18" 2>&1
[[ "$(grep -c '^npx ' "$EXEC_LOG")" -eq 1 ]] || \
    fail "重名 skill 应只安装一次: $(<"$EXEC_LOG")"
grep -q 'add -y org-a/repo-a -s dup-skill' "$EXEC_LOG" || \
    fail "应保留首个声明: $(<"$EXEC_LOG")"
grep -q "skill 'dup-skill' 已被其它 source 声明" "$fixture/out18" || \
    fail "缺少重名告警: $(<"$fixture/out18")"
pass "跨仓库重名：保留首个并告警，避免并发写同一目录"

# 复原：后续若继续追加用例，按真实默认值走
FORCE=false
SKILLS_CONFIG="$fixture/repo/configs/skills.toml"
unset FAKE_NPX_LOCK FAKE_NPX_DELAY FAKE_NPX_INTERVAL_LOG

echo "All agents-skills tests passed."
