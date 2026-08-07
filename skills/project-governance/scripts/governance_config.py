#!/usr/bin/env python3
"""Load and validate repository documentation-governance path mappings."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any

CONFIG_CANDIDATES = (".project-governance.json", "docs/project-governance.json")
DOCUMENT_EXTENSIONS = {".md", ".markdown", ".rst", ".txt"}
RESERVED_NON_DOCUMENT_NAMES = {
    "Makefile", "GNUmakefile", "CMakeLists.txt", "Kconfig", "Dockerfile", "Jenkinsfile",
    "meson.build", "SConstruct", "BUILD", "BUILD.bazel", ".config",
}
RESERVED_NON_DOCUMENT_PREFIXES = ("Kconfig.", "Dockerfile.", "Jenkinsfile.")
DEFAULT_PATHS = {
    "requirement": "docs/requirement",
    "specs": "docs/specs",
    "dev_guide": "docs/dev-guide",
    "analysis": "docs/analysis",
    "archive": "docs/archive",
    "todo": "docs/TODO.md",
}
DEFAULT_GOVERNANCE_FILE = "docs/dev-guide/document-governance.md"
DIRECTORY_KEYS = ("requirement", "specs", "dev_guide", "analysis", "archive")
REQUIRED_PATH_KEYS = tuple(DEFAULT_PATHS)


class ConfigError(ValueError):
    """Raised when a repository governance configuration is invalid or unsafe."""


def ensure_repo_path(repo: Path, candidate: str | Path, *, field: str) -> Path:
    """Return a lexical repository path only when its resolved destination stays inside."""

    repo = repo.resolve()
    path = Path(candidate)
    if not path.is_absolute():
        path = repo / path

    lexical = Path(os.path.abspath(path))
    try:
        lexical.relative_to(repo)
    except ValueError as exc:
        raise ConfigError(f"{field} must stay inside the repository: {candidate!s}") from exc

    try:
        resolved = path.resolve(strict=False)
    except (OSError, RuntimeError) as exc:
        raise ConfigError(f"{field} cannot be resolved safely: {candidate!s}: {exc}") from exc
    try:
        resolved.relative_to(repo)
    except ValueError as exc:
        raise ConfigError(
            f"{field} resolves outside the repository, possibly through a symlink: {candidate!s} -> {resolved}"
        ) from exc
    return lexical


@dataclass(frozen=True)
class GovernanceConfig:
    repo: Path
    source_path: Path | None
    declared: bool
    canonical_instruction: str | None
    governance_file: str
    paths: dict[str, str]

    def path(self, key: str) -> Path:
        return ensure_repo_path(self.repo, self.paths[key], field=f"paths.{key}")

    @property
    def requirement_dir(self) -> Path:
        return self.path("requirement")

    @property
    def specs_dir(self) -> Path:
        return self.path("specs")

    @property
    def dev_guide_dir(self) -> Path:
        return self.path("dev_guide")

    @property
    def analysis_dir(self) -> Path:
        return self.path("analysis")

    @property
    def archive_dir(self) -> Path:
        return self.path("archive")

    @property
    def todo_file(self) -> Path:
        return self.path("todo")

    @property
    def governance_path(self) -> Path:
        return ensure_repo_path(self.repo, self.governance_file, field="governance_file")

    @property
    def canonical_instruction_path(self) -> Path | None:
        if self.canonical_instruction is None:
            return None
        return ensure_repo_path(self.repo, self.canonical_instruction, field="canonical_instruction")

    def as_dict(self) -> dict[str, Any]:
        return {
            "declared": self.declared,
            "source": self.source_path.relative_to(self.repo).as_posix() if self.source_path else None,
            "canonical_instruction": self.canonical_instruction,
            "governance_file": self.governance_file,
            "paths": dict(self.paths),
        }


def _normalize_relative_path(value: Any, *, field: str, expect_file: bool | None = None) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"{field} must be a non-empty repository-relative path string")
    raw = value.replace("\\", "/").strip()
    pure = PurePosixPath(raw)
    if pure.is_absolute() or ".." in pure.parts:
        raise ConfigError(f"{field} must stay inside the repository: {value!r}")
    normalized = pure.as_posix()
    if not normalized or normalized == ".":
        raise ConfigError(f"{field} cannot point at the repository root")
    if expect_file is True and normalized.endswith("/"):
        raise ConfigError(f"{field} must name a file, not a directory")
    return normalized




def _validate_document_role_name(value: str, *, field: str) -> None:
    """Require governance file roles to remain ordinary documentation files."""

    pure = PurePosixPath(value)
    name = pure.name
    if name in RESERVED_NON_DOCUMENT_NAMES or name.startswith(RESERVED_NON_DOCUMENT_PREFIXES):
        raise ConfigError(f"{field} cannot name a source/build/configuration file: {value!r}")
    if pure.suffix.lower() not in DOCUMENT_EXTENSIONS:
        allowed = ", ".join(sorted(DOCUMENT_EXTENSIONS))
        raise ConfigError(f"{field} must use a governance-document extension ({allowed}): {value!r}")

def _resolve_config_path(repo: Path, explicit: str | Path | None) -> Path | None:
    if explicit is not None:
        candidate = ensure_repo_path(repo, explicit, field="configuration file")
        if candidate.is_symlink() or not candidate.is_file():
            raise ConfigError(f"configuration path is not a regular non-symlink file: {candidate}")
        return candidate

    found: list[Path] = []
    for name in CONFIG_CANDIDATES:
        candidate = repo / name
        if not candidate.exists() and not candidate.is_symlink():
            continue
        safe = ensure_repo_path(repo, candidate, field=f"configuration file {name}")
        if safe.is_symlink() or not safe.is_file():
            raise ConfigError(f"configuration path is not a regular non-symlink file: {name}")
        found.append(safe)
    if len(found) > 1:
        paths = ", ".join(path.relative_to(repo).as_posix() for path in found)
        raise ConfigError(f"multiple governance configuration files found: {paths}")
    return found[0] if found else None


def _path_relation(a: str, b: str) -> str | None:
    pa = PurePosixPath(a)
    pb = PurePosixPath(b)
    if pa == pb:
        return "equal"
    if pa in pb.parents:
        return "ancestor"
    if pb in pa.parents:
        return "descendant"
    return None


def _resolved_relative(repo: Path, value: str, *, field: str) -> str:
    path = ensure_repo_path(repo, value, field=field)
    try:
        return path.resolve(strict=False).relative_to(repo.resolve()).as_posix()
    except (OSError, RuntimeError, ValueError) as exc:
        raise ConfigError(f"{field} cannot be resolved inside the repository: {value!r}") from exc


def _validate_resolved_directory_roles(config: GovernanceConfig) -> None:
    """Reject category aliases and physical ancestor/descendant overlap."""

    resolved: dict[str, str] = {}
    for key in DIRECTORY_KEYS:
        target = config.path(key)
        if target.is_symlink():
            raise ConfigError(
                f"paths.{key} must not itself be a symbolic link: {config.paths[key]!r}"
            )
        resolved[key] = _resolved_relative(config.repo, config.paths[key], field=f"paths.{key}")

    items = list(resolved.items())
    for index, (left_name, left_path) in enumerate(items):
        for right_name, right_path in items[index + 1 :]:
            relation = _path_relation(left_path, right_path)
            if relation is not None:
                raise ConfigError(
                    "governance directory roles must be physically non-overlapping after resolving symlinks: "
                    f"paths.{left_name}={config.paths[left_name]!r} -> {left_path!r}, "
                    f"paths.{right_name}={config.paths[right_name]!r} -> {right_path!r} ({relation})"
                )


def _validate_existing_parent_chain(repo: Path, target: Path, *, field: str) -> None:
    repo = repo.resolve()
    try:
        rel = target.relative_to(repo)
    except ValueError as exc:
        raise ConfigError(f"{field} is outside the repository: {target}") from exc

    current = repo
    for part in rel.parts[:-1]:
        current = current / part
        if not current.exists() and not current.is_symlink():
            continue
        ensure_repo_path(repo, current, field=f"ancestor of {field}")
        if not current.is_dir():
            raise ConfigError(
                f"ancestor of {field} is not a directory: {current.relative_to(repo).as_posix()}"
            )


def _validate_directory_target(repo: Path, target: Path, *, field: str) -> None:
    _validate_existing_parent_chain(repo, target, field=field)
    if target.is_symlink():
        raise ConfigError(f"{field} must be a real directory or absent, not a symbolic link: {target.relative_to(repo)}")
    if target.exists() and not target.is_dir():
        raise ConfigError(f"{field} must be a directory or absent: {target.relative_to(repo)}")


def _validate_file_target(repo: Path, target: Path, *, field: str) -> None:
    _validate_existing_parent_chain(repo, target, field=field)
    if target.is_symlink():
        raise ConfigError(f"{field} must be a regular file or absent, not a symlink: {target.relative_to(repo)}")
    if target.exists() and not target.is_file():
        raise ConfigError(f"{field} must be a regular file or absent: {target.relative_to(repo)}")
    if target.exists():
        try:
            if target.stat().st_nlink > 1:
                raise ConfigError(
                    f"{field} must not be a hard-linked file: {target.relative_to(repo)}"
                )
        except OSError as exc:
            raise ConfigError(f"cannot inspect {field}: {target.relative_to(repo)}: {exc}") from exc


def _role_paths(config: GovernanceConfig, *, resolved: bool) -> tuple[dict[str, str], dict[str, str]]:
    directories = {f"paths.{key}": config.paths[key] for key in DIRECTORY_KEYS}
    files: dict[str, str] = {
        "paths.todo": config.paths["todo"],
        "governance_file": config.governance_file,
    }
    if config.canonical_instruction is not None:
        files["canonical_instruction"] = config.canonical_instruction
    if resolved:
        directories = {
            name: _resolved_relative(config.repo, value, field=name) for name, value in directories.items()
        }
        files = {name: _resolved_relative(config.repo, value, field=name) for name, value in files.items()}
    return directories, files


def _validate_role_graph(config: GovernanceConfig, *, resolved: bool) -> None:
    """Reject semantic role collisions in lexical and physical path space."""

    directory_roles, file_roles = _role_paths(config, resolved=resolved)
    space = "physical/resolved" if resolved else "lexical"

    directory_items = list(directory_roles.items())
    for index, (left_name, left_path) in enumerate(directory_items):
        for right_name, right_path in directory_items[index + 1 :]:
            relation = _path_relation(left_path, right_path)
            if relation is not None:
                wording = "physically non-overlapping" if resolved else "non-overlapping"
                raise ConfigError(
                    f"governance directory roles must be {wording} in {space} path space: "
                    f"{left_name}={left_path!r}, {right_name}={right_path!r} ({relation})"
                )

    file_items = list(file_roles.items())
    for index, (left_name, left_path) in enumerate(file_items):
        for right_name, right_path in file_items[index + 1 :]:
            relation = _path_relation(left_path, right_path)
            if relation is not None:
                raise ConfigError(
                    f"file roles must not reuse or contain one another in {space} path space: "
                    f"{left_name}={left_path!r}, {right_name}={right_path!r} ({relation})"
                )

    for file_name, file_path in file_roles.items():
        file_pure = PurePosixPath(file_path)
        for directory_name, directory_path in directory_roles.items():
            directory_pure = PurePosixPath(directory_path)
            # A governance file may live below its category directory, but it may
            # never be the directory itself or physically contain a category.
            if file_pure == directory_pure or file_pure in directory_pure.parents:
                raise ConfigError(
                    f"file role {file_name}={file_path!r} conflicts with directory role "
                    f"{directory_name}={directory_path!r} in {space} path space"
                )


def _validate_mapping_roles(config: GovernanceConfig) -> None:
    _validate_role_graph(config, resolved=False)
    _validate_role_graph(config, resolved=True)

def _validate_mapping_targets(config: GovernanceConfig) -> None:
    # Report an explicit category symlink before resolved aliases collapse its
    # identity into another role.
    for key in DIRECTORY_KEYS:
        target = config.path(key)
        if target.is_symlink():
            raise ConfigError(
                f"paths.{key} must not itself be a symbolic link: {config.paths[key]!r}"
            )

    _validate_mapping_roles(config)

    for key in DIRECTORY_KEYS:
        target = config.path(key)
        _validate_directory_target(config.repo, target, field=f"paths.{key}")

    _validate_file_target(config.repo, config.todo_file, field="paths.todo")
    _validate_file_target(config.repo, config.governance_path, field="governance_file")
    if config.canonical_instruction_path is not None:
        _validate_file_target(
            config.repo,
            config.canonical_instruction_path,
            field="canonical_instruction",
        )


def default_config(repo: Path) -> GovernanceConfig:
    repo = repo.resolve()
    config = GovernanceConfig(
        repo=repo,
        source_path=None,
        declared=False,
        canonical_instruction=None,
        governance_file=DEFAULT_GOVERNANCE_FILE,
        paths=dict(DEFAULT_PATHS),
    )
    _validate_mapping_targets(config)
    _validate_document_role_name(config.paths["todo"], field="paths.todo")
    _validate_document_role_name(config.governance_file, field="governance_file")
    return config


def load_config(repo: Path, explicit: str | Path | None = None) -> GovernanceConfig:
    repo = repo.resolve()
    source = _resolve_config_path(repo, explicit)
    if source is None:
        return default_config(repo)

    try:
        data = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"cannot parse {source.relative_to(repo)}: {exc}") from exc
    if not isinstance(data, dict):
        raise ConfigError("governance configuration root must be a JSON object")
    if data.get("version", 1) != 1:
        raise ConfigError(f"unsupported governance configuration version: {data.get('version')!r}")

    raw_paths = data.get("paths")
    if not isinstance(raw_paths, dict):
        raise ConfigError("paths must be an object containing all governance categories")
    missing = [key for key in REQUIRED_PATH_KEYS if key not in raw_paths]
    unknown = sorted(set(raw_paths) - set(REQUIRED_PATH_KEYS))
    if missing:
        raise ConfigError(f"paths is missing required keys: {', '.join(missing)}")
    if unknown:
        raise ConfigError(f"paths contains unknown keys: {', '.join(unknown)}")

    paths: dict[str, str] = {}
    for key in REQUIRED_PATH_KEYS:
        paths[key] = _normalize_relative_path(
            raw_paths[key],
            field=f"paths.{key}",
            expect_file=(key == "todo"),
        )

    governance_file = _normalize_relative_path(
        data.get("governance_file", DEFAULT_GOVERNANCE_FILE),
        field="governance_file",
        expect_file=True,
    )
    canonical = data.get("canonical_instruction")
    if canonical is not None:
        canonical = _normalize_relative_path(canonical, field="canonical_instruction", expect_file=True)

    config = GovernanceConfig(
        repo=repo,
        source_path=source,
        declared=True,
        canonical_instruction=canonical,
        governance_file=governance_file,
        paths=paths,
    )
    _validate_mapping_targets(config)
    _validate_document_role_name(config.paths["todo"], field="paths.todo")
    _validate_document_role_name(config.governance_file, field="governance_file")
    if config.canonical_instruction is not None:
        _validate_document_role_name(config.canonical_instruction, field="canonical_instruction")
    return config


def common_governance_root(config: GovernanceConfig) -> Path | None:
    """Return a useful common parent for governed directories, or None if too broad."""

    directories = [config.path(key) for key in DIRECTORY_KEYS]
    common = Path(os.path.commonpath([str(path) for path in directories]))
    try:
        rel = common.relative_to(config.repo)
    except ValueError:
        return None
    if not rel.parts:
        return None
    return common
