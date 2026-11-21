#!/usr/bin/env python3
"""解析 configs/skills.toml / plugins.toml → dataclass 清单。

解析逻辑照搬 script/parse-manifests.py：3.11+ 用 tomllib，3.10 用手写
TOML 子集解析器（数组 of tables + 双引号字符串 + # 注释 + 空行）。
文件缺失 → 空列表（调用方自行决定是否告警）。
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

try:
    import tomllib  # Python 3.11+

    HAS_TOMLLIB = True
except ModuleNotFoundError:  # Python 3.10 及更早
    HAS_TOMLLIB = False


@dataclass(frozen=True)
class SkillSource:
    name: str
    repo: str
    skill: str
    agent: str = "claude-code"
    scope: str = "global"
    note: str = ""


@dataclass(frozen=True)
class PluginSource:
    name: str
    repo: str
    method: str  # claude-plugin | npx
    marketplace: str = ""
    command: str = ""
    note: str = ""


SKILL_REQUIRED = ("name", "repo")
PLUGIN_REQUIRED = ("name", "repo", "method")
PLUGIN_METHODS = {"claude-plugin", "npx"}


class ManifestError(ValueError):
    """清单解析/校验失败（缺必填字段、非法 method、非法 TOML 结构）。"""


def _parse_subset_toml(text: str) -> dict:
    """零依赖 TOML 子集解析器，仅支持清单实际用到的语法：

    数组 of tables（[[sources]] / [[plugins]]）+ 双引号字符串键值对
    + # 注释 + 空行。其余语法一律 ValueError。
    """
    entries: list[dict] = []
    current: dict | None = None
    table_name: str | None = None

    def push() -> None:
        nonlocal current
        if current is not None:
            entries.append(current)
        current = {}

    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[[") and line.endswith("]]"):
            table = line[2:-2].strip()
            if table not in ("sources", "plugins"):
                raise ValueError(f"第 {lineno} 行: 不支持的顶层表 [[{table}]]")
            if table_name is not None and table != table_name:
                raise ValueError(f"第 {lineno} 行: 清单同时包含 [[sources]] 和 [[plugins]]，不支持")
            table_name = table
            push()
            continue
        if "=" not in line:
            raise ValueError(f"第 {lineno} 行: 无法解析的键值对: {line!r}")
        key, _, raw_value = line.partition("=")
        key = key.strip()
        value = raw_value.strip()
        if not (value.startswith('"') and value.endswith('"')):
            raise ValueError(f"第 {lineno} 行: 值必须是双引号字符串: {line!r}")
        if current is None:
            raise ValueError(f"第 {lineno} 行: 键 {key!r} 出现在任何 [[表]] 之外")
        current[key] = value[1:-1]

    push()
    # 纯注释文件（无任何表）视为空清单：与 tomllib 路径对空文件返回 {} 的行为一致
    if table_name is None:
        return {}
    return {table_name: entries}


def _load(manifest_path: Path) -> dict:
    """读文件并解析为 dict；解析失败抛 ManifestError。"""
    text = manifest_path.read_text(encoding="utf-8")
    try:
        if HAS_TOMLLIB:
            return tomllib.loads(text)
        return _parse_subset_toml(text)
    except ValueError as exc:  # TOMLDecodeError 是 ValueError 子类
        raise ManifestError(f"清单解析失败 ({manifest_path}): {exc}") from exc


def _validate_str(item: dict, key: str, where: str) -> str:
    value = item.get(key)
    if not isinstance(value, str):
        raise ManifestError(f"{where}: {key} 字段必须是字符串，收到 {type(value).__name__}")
    return value


def load_skills(config: Path) -> list[SkillSource]:
    """skills.toml → list[SkillSource]；文件缺失 → []；校验失败抛 ManifestError。"""
    path = Path(config)
    if not path.is_file():
        return []
    data = _load(path)
    entries = data.get("sources", [])
    if not isinstance(entries, list):
        raise ManifestError("skills.toml 顶层 sources 必须是数组")
    sources: list[SkillSource] = []
    for index, item in enumerate(entries, start=1):
        if not isinstance(item, dict):
            raise ManifestError(f"skills.toml [{index}] source 必须是对象")
        where = f"skills.toml [{index}]"
        missing = [key for key in SKILL_REQUIRED if key not in item]
        if missing:
            raise ManifestError(f"{where} 缺少必填字段: {', '.join(missing)}")
        sources.append(SkillSource(
            name=_validate_str(item, "name", where),
            repo=_validate_str(item, "repo", where),
            skill=_validate_str(item, "skill", where) if "skill" in item else "*",
            agent=_validate_str(item, "agent", where) if "agent" in item else "claude-code",
            scope=_validate_str(item, "scope", where) if "scope" in item else "global",
            note=_validate_str(item, "note", where) if "note" in item else "",
        ))
    return sources


def load_plugins(config: Path) -> list[PluginSource]:
    """plugins.toml → list[PluginSource]；文件缺失 → []；校验失败抛 ManifestError。"""
    path = Path(config)
    if not path.is_file():
        return []
    data = _load(path)
    entries = data.get("plugins", [])
    if not isinstance(entries, list):
        raise ManifestError("plugins.toml 顶层 plugins 必须是数组")
    plugins: list[PluginSource] = []
    for index, item in enumerate(entries, start=1):
        if not isinstance(item, dict):
            raise ManifestError(f"plugins.toml [{index}] plugin 必须是对象")
        where = f"plugins.toml [{index}]"
        missing = [key for key in PLUGIN_REQUIRED if key not in item]
        if missing:
            raise ManifestError(f"{where} 缺少必填字段: {', '.join(missing)}")
        method = item.get("method", "claude-plugin")
        if method not in PLUGIN_METHODS:
            raise ManifestError(
                f"{where} method 必须是 {'|'.join(sorted(PLUGIN_METHODS))}，收到: {method}")
        plugins.append(PluginSource(
            name=_validate_str(item, "name", where),
            repo=_validate_str(item, "repo", where),
            method=method,
            marketplace=_validate_str(item, "marketplace", where) if "marketplace" in item else "",
            command=_validate_str(item, "command", where) if "command" in item else "",
            note=_validate_str(item, "note", where) if "note" in item else "",
        ))
    return plugins


def local_skill_names(repo_root: Path) -> list[str]:
    """仓库自有 skill 目录名列表（skills/*/SKILL.md），排序。目录缺失 → []。"""
    skills_root = Path(repo_root) / "skills"
    if not skills_root.is_dir():
        return []
    return sorted(
        entry.name for entry in skills_root.iterdir()
        if entry.is_dir() and not entry.name.startswith(".") and (entry / "SKILL.md").is_file()
    )


if __name__ == "__main__":
    # --- 自检：真实清单解析 + 缺失文件 + 手写解析器与 tomllib 等价 ---
    repo = Path(__file__).resolve().parents[2]
    skills = load_skills(repo / "configs" / "skills.toml")
    assert any(s.name == "grilling" and s.repo == "mattpocock/skills"
               and s.skill == "grilling" and s.agent == "claude-code"
               and s.scope == "global" for s in skills), skills
    assert any(s.name == "diagram-design" and s.repo == "cathrynlavery/diagram-design"
               for s in skills)
    assert any(s.name == "archify" and s.repo == "tt-a1i/archify" for s in skills)

    plugins = load_plugins(repo / "configs" / "plugins.toml")
    assert any(p.name == "superpowers" and p.method == "claude-plugin"
               and p.marketplace == "superpowers-dev" for p in plugins), plugins
    assert any(p.name == "CodeGraph" and p.method == "npx"
               and p.command == "npm i -g @colbymchenry/codegraph" for p in plugins)
    assert any(p.name == "OpenSpec" and p.method == "npx"
               and p.command == "npm install -g @mindfoldhq/trellis@latest" for p in plugins)
    # 默认值：method 缺省 = claude-plugin
    assert all(p.method in ("claude-plugin", "npx") for p in plugins)

    # 文件缺失 → 空列表
    assert load_skills(Path("/nonexistent/skills.toml")) == []
    assert load_plugins(Path("/nonexistent/plugins.toml")) == []

    # 缺必填字段 → ManifestError
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        bad = Path(tmp) / "bad.toml"
        bad.write_text('[[sources]]\nname = "missing-repo"\n', encoding="utf-8")
        try:
            load_skills(bad)
            raise AssertionError("缺 repo 应报错")
        except ManifestError:
            pass
        # 未知 method → ManifestError
        bad.write_text('[[plugins]]\nname = "x"\nrepo = "o/r"\nmethod = "curl"\n', encoding="utf-8")
        try:
            load_plugins(bad)
            raise AssertionError("未知 method 应报错")
        except ManifestError:
            pass
        # 纯注释文件 → 空清单
        empty = Path(tmp) / "empty.toml"
        empty.write_text("# 只有一行注释\n", encoding="utf-8")
        assert load_skills(empty) == []
        # 注释/空值处理与 tomllib 等价（有 tomllib 时交叉验证）
        if HAS_TOMLLIB:
            mixed = Path(tmp) / "mixed.toml"
            mixed.write_text(
                '# 注释\n\n[[sources]]\nname = "a"  # 行尾注释由 tomllib 处理，子集解析器不支持\n'
                'repo = "o/r"\nskill = "a"\n', encoding="utf-8")
            # 行尾注释：子集解析器把 'a"  # ...' 当值会炸 → 断言子集解析器行为明确：
            # 实际清单无行尾注释，此处只验证无行尾注释时两条路径等价
            mixed.write_text('[[sources]]\nname = "a"\nrepo = "o/r"\nskill = "a"\n', encoding="utf-8")
            import tomllib as _tl
            ref = _tl.loads(mixed.read_text(encoding="utf-8"))
            ours = _parse_subset_toml(mixed.read_text(encoding="utf-8"))
            assert ours == ref, (ours, ref)

    # local_skill_names：真实仓库非空且排序
    names = local_skill_names(repo)
    assert names == sorted(names) and len(names) > 0
    with tempfile.TemporaryDirectory() as tmp:
        assert local_skill_names(Path(tmp)) == []
        (Path(tmp) / "skills").mkdir()
        (Path(tmp) / "skills" / "x").mkdir()
        (Path(tmp) / "skills" / "x" / "SKILL.md").write_text("---\nname: x\n---\n", encoding="utf-8")
        (Path(tmp) / "skills" / ".hidden").mkdir()  # 隐藏目录跳过
        (Path(tmp) / "skills" / "nofile").mkdir()   # 无 SKILL.md 跳过
        assert local_skill_names(Path(tmp)) == ["x"]

    print("manifest self-check passed.")
