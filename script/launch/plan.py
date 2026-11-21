#!/usr/bin/env python3
"""统一资源计划层：discover → normalize → conflict → select。

吸收自 script/resource-plan.py，CLI 子进程改为函数调用：
plan_resources(repo_root, requests, choices) → ResourcePlan。

- 本地候选：repo_root/skills/<name>/SKILL.md（越界 symlink/缺 frontmatter → PlanError）。
- 远程候选：configs/skills.toml（skill='*' 依赖 inventory 展开，无 inventory 降级为
  集合资源 id=source alias）+ configs/plugins.toml。
- 同一 (kind,id) 有多个候选且 choices 未决 → 进 ResourcePlan.conflicts，不抛异常。
- request 过滤："skill:NAME" / "plugin:NAME"（id 或 source alias 命中）。
"""

from __future__ import annotations

import os
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

if __package__ in (None, ""):  # 直接执行自检：script/ 加入 sys.path 以支持相对导入
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    __package__ = "launch"

from . import manifest


class PlanError(ValueError):
    pass


@dataclass
class PlannedItem:
    kind: str      # skill | plugin
    id: str
    source: str    # local | remote
    name: str
    repo: str | None
    marketplace: str | None
    path: str | None
    action: str = ""      # local | remote | skip | ""（未决冲突）
    conflict: bool = False  # 该 (kind,id) 有未决冲突
    collection: bool = False  # wildcard 无 inventory 降级的集合资源


@dataclass
class Conflict:
    kind: str
    id: str
    candidates: list[PlannedItem] = field(default_factory=list)


@dataclass
class ResourcePlan:
    items: list[PlannedItem]
    conflicts: list[Conflict]


# ---------------------------------------------------------------------------
# 本地发现
# ---------------------------------------------------------------------------

def _inside(path: Path, root: Path) -> bool:
    try:
        return os.path.commonpath((str(path), str(root))) == str(root)
    except ValueError:
        return False


def _frontmatter_name(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        raise PlanError(f"{path}: SKILL.md 缺少 frontmatter")
    try:
        end = next(i for i, line in enumerate(lines[1:], 1) if line.strip() == "---")
    except StopIteration as exc:
        raise PlanError(f"{path}: SKILL.md frontmatter 未闭合") from exc
    values: dict[str, str] = {}
    block_key: str | None = None
    for line in lines[1:end]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line[:1].isspace():
            if block_key is None:
                raise PlanError(f"{path}: frontmatter 缩进续行缺少 block scalar")
            continue
        key, sep, value = line.partition(":")
        if not sep or not key.strip():
            raise PlanError(f"{path}: frontmatter 字段格式无效: {line!r}")
        key = key.strip()
        if key in values:
            raise PlanError(f"{path}: frontmatter 字段重复: {key}")
        raw_value = value.strip()
        block_key = key if not raw_value or raw_value in {">", ">-", "|", "|-"} else None
        values[key] = "" if block_key else raw_value.strip('"\'')
    name = values.get("name", "")
    if not name or "\n" in name:
        raise PlanError(f"{path}: frontmatter 缺少有效 name")
    return name


def discover_local(repo_root: Path) -> list[PlannedItem]:
    skills_root = (Path(repo_root) / "skills").resolve()
    if not skills_root.is_dir():
        return []
    resources: list[PlannedItem] = []
    for entry in sorted(skills_root.iterdir(), key=lambda p: p.name):
        if not entry.is_dir():
            continue
        if entry.name.startswith("."):
            raise PlanError(f"隐藏 skill 目录不受支持: {entry}")
        resolved_dir = entry.resolve()
        if not _inside(resolved_dir, skills_root):
            raise PlanError(f"skill 目录越界 symlink: {entry}")
        skill_file = entry / "SKILL.md"
        if not skill_file.is_file():
            raise PlanError(f"skill 缺失 SKILL.md: {entry}")
        resolved_file = skill_file.resolve()
        if not _inside(resolved_file, skills_root):
            raise PlanError(f"SKILL.md 越界 symlink: {skill_file}")
        name = _frontmatter_name(skill_file)
        if name != entry.name:
            raise PlanError(f"skill name mismatch: 目录 {entry.name!r} != frontmatter {name!r}")
        resources.append(PlannedItem(
            kind="skill", id=name, source="local", name=name,
            repo=None, marketplace=None, path=str(skill_file)))
    return resources


# ---------------------------------------------------------------------------
# 清单声明 → 资源
# ---------------------------------------------------------------------------

def declared_resources(skills_file: Path, plugins_file: Path,
                       inventory: dict[str, list[str]] | None = None) -> list[PlannedItem]:
    resources: list[PlannedItem] = []
    inventory = inventory or {}
    if skills_file.is_file():
        for src in manifest.load_skills(skills_file):
            if not src.name or not src.repo or not src.skill:
                raise PlanError(f"skill 清单必须包含 name/repo/skill: {src}")
            skill_names = inventory.get(src.repo, []) if src.skill == "*" else [src.skill]
            if not skill_names:
                # wildcard 无 inventory：降级为集合资源（id=source alias），保留整源语义，
                # 让真实仓库（全 wildcard）也能走统一 resolver，不阻塞发现/冲突。
                resources.append(PlannedItem(
                    kind="skill", id=src.name, source="remote", name=src.name,
                    repo=src.repo, marketplace=None, path=None, collection=True))
                continue
            for skill_name in skill_names:
                resources.append(PlannedItem(
                    kind="skill", id=skill_name, source="remote", name=src.name,
                    repo=src.repo, marketplace=None, path=None))
    if plugins_file.is_file():
        for src in manifest.load_plugins(plugins_file):
            if not src.name or not src.repo:
                raise PlanError(f"plugin 清单必须包含 name/repo: {src}")
            if src.method == "npx":
                # npx 插件手动安装，无 marketplace，canonical id 用 name
                resources.append(PlannedItem(
                    kind="plugin", id=src.name, source="remote",
                    name=src.name, repo=src.repo, marketplace=None, path=None))
                continue
            if not src.marketplace:
                raise PlanError(f"plugin {src.name!r} 缺少 marketplace")
            resources.append(PlannedItem(
                kind="plugin", id=f"{src.name}@{src.marketplace}", source="remote",
                name=src.name, repo=src.repo, marketplace=src.marketplace, path=None))
    return resources


def parse_remote(spec: str) -> PlannedItem:
    """remote skill 规格字符串 → 资源。

    三种形态：id=owner/repo[/skill] | alias,repo,skill | owner/repo/skill。
    """
    if "=" in spec:
        ident, rhs = spec.split("=", 1)
        if not ident:
            raise PlanError(f"remote skill id 不能为空: {spec}")
        parts = rhs.split("/")
        if len(parts) < 2 or not all(parts):
            raise PlanError(f"remote skill 必须是 id=owner/repo[/skill]: {spec}")
        repo = "/".join(parts[:2])
        alias = "/".join(parts[2:]) or ident
        return PlannedItem(kind="skill", id=ident, source="remote", name=alias,
                           repo=repo, marketplace=None, path=None)
    parts = spec.split(",") if "," in spec else spec.split("/")
    if len(parts) == 3 and "," in spec:
        alias, repo, ident = parts
    elif len(parts) == 3:
        repo, ident = "/".join(parts[:2]), parts[2]
        alias = ident
    elif len(parts) >= 4:
        alias, repo, ident = parts[0], "/".join(parts[1:3]), "/".join(parts[3:])
    else:
        raise PlanError(f"remote skill 必须是 id=owner/repo[/skill] 或 alias,repo,skill: {spec}")
    if not all((alias, repo, ident)):
        raise PlanError(f"remote skill 字段不能为空: {spec}")
    return PlannedItem(kind="skill", id=ident, source="remote", name=alias,
                       repo=repo, marketplace=None, path=None)


# ---------------------------------------------------------------------------
# 冲突/选择
# ---------------------------------------------------------------------------

def _build_groups(resources: list[PlannedItem]
                  ) -> tuple[list[Conflict], dict[tuple[str, str], str]]:
    """按 (kind,id) 分组；多候选且无 choice → Conflict；返回 (conflicts, action 映射)。"""
    groups: dict[tuple[str, str], list[PlannedItem]] = defaultdict(list)
    for resource in resources:
        groups[(resource.kind, resource.id)].append(resource)
    conflicts: list[Conflict] = []
    actions: dict[tuple[str, str], str] = {}
    for key in sorted(groups):
        kind, ident = key
        group = sorted(groups[key],
                       key=lambda item: (item.source, item.repo or "", item.path or ""))
        sources = sorted({item.source for item in group})
        choice = _choices.get(key)
        if choice is not None and choice not in {"local", "remote", "skip"}:
            raise PlanError(f"选择值必须是 local|remote|skip: {kind}:{ident}={choice}")
        if len(sources) > 1 and choice is None:
            conflicts.append(Conflict(kind=kind, id=ident, candidates=group))
            continue
        selected = choice or sources[0]
        if selected != "skip" and selected not in sources:
            raise PlanError(f"{kind}:{ident} 不存在 source={selected}")
        actions[key] = selected
    return conflicts, actions


_choices: dict[tuple[str, str], str] = {}


def plan_resources(repo_root: Path, requests: list[str], *,
                   choices: dict[str, str] = {}) -> ResourcePlan:
    """发现 + 请求过滤 + 冲突检测 → ResourcePlan。

    requests: "skill:NAME" / "plugin:NAME"（id、source alias、plugin name 均可命中）；
    空列表 = 全量。choices: "skill:NAME" -> "local|remote|skip"。
    冲突未决不抛异常，放进 ResourcePlan.conflicts（对应项 action=""、conflict=True）。
    """
    global _choices
    repo_root = Path(repo_root).resolve()
    skills_file = repo_root / "configs" / "skills.toml"
    plugins_file = repo_root / "configs" / "plugins.toml"

    _choices = {}
    for raw, value in choices.items():
        match = re.fullmatch(r"(skill|plugin):(.+)", raw)
        if not match:
            raise PlanError(f"choice 键格式必须为 kind:id: {raw}")
        _choices[(match.group(1), match.group(2))] = value

    resources = discover_local(repo_root)
    if skills_file.is_file() or plugins_file.is_file():
        resources.extend(declared_resources(skills_file, plugins_file))

    # 请求过滤：只保留命中的资源（无请求 = 全量）
    filtered: list[PlannedItem] = []
    if requests:
        for req in requests:
            match = re.fullmatch(r"(skill|plugin):(.+)", req)
            if not match:
                raise PlanError(f"request 格式必须为 kind:spec: {req}")
            rkind, spec = match.groups()
            hits = [r for r in resources
                    if r.kind == rkind and (
                        r.id == spec or r.name == spec
                        or (rkind == "plugin" and r.marketplace and
                            r.id == f"{spec}@{r.marketplace}"))]
            if not hits:
                raise PlanError(f"请求的资源不存在: {req}")
            for hit in hits:
                if hit not in filtered:
                    filtered.append(hit)
        resources = filtered

    conflicts, actions = _build_groups(resources)

    items: list[PlannedItem] = []
    for item in sorted(resources,
                       key=lambda r: (r.kind, r.id, r.source, r.name)):
        key = (item.kind, item.id)
        action = actions.get(key, "")
        item.action = action
        item.conflict = action == "" and any(
            c.kind == item.kind and c.id == item.id for c in conflicts)
        items.append(item)
    return ResourcePlan(items=items, conflicts=conflicts)


if __name__ == "__main__":
    # --- 自检：真实仓库（含自有 skills/ + configs/ 清单）+ 冲突/选择/过滤 ---
    import tempfile

    repo = Path(__file__).resolve().parents[2]

    # 真实仓库：本地 skills/ + skills.toml + plugins.toml 都应被发现
    plan = plan_resources(repo, [])
    kinds = {item.kind for item in plan.items}
    assert kinds <= {"skill", "plugin"}, kinds
    assert any(i.kind == "skill" and i.source == "local" for i in plan.items), "应发现本地 skill"
    assert any(i.kind == "skill" and i.id == "grilling" and i.source == "remote"
               for i in plan.items), plan.items
    assert any(i.kind == "plugin" and i.id == "superpowers@superpowers-dev"
               for i in plan.items), plan.items
    assert any(i.kind == "plugin" and i.id == "CodeGraph" and i.marketplace is None
               for i in plan.items), plan.items

    # request 过滤 + 命中不存在 → PlanError
    plan = plan_resources(repo, ["skill:grilling"])
    assert all(i.kind == "skill" and (i.id == "grilling" or i.name == "grilling")
               for i in plan.items), plan.items
    try:
        plan_resources(repo, ["skill:nope"])
        raise AssertionError("不存在的请求应报错")
    except PlanError:
        pass
    try:
        plan_resources(repo, ["bogus:x"])
        raise AssertionError("非法 request 格式应报错")
    except PlanError:
        pass

    # 冲突与 choose：fixture 仓库 local+remote 同名
    with tempfile.TemporaryDirectory() as tmp:
        fx = Path(tmp)
        (fx / "skills" / "same").mkdir(parents=True)
        (fx / "skills" / "same" / "SKILL.md").write_text(
            "---\nname: same\ndescription: t\n---\n", encoding="utf-8")
        (fx / "configs").mkdir()
        (fx / "configs" / "skills.toml").write_text(
            '[[sources]]\nname = "same"\nrepo = "owner/repo"\nskill = "same"\n',
            encoding="utf-8")
        plan = plan_resources(fx, ["skill:same"])
        assert len(plan.conflicts) == 1 and plan.conflicts[0].id == "same"
        assert {i.source for i in plan.items} == {"local", "remote"}
        assert all(i.action == "" and i.conflict for i in plan.items), plan.items

        plan = plan_resources(fx, ["skill:same"], choices={"skill:same": "local"})
        assert plan.conflicts == []
        assert all(i.action == "local" for i in plan.items), plan.items

        plan = plan_resources(fx, ["skill:same"], choices={"skill:same": "skip"})
        assert plan.conflicts == [] and all(i.action == "skip" for i in plan.items)

        try:
            plan_resources(fx, ["skill:same"], choices={"skill:same": "bogus"})
            raise AssertionError("非法 choose 值应报错")
        except PlanError:
            pass

        # 越界 symlink → PlanError
        outside = Path(tempfile.mkdtemp())
        try:
            (outside / "SKILL.md").write_text("---\nname: escape\n---\n", encoding="utf-8")
            (fx / "skills" / "escape").symlink_to(outside)
            try:
                plan_resources(fx, [])
                raise AssertionError("越界 symlink 应报错")
            except PlanError:
                pass
        finally:
            import shutil
            shutil.rmtree(outside)

    # wildcard 无 inventory 降级为集合资源
    with tempfile.TemporaryDirectory() as tmp:
        fx = Path(tmp)
        (fx / "configs").mkdir()
        (fx / "configs" / "skills.toml").write_text(
            '[[sources]]\nname = "src"\nrepo = "o/r"\nskill = "*"\n', encoding="utf-8")
        plan = plan_resources(fx, [])
        assert len(plan.items) == 1 and plan.items[0].collection \
            and plan.items[0].id == "src" and plan.items[0].source == "remote", plan.items

    # npx 插件 id=name；claude-plugin id=name@marketplace
    with tempfile.TemporaryDirectory() as tmp:
        fx = Path(tmp)
        (fx / "configs").mkdir()
        (fx / "configs" / "plugins.toml").write_text(
            '[[plugins]]\nname = "p1"\nrepo = "o/r"\nmethod = "npx"\ncommand = "npm i -g x"\n'
            '[[plugins]]\nname = "p2"\nrepo = "o/r2"\nmethod = "claude-plugin"\nmarketplace = "mkt"\n', encoding="utf-8")
        plan = plan_resources(fx, [])
        ids = {i.id for i in plan.items}
        assert ids == {"p1", "p2@mkt"}, ids

    print("plan self-check passed.")
