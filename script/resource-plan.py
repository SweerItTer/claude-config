#!/usr/bin/env python3
"""Discover local and declared remote resources and produce an install plan."""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


class PlanError(ValueError):
    pass


def inside(path: Path, root: Path) -> bool:
    try:
        return os.path.commonpath((str(path), str(root))) == str(root)
    except ValueError:
        return False


def frontmatter_name(path: Path) -> str:
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


def discover_local(repo_root: Path) -> list[dict[str, Any]]:
    skills_root = (repo_root / "skills").resolve()
    if not skills_root.is_dir():
        return []
    resources: list[dict[str, Any]] = []
    for entry in sorted(skills_root.iterdir(), key=lambda p: p.name):
        if not entry.is_dir():
            continue
        if entry.name.startswith("."):
            raise PlanError(f"隐藏 skill 目录不受支持: {entry}")
        resolved_dir = entry.resolve()
        if not inside(resolved_dir, skills_root):
            raise PlanError(f"skill 目录越界 symlink: {entry}")
        skill_file = entry / "SKILL.md"
        if not skill_file.is_file():
            raise PlanError(f"skill 缺失 SKILL.md: {entry}")
        resolved_file = skill_file.resolve()
        if not inside(resolved_file, skills_root):
            raise PlanError(f"SKILL.md 越界 symlink: {skill_file}")
        name = frontmatter_name(skill_file)
        if name != entry.name:
            raise PlanError(f"skill name mismatch: 目录 {entry.name!r} != frontmatter {name!r}")
        resources.append({
            "kind": "skill", "id": name, "source": "local", "name": name,
            "repo": None, "marketplace": None, "path": str(skill_file),
        })
    return resources


def read_tsv(path: Path, kind: str) -> list[dict[str, str]]:
    if not path.is_file():
        raise PlanError(f"{kind} TSV 不存在: {path}")
    rows: list[dict[str, str]] = []
    expected = 6
    with path.open(encoding="utf-8", newline="") as stream:
        for lineno, row in enumerate(csv.reader(stream, delimiter="\t"), 1):
            if not row or all(not cell for cell in row):
                continue
            if len(row) != expected:
                raise PlanError(f"{path}:{lineno}: {kind} TSV 必须是 6 列，收到 {len(row)}")
            rows.append(dict(zip(
                ("name", "repo", "skill", "agent", "scope", "note") if kind == "skill"
                else ("name", "repo", "method", "marketplace", "command", "note"), row
            )))
    return rows


def parse_manifest_rows(path: Path, kind: str) -> list[dict[str, str]]:
    if path.suffix.lower() == ".toml":
        parser = Path(__file__).resolve().parent / "parse-manifests.py"
        if not parser.is_file():
            raise PlanError(f"找不到清单解析器: {parser}")
        command = [sys.executable, str(parser), "skills" if kind == "skill" else "plugins",
                   "--file", str(path)]
        try:
            result = subprocess.run(command, capture_output=True, text=True, check=False)
        except OSError as exc:
            raise PlanError(f"无法执行清单解析器: {exc}") from exc
        if result.returncode != 0:
            detail = result.stderr.strip() or f"exit {result.returncode}"
            raise PlanError(f"清单解析失败: {path}: {detail}")
        keys = (("name", "repo", "skill", "agent", "scope", "note")
                if kind == "skill" else
                ("name", "repo", "method", "marketplace", "command", "note"))
        rows: list[dict[str, str]] = []
        for lineno, line in enumerate(result.stdout.splitlines(), 1):
            cells = line.split("\t")
            if len(cells) != 6:
                raise PlanError(f"{path}:{lineno}: parser 输出必须是 6 列")
            rows.append(dict(zip(keys, cells)))
        return rows
    return read_tsv(path, kind)


def load_inventory(path: Path | None) -> dict[str, list[str]]:
    if path is None:
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PlanError(f"skill inventory 无法读取: {path}: {exc}") from exc
    if not isinstance(data, list):
        raise PlanError(f"skill inventory 必须是 JSON 数组: {path}")
    result: dict[str, list[str]] = defaultdict(list)
    for item in data:
        if not isinstance(item, dict) or not isinstance(item.get("source"), str) \
                or not isinstance(item.get("name"), str) or not item["name"]:
            raise PlanError(f"skill inventory 项必须包含非空 source/name: {item!r}")
        result[item["source"]].append(item["name"])
    return {source: sorted(set(names)) for source, names in result.items()}


def declared_resources(skills_file: Path, plugins_file: Path,
                       inventory: dict[str, list[str]] | None = None) -> list[dict[str, Any]]:
    resources: list[dict[str, Any]] = []
    inventory = inventory or {}
    if skills_file.is_file():
        for row in parse_manifest_rows(skills_file, "skill"):
            alias, repo, skill = row["name"], row["repo"], row["skill"]
            if not alias or not repo or not skill:
                raise PlanError(f"skill 清单必须包含 name/repo/skill: {row}")
            skill_names = inventory.get(repo, []) if skill == "*" else [skill]
            if not skill_names:
                # wildcard 无 inventory：降级为集合资源（id=source alias），保留整源语义，
                # 让真实仓库（全 wildcard）也能走统一 resolver，不阻塞发现/冲突。
                resources.append({
                    "kind": "skill", "id": alias, "source": "remote", "name": alias,
                    "repo": repo, "marketplace": None, "path": None, "collection": True,
                })
                continue
            for skill_name in skill_names:
                resources.append({
                    "kind": "skill", "id": skill_name, "source": "remote", "name": alias,
                    "repo": repo, "marketplace": None, "path": None,
                })
    if plugins_file.is_file():
        for row in parse_manifest_rows(plugins_file, "plugin"):
            name, repo, marketplace = row["name"], row["repo"], row["marketplace"]
            if not name or not repo:
                raise PlanError(f"plugin 清单必须包含 name/repo: {row}")
            if not marketplace:
                raise PlanError(f"plugin {name!r} 缺少 marketplace")
            resources.append({
                "kind": "plugin", "id": f"{name}@{marketplace}", "source": "remote",
                "name": name, "repo": repo, "marketplace": marketplace, "path": None,
            })
    return resources


def parse_remote(spec: str) -> dict[str, Any]:
    if "=" in spec:
        ident, rhs = spec.split("=", 1)
        if not ident:
            raise PlanError(f"remote skill id 不能为空: {spec}")
        parts = rhs.split("/")
        if len(parts) < 2 or not all(parts):
            raise PlanError(f"remote skill 必须是 id=owner/repo[/skill]: {spec}")
        repo = "/".join(parts[:2])
        alias = "/".join(parts[2:]) or ident
        return {"kind": "skill", "id": ident, "source": "remote", "name": alias,
                "repo": repo, "marketplace": None, "path": None}
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
    return {"kind": "skill", "id": ident, "source": "remote", "name": alias,
            "repo": repo, "marketplace": None, "path": None}


def build_plan(resources: list[dict[str, Any]], choices: dict[tuple[str, str], str]) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    groups: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for resource in resources:
        groups[(resource["kind"], resource["id"])].append(resource)
    conflicts = []
    plan = []
    for key in sorted(groups):
        kind, ident = key
        group = sorted(groups[key], key=lambda item: (item["source"], item["repo"] or "", item["path"] or ""))
        sources = sorted({item["source"] for item in group})
        choice = choices.get(key)
        if len(sources) > 1 and choice is None:
            conflicts.append({"kind": kind, "id": ident, "resources": group})
            continue
        if choice is not None and choice not in {"local", "remote", "skip"}:
            raise PlanError(f"选择值必须是 local|remote|skip: {kind}:{ident}={choice}")
        selected = choice or sources[0]
        if selected != "skip" and selected not in sources:
            raise PlanError(f"{kind}:{ident} 不存在 source={selected}")
        plan.append({"kind": kind, "id": ident, "action": selected})
    return sorted(resources, key=lambda item: (item["kind"], item["id"], item["source"], item["name"])), conflicts, plan


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="发现本地/远程 skill 与 plugin 并生成资源计划")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--skills-file", type=Path)
    parser.add_argument("--plugins-file", type=Path)
    parser.add_argument("--remote-skill", action="append", default=[])
    parser.add_argument("--inventory", type=Path,
                        help="skills list -g --json 的 JSON 输出，用于展开 skill='*'")
    parser.add_argument("--request", action="append", default=[],
                        help="只处理指定资源 kind:id 或 kind:source-alias (可重复)")
    parser.add_argument("--choose", action="append", default=[])
    parser.add_argument("--format", choices=("json", "tsv"), default="json",
                        help="json=完整计划; tsv=TUI 消费的 9 列计划记录")
    args = parser.parse_args(argv)
    repo_root = args.repo_root.resolve()
    skills_file = args.skills_file or repo_root / "configs" / "skills.toml"
    plugins_file = args.plugins_file or repo_root / "configs" / "plugins.toml"
    try:
        inventory = load_inventory(args.inventory)
        resources = discover_local(repo_root)
        # 显式传了任一清单但文件不存在 = fail loudly；未显式传的默认路径不存在则视为无该类别。
        for flag, path, label in (("--skills-file", skills_file, "skill 清单"),
                                  ("--plugins-file", plugins_file, "plugin 清单")):
            if (args.skills_file or args.plugins_file) and not path.is_file():
                # 只有显式指名的路径才算错误；默认路径缺失是合法空态
                explicit = (args.skills_file == path or args.plugins_file == path)
                if explicit:
                    raise PlanError(f"{label} 不存在: {path}")
        if skills_file.is_file() or plugins_file.is_file():
            resources.extend(declared_resources(skills_file, plugins_file, inventory))
        resources.extend(parse_remote(spec) for spec in args.remote_skill)
        if args.request:
            filtered: list[dict[str, Any]] = []
            for req in args.request:
                match = re.fullmatch(r"(skill|plugin):(.+)", req)
                if not match:
                    raise PlanError(f"--request 格式必须为 kind:spec: {req}")
                rkind, spec = match.groups()
                hits = [r for r in resources
                        if r["kind"] == rkind and (
                            r["id"] == spec or r["name"] == spec
                            or (rkind == "plugin" and r["id"] == f"{spec}@{r['marketplace']}"))]
                if not hits:
                    raise PlanError(f"请求的资源不存在: {req}")
                for hit in hits:
                    if hit not in filtered:
                        filtered.append(hit)
            resources = filtered
        choices: dict[tuple[str, str], str] = {}
        for raw in args.choose:
            match = re.fullmatch(r"(skill|plugin):([^=]+)=(local|remote|skip)", raw)
            if not match:
                raise PlanError(f"--choose 格式必须为 kind:id=local|remote|skip: {raw}")
            choices[(match.group(1), match.group(2))] = match.group(3)
        resources_out, conflicts, plan = build_plan(resources, choices)
    except (OSError, PlanError) as exc:
        print(f"[ERR] {exc}", file=sys.stderr)
        return 1
    selected = []
    for item in resources_out:
        choice = choices.get((item["kind"], item["id"]))
        if choice is None:
            matches = [candidate for candidate in plan
                       if candidate["kind"] == item["kind"] and candidate["id"] == item["id"]]
            if matches and matches[0]["action"] == item["source"]:
                selected.append(item)
        elif choice != "skip" and choice == item["source"]:
            selected.append(item)
    if args.format == "tsv":
        # TUI 消费的计划记录：9 列  kind\tid\tsource\tname\trepo\tmarketplace\tpath\taction\tconflict
        # 每资源一行；conflict=1 表示该 (kind,id) 有未决冲突，TUI 须让用户选择。
        plan_action = {f"{p['kind']}:{p['id']}": p["action"] for p in plan}
        conflict_ids = {f"{c['kind']}:{c['id']}" for c in conflicts}
        for item in sorted(resources_out, key=lambda r: (r["kind"], r["id"], r["source"], r["name"])):
            key = f"{item['kind']}:{item['id']}"
            fields = [
                item["kind"], item["id"], item["source"], item["name"] or "",
                item["repo"] or "", item["marketplace"] or "", item["path"] or "",
                plan_action.get(key, ""), "1" if key in conflict_ids else "0",
            ]
            print("\t".join(fields))
        return 2 if conflicts else 0
    payload = {
        "version": 1,
        "resources": resources_out,
        "conflicts": conflicts,
        "plan": plan,
        "choices": {f"{kind}:{ident}": value for (kind, ident), value in sorted(choices.items())},
        "selected": selected,
    }
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    return 2 if conflicts else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
