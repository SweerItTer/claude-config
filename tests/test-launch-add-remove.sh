#!/usr/bin/env bash
# Tests for launch add/remove subcommands (script/launch/cli.py).
# Sandbox: mktemp HOME + LAUNCH_REPO_ROOT/XDG_STATE_HOME/CLAUDE_CONFIG_DIR/AGENTS_SKILLS_HOME
# 全路径 dry-run 无副作用（toml byte 不变）+ 假 repo 失败路径 + 冲突名路径。
# 真实 npx 试装（网络）不在 CI 断言范围。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

python3 -m py_compile "$REAL_REPO/script/launch/cli.py" \
    || { echo "FAIL: compileall cli"; exit 1; }

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# 模块自带 __main__ assert 自检（parser/块删除/追加/转义往返）
python3 "$REAL_REPO/script/launch/cli.py" || fail "cli 自检失败"

# --- 沙箱 dry-run 全路径无副作用 ---
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
export LAUNCH_REPO_ROOT="$SBX/repo"
export CLAUDE_CONFIG_DIR="$SBX/claude"
export AGENTS_SKILLS_HOME="$SBX/agents-skills"
export XDG_STATE_HOME="$SBX/state"
export NO_COLOR=1
mkdir -p "$SBX/repo/configs" "$SBX/repo/skills/demo"
printf '# [[sources]]\n# name = "demo-local"\n' > /dev/null
cat "$REAL_REPO/configs/skills.toml" > "$SBX/repo/configs/skills.toml"
printf -- '---\nname: demo\n---\n# demo\n' > "$SBX/repo/skills/demo/SKILL.md"

BEFORE="$(md5sum "$SBX/repo/configs/skills.toml" | cut -d' ' -f1)"

# dry-run add：校验 + 预览，不装不写
out="$("$REAL_REPO/launch" --dry-run --no-color add owner/repo someskill 2>&1)" \
    || fail "dry-run add 应退出 0: $out"
echo "$out" | grep -q "skills@latest" || fail "dry-run add 应打印试装命令: $out"
echo "$out" | grep -q '\[\[sources\]\]' || fail "dry-run add 应预览 toml 块: $out"
AFTER="$(md5sum "$SBX/repo/configs/skills.toml" | cut -d' ' -f1)"
[ "$BEFORE" = "$AFTER" ] || fail "dry-run add 改动了 skills.toml"

# dry-run remove：预览卸载与删块，无副作用
out="$("$REAL_REPO/launch" --dry-run --no-color remove grilling 2>&1)" \
    || fail "dry-run remove 应退出 0: $out"
echo "$out" | grep -q "卸载 skill: grilling" || fail "dry-run remove 应预览卸载: $out"
AFTER="$(md5sum "$SBX/repo/configs/skills.toml" | cut -d' ' -f1)"
[ "$BEFORE" = "$AFTER" ] || fail "dry-run remove 改动了 skills.toml"

# --- add repo 格式错误 → rc=2，toml 不动 ---
rc=0
"$REAL_REPO/launch" --no-color add badrepo someskill 2>"$SBX/err" || rc=$?
[ "$rc" -eq 2 ] || fail "add 缺斜杠应退出 2, 实际 $rc"
grep -q "owner/name" "$SBX/err" || fail "add 格式报错缺提示: $(cat "$SBX/err")"
AFTER="$(md5sum "$SBX/repo/configs/skills.toml" | cut -d' ' -f1)"
[ "$BEFORE" = "$AFTER" ] || fail "add 格式错误却改动了 skills.toml"

# --- add 名字冲突 → rc=1，toml 不动（用现有 manifest 名 grilling）---
rc=0
"$REAL_REPO/launch" --no-color add owner/repo grilling 2>"$SBX/err" || rc=$?
[ "$rc" -eq 1 ] || fail "add 冲突名应退出 1, 实际 $rc"
grep -q "同名" "$SBX/err" || fail "add 冲突报错缺提示: $(cat "$SBX/err")"
AFTER="$(md5sum "$SBX/repo/configs/skills.toml" | cut -d' ' -f1)"
[ "$BEFORE" = "$AFTER" ] || fail "add 冲突却改动了 skills.toml"

# --- 假 repo 真装失败 → rc=1，toml 不动（npx 对不存在仓库报错；无网环境同样失败路径）---
rc=0
"$REAL_REPO/launch" --no-color add not-exist-zzz/no-such-repo-xyz somefake 2>"$SBX/err" || rc=$?
[ "$rc" -eq 1 ] || fail "add 假 repo 应退出 1, 实际 $rc"
grep -q "试装失败" "$SBX/err" || fail "add 试装失败报错缺提示: $(cat "$SBX/err")"
AFTER="$(md5sum "$SBX/repo/configs/skills.toml" | cut -d' ' -f1)"
[ "$BEFORE" = "$AFTER" ] || fail "add 试装失败却改动了 skills.toml"

# --- remove 不存在名 → rc=1 并列出合法名 ---
rc=0
"$REAL_REPO/launch" --no-color remove no-such-skill-xyz 2>"$SBX/err" || rc=$?
[ "$rc" -eq 1 ] || fail "remove 不存在名应退出 1, 实际 $rc"
grep -q "合法名" "$SBX/err" || fail "remove 缺合法名提示: $(cat "$SBX/err")"

# --- 块删除纯逻辑：临时 toml 上验证删块不改注释、toml 重载一致 ---
python3 - "$REAL_REPO" "$SBX" <<'PYEOF' || fail "块删除断言失败"
import sys
sys.path.insert(0, sys.argv[1] + "/script")
from pathlib import Path
from launch.cli import _remove_source_blocks, _append_source
from launch.manifest import load_skills, SkillSource

cfg = Path(sys.argv[2]) / "block.toml"
cfg.write_text(
    "# 头注释\n"
    "[[sources]]\n"
    'name = "grilling"\n'
    'repo = "m/s"\n'
    "\n"
    "[[sources]]\n"
    'name = "wayfinder"\n'
    'repo = "m/s"\n',
    encoding="utf-8")
removed, malformed = _remove_source_blocks(cfg, ["grilling"])
assert (removed, malformed) == (1, 0), (removed, malformed)
text = cfg.read_text(encoding="utf-8")
assert "# 头注释" in text and 'name = "wayfinder"' in text and "grilling" not in text
assert [s.name for s in load_skills(cfg)] == ["wayfinder"]
_append_source(cfg, SkillSource(name="grilling", repo="m/s", skill="grilling",
                                agent="claude-code", scope="global"))
assert [s.name for s in load_skills(cfg)] == ["wayfinder", "grilling"]
print("block edit ok")
PYEOF

echo "test-launch-add-remove passed."
