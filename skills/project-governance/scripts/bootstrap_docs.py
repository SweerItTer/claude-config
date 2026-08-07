#!/usr/bin/env python3
"""Create configured project documentation governance without overwriting files."""

from __future__ import annotations

import argparse
from pathlib import Path

from governance_config import ConfigError, GovernanceConfig, ensure_repo_path, load_config


def render_template(text: str, config: GovernanceConfig) -> str:
    replacements = {
        "docs/requirement/": config.paths["requirement"].rstrip("/") + "/",
        "docs/specs/": config.paths["specs"].rstrip("/") + "/",
        "docs/dev-guide/": config.paths["dev_guide"].rstrip("/") + "/",
        "docs/analysis/": config.paths["analysis"].rstrip("/") + "/",
        "docs/archive/": config.paths["archive"].rstrip("/") + "/",
        "docs/TODO.md": config.paths["todo"],
        "docs/dev-guide/document-governance.md": config.governance_file,
    }
    for old in sorted(replacements, key=len, reverse=True):
        text = text.replace(old, replacements[old])
    return text


def prepare_directory(target: Path, repo: Path, *, field: str) -> Path:
    safe = ensure_repo_path(repo, target, field=field)
    if safe.exists() and not safe.is_dir():
        raise ConfigError(f"{field} exists but is not a directory: {safe.relative_to(repo)}")
    safe.mkdir(parents=True, exist_ok=True)
    # Re-check after creation so a pre-existing symlink ancestor can never be
    # silently followed to a destination outside the repository.
    return ensure_repo_path(repo, safe, field=field)


def write_if_missing(source: Path, target: Path, repo: Path, config: GovernanceConfig, *, field: str) -> None:
    safe = ensure_repo_path(repo, target, field=field)
    if safe.exists() or safe.is_symlink():
        print(f"skip existing: {safe.relative_to(repo)}")
        return
    prepare_directory(safe.parent, repo, field=f"parent of {field}")
    safe = ensure_repo_path(repo, safe, field=field)
    rendered = render_template(source.read_text(encoding="utf-8"), config)
    safe.write_text(rendered, encoding="utf-8")
    print(f"created: {safe.relative_to(repo)}")


def bootstrap(repo: Path, config: GovernanceConfig) -> None:
    skill_root = Path(__file__).resolve().parents[1]
    template_root = skill_root / "assets" / "templates"

    for key in ("requirement", "specs", "dev_guide", "analysis", "archive"):
        path = prepare_directory(config.path(key), repo, field=f"paths.{key}")
        print(f"ready: {path.relative_to(repo)}")

    targets = {
        "requirement.md": (config.requirement_dir / "_TEMPLATE.md", "Requirement template"),
        "spec.md": (config.specs_dir / "_TEMPLATE.md", "Spec template"),
        "document-governance.md": (config.governance_path, "governance_file"),
        "TODO.md": (config.todo_file, "paths.todo"),
    }
    for source_name, (target, field) in targets.items():
        write_if_missing(template_root / source_name, target, repo, config, field=field)

    if config.canonical_instruction:
        candidates = [config.canonical_instruction_path]
    else:
        candidates = [ensure_repo_path(repo, name, field=f"instruction candidate {name}") for name in ("AGENTS.md", "CLAUDE.md")]
    canonical = next((path for path in candidates if path is not None and path.exists()), None)
    fragment = render_template((template_root / "agents-documentation-section.md").read_text(encoding="utf-8"), config)
    if canonical:
        text = canonical.read_text(encoding="utf-8", errors="replace")
        if config.governance_file in text:
            print(f"ready: {canonical.relative_to(repo)} already indexes documentation governance")
        else:
            print(f"manual: append the rendered governance index to {canonical.relative_to(repo)} after review")
            print("--- rendered index ---")
            print(fragment.rstrip())
            print("--- end index ---")
    else:
        print("manual: no canonical instruction file found; add the rendered governance index to the repository's chosen instruction source")
        print("--- rendered index ---")
        print(fragment.rstrip())
        print("--- end index ---")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", help="Repository root")
    parser.add_argument("--config", help="Explicit repository-relative governance JSON file")
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    if not repo.exists() or not repo.is_dir():
        parser.error(f"Repository path is not a directory: {repo}")
    try:
        config = load_config(repo, args.config)
        bootstrap(repo, config)
    except ConfigError as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
