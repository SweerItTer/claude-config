#!/usr/bin/env bash
# Tests for script/launch/manifest.py — TOML manifest loader (absorbed from
# parse-manifests.py). Bash wrapper driving the module's API + self-check.
#
# Covers: real-manifest parsing (both skills + plugins), missing-file → empty,
# schema validation failures, the Python 3.10 fallback path (no tomllib), and
# local_skill_names().
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

python3 -m py_compile "$REPO_ROOT/script/launch/manifest.py"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# 模块自带 __main__ assert 自检（真实清单 + 手写解析器与 tomllib 交叉验证）
python3 "$REPO_ROOT/script/launch/manifest.py" || fail "manifest 自检失败"

# --- API 级断言：真实清单 + 缺失文件 + 校验失败 ---
python3 - "$REPO_ROOT" <<'PYEOF'
import subprocess
import sys
import tempfile
from pathlib import Path

repo = Path(sys.argv[1])
sys.path.insert(0, str(repo / "script"))
from launch.manifest import ManifestError, load_plugins, load_skills, local_skill_names

# 真实 skills.toml
skills = load_skills(repo / "configs" / "skills.toml")
assert len(skills) >= 3, skills
by_name = {s.name: s for s in skills}
assert by_name["grilling"].repo == "mattpocock/skills"
assert by_name["grilling"].skill == "grilling"
assert by_name["grilling"].agent == "claude-code"
assert by_name["grilling"].scope == "global"
assert by_name["diagram-design"].repo == "cathrynlavery/diagram-design"
print("PASS: skills.toml 解析（含 grilling/diagram-design 条目）")

# 真实 plugins.toml
plugins = load_plugins(repo / "configs" / "plugins.toml")
assert plugins, "plugins.toml 不应为空"
by_name = {p.name: p for p in plugins}
assert by_name["superpowers"].method == "claude-plugin"
assert by_name["superpowers"].marketplace == "superpowers-dev"
assert by_name["CodeGraph"].method == "npx"
assert by_name["CodeGraph"].command == "npm i -g @colbymchenry/codegraph"
assert by_name["OpenSpec"].method == "npx"
print("PASS: plugins.toml 解析（superpowers marketplace / CodeGraph+OpenSpec npx）")

# 文件缺失 → 空列表（不抛异常）
assert load_skills(Path("/nonexistent/skills.toml")) == []
assert load_plugins(Path("/nonexistent/plugins.toml")) == []
print("PASS: 清单文件缺失返回空列表")

# 缺必填字段 → ManifestError
with tempfile.TemporaryDirectory() as tmp:
    bad = Path(tmp) / "bad.toml"
    bad.write_text('[[sources]]\nname = "missing-repo"\n', encoding="utf-8")
    try:
        load_skills(bad)
        raise AssertionError("缺 repo 应报错")
    except ManifestError:
        pass
    print("PASS: 缺必填字段报错")

    # 未知 method → ManifestError
    bad.write_text('[[plugins]]\nname = "x"\nrepo = "owner/x"\nmethod = "unknown-method"\n',
                   encoding="utf-8")
    try:
        load_plugins(bad)
        raise AssertionError("未知 method 应报错")
    except ManifestError:
        pass
    print("PASS: 未知 method 报错")

    # 空清单（只有注释，无任何 [[sources]] 表）→ 空列表，不报错
    empty = Path(tmp) / "empty.toml"
    empty.write_text('# 空清单：只有注释\n# [[sources]]\n# name = "x"\n', encoding="utf-8")
    assert load_skills(empty) == []
    print("PASS: 空清单（纯注释）解析为空列表")

    # 3.10 回退路径：无 tomllib 时手写解析器与 tomllib 结果一致（有 tomllib 时交叉验证）
    mixed = Path(tmp) / "mixed.toml"
    mixed.write_text('[[sources]]\nname = "a"\nrepo = "o/r"\nskill = "a"\n', encoding="utf-8")
    try:
        import tomllib
        ref = tomllib.loads(mixed.read_text(encoding="utf-8"))
        sys.path.insert(0, str(repo / "script" / "launch"))
        import manifest as m
        assert m._parse_subset_toml(mixed.read_text(encoding="utf-8")) == ref
        print("PASS: 3.10 手写解析器与 tomllib 结果一致")
    except ModuleNotFoundError:
        # 本机无 tomllib：load_skills 本身就在走手写路径（上面已验证行为）
        print("PASS: 当前解释器无 tomllib，手写路径即主路径")

# local_skill_names：真实仓库非空、排序、跳过无 SKILL.md 目录
names = local_skill_names(repo)
assert names == sorted(names) and len(names) > 0
assert "git-workflow" in names
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    assert local_skill_names(root) == []
    (root / "skills" / "ok").mkdir(parents=True)
    (root / "skills" / "ok" / "SKILL.md").write_text("---\nname: ok\n---\n", encoding="utf-8")
    (root / "skills" / ".hidden").mkdir()
    (root / "skills" / "nofile").mkdir()
    assert local_skill_names(root) == ["ok"]
print("PASS: local_skill_names（排序/隐藏目录/缺 SKILL.md）")

PYEOF

echo "All manifest parsing tests passed."
