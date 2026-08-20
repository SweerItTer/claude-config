#!/usr/bin/env python3
"""Inventory repository documentation without modifying the repository."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable

from governance_config import ConfigError, GovernanceConfig, load_config

FRONTMATTER_RE = re.compile(r"\A---\s*\n(.*?)\n---\s*\n?", re.DOTALL)
ID_RE = re.compile(r"(?<![A-Z0-9])([RS]\d{2,})(?!\d)")
IDENTITY_FILENAME_RE = re.compile(r"^([RS]\d{2,})(?:$|[-_. ])")
VERSION_RE = re.compile(r"(?:^|[-_.])(v\d+|final|latest|new|old)(?:[-_.]|$)", re.IGNORECASE)
DOC_EXTENSIONS = {".md", ".markdown", ".mdx", ".rst", ".txt"}
IGNORED_DIRS = {".git", ".hg", ".svn", "node_modules", ".venv", "venv", "vendor", "build", "install", "dist"}


def run_git(repo: Path, args: list[str]) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo), *args],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )
        return proc.returncode, proc.stdout.strip()
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, str(exc)


def is_ignored(path: Path, repo: Path, config: GovernanceConfig | None = None) -> bool:
    try:
        rel = path.relative_to(repo)
    except ValueError:
        return True
    if config is not None:
        explicit_roots = [config.path(key) for key in ("requirement", "specs", "dev_guide", "analysis", "archive")]
        explicit_files = {config.todo_file, config.governance_path}
        if config.source_path is not None:
            explicit_files.add(config.source_path)
        if config.canonical_instruction_path is not None:
            explicit_files.add(config.canonical_instruction_path)
        if path in explicit_files or any(is_under(path, root) for root in explicit_roots):
            return False
    return any(part in IGNORED_DIRS for part in rel.parts[:-1])


def is_under(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def iter_docs(repo: Path, config: GovernanceConfig) -> Iterable[Path]:
    for path in repo.rglob("*"):
        if not path.is_file() or is_ignored(path, repo, config):
            continue
        if path.suffix.lower() in DOC_EXTENSIONS:
            yield path


def parse_frontmatter(path: Path) -> dict[str, str]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    match = FRONTMATTER_RE.match(text)
    if not match:
        return {}
    result: dict[str, str] = {}
    for raw in match.group(1).splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        result[key.strip()] = value.strip().strip("'\"")
    return result


def classify_path(path: Path, config: GovernanceConfig) -> str:
    for key in ("requirement", "specs", "dev_guide", "analysis", "archive"):
        if is_under(path, config.path(key)):
            return key
    if path == config.todo_file or path == config.governance_path:
        return "special"
    return "outside-governed-paths"


def instruction_info(repo: Path) -> list[dict[str, Any]]:
    names = ["AGENTS.md", "CLAUDE.md", "CONTRIBUTING.md", ".cursorrules", ".windsurfrules", "OPENCODE.md"]
    rows: list[dict[str, Any]] = []
    for name in names:
        path = repo / name
        if not path.exists() and not path.is_symlink():
            continue
        row: dict[str, Any] = {"path": name, "symlink": path.is_symlink()}
        if path.is_symlink():
            try:
                row["target"] = str(path.readlink())
            except OSError as exc:
                row["target_error"] = str(exc)
        rows.append(row)
    return rows


def build_inventory(repo: Path, explicit_config: str | None = None) -> dict[str, Any]:
    config = load_config(repo, explicit_config)
    files = sorted(iter_docs(repo, config))
    by_class = Counter()
    ids: dict[str, list[str]] = defaultdict(list)
    versioned: list[str] = []
    no_frontmatter: list[str] = []
    outside: list[str] = []
    status_counts = Counter()
    kind_counts = Counter()

    for path in files:
        rel = path.relative_to(repo).as_posix()
        cls = classify_path(path, config)
        by_class[cls] += 1
        identity_match = IDENTITY_FILENAME_RE.match(path.stem)
        identity = identity_match.group(1) if identity_match else None
        if identity and (
            (cls == "requirement" and identity.startswith("R"))
            or (cls == "specs" and identity.startswith("S"))
            or cls == "archive"
        ):
            ids[identity].append(rel)
        if VERSION_RE.search(path.stem):
            versioned.append(rel)
        fm = parse_frontmatter(path)
        if cls in {"requirement", "specs"} and not path.name.startswith("_TEMPLATE"):
            if not fm:
                no_frontmatter.append(rel)
            if fm.get("status"):
                status_counts[fm["status"]] += 1
            if fm.get("kind"):
                kind_counts[fm["kind"]] += 1
        if cls == "outside-governed-paths":
            outside.append(rel)

    rc, root = run_git(repo, ["rev-parse", "--show-toplevel"])
    git_repo = rc == 0
    branch = ""
    status = ""
    if git_repo:
        _, branch = run_git(repo, ["branch", "--show-current"])
        _, status = run_git(repo, ["status", "--short"])

    todo = config.todo_file
    todo_info: dict[str, Any] = {"path": config.paths["todo"], "exists": todo.exists()}
    if todo.exists():
        text = todo.read_text(encoding="utf-8", errors="replace")
        todo_info.update(
            {
                "lines": len(text.splitlines()),
                "pending": len(re.findall(r"^\s*[-*]\s*\[ \]", text, re.MULTILINE)),
                "completed": len(re.findall(r"^\s*[-*]\s*\[[xX]\]", text, re.MULTILINE)),
            }
        )

    duplicates = {key: paths for key, paths in ids.items() if len(paths) > 1}
    return {
        "repo": str(repo),
        "governance": config.as_dict(),
        "git": {
            "is_repository": git_repo,
            "root": root if git_repo else None,
            "branch": branch if git_repo else None,
            "working_tree": status.splitlines() if status else [],
        },
        "instructions": instruction_info(repo),
        "documents": {
            "total": len(files),
            "by_class": dict(sorted(by_class.items())),
            "outside_governed_paths": outside,
            "missing_frontmatter_candidates": no_frontmatter,
            "versioned_filename_candidates": versioned,
        },
        "stable_ids": {"count": len(ids), "duplicates": duplicates, "locations": dict(sorted(ids.items()))},
        "lifecycle": {"status_counts": dict(sorted(status_counts.items())), "kind_counts": dict(sorted(kind_counts.items()))},
        "todo": todo_info,
    }


def print_markdown(data: dict[str, Any]) -> None:
    print("# Documentation inventory\n")
    print(f"- Repository: `{data['repo']}`")
    governance = data["governance"]
    print(f"- Governance mapping: `{governance['source'] or 'default fallback'}`")
    for key, value in governance["paths"].items():
        print(f"  - `{key}`: `{value}`")
    git = data["git"]
    print(f"- Git repository: {'yes' if git['is_repository'] else 'no'}")
    if git["is_repository"]:
        print(f"- Branch: `{git['branch'] or '(detached)'}`")
        print(f"- Working-tree changes: {len(git['working_tree'])}")
    print()

    print("## Instruction files")
    rows = data["instructions"]
    if not rows:
        print("- None found")
    else:
        for row in rows:
            suffix = f" -> `{row.get('target')}`" if row.get("symlink") else ""
            print(f"- `{row['path']}`: {'symlink' if row.get('symlink') else 'file'}{suffix}")
    print()

    docs = data["documents"]
    print("## Documents")
    print(f"- Total documentation-like files: {docs['total']}")
    for cls, count in docs["by_class"].items():
        print(f"- `{cls}`: {count}")
    print(f"- Outside configured governed paths: {len(docs['outside_governed_paths'])}")
    for path in docs["outside_governed_paths"][:50]:
        print(f"  - `{path}`")
    if len(docs["outside_governed_paths"]) > 50:
        print(f"  - ... {len(docs['outside_governed_paths']) - 50} more")
    print()

    print("## Stable IDs")
    stable = data["stable_ids"]
    print(f"- Unique IDs found: {stable['count']}")
    if stable["duplicates"]:
        for stable_id, paths in stable["duplicates"].items():
            print(f"- Duplicate `{stable_id}`: {', '.join(f'`{p}`' for p in paths)}")
    else:
        print("- Duplicate IDs: none detected")
    print()

    print("## Lifecycle and TODO")
    print(f"- Status counts: {data['lifecycle']['status_counts'] or {}}")
    print(f"- Kind counts: {data['lifecycle']['kind_counts'] or {}}")
    todo = data["todo"]
    if todo["exists"]:
        print(f"- TODO `{todo['path']}`: {todo['lines']} lines, {todo['pending']} pending, {todo['completed']} completed")
    else:
        print(f"- TODO `{todo['path']}`: not found")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", help="Repository root")
    parser.add_argument("--config", help="Explicit repository-relative governance JSON file")
    parser.add_argument("--json", action="store_true", help="Emit JSON")
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    if not repo.exists() or not repo.is_dir():
        parser.error(f"Repository path is not a directory: {repo}")
    try:
        data = build_inventory(repo, args.config)
    except ConfigError as exc:
        parser.error(str(exc))
    if args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print_markdown(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
