#!/usr/bin/env python3
"""Protect pre-existing Git work while project-governance reorganizes documents."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

from governance_config import CONFIG_CANDIDATES, ConfigError, GovernanceConfig, load_config

SNAPSHOT_VERSION = 10
STATE_ORDER = ("staged", "unstaged", "untracked", "ignored", "index-hidden")
DOCUMENT_EXTENSIONS = {".md", ".markdown", ".rst", ".txt"}
INSTRUCTION_NAMES = {"AGENTS.md", "CLAUDE.md", "CONTRIBUTING.md", "OPENCODE.md"}
RESERVED_NON_DOCUMENT_NAMES = {
    "Makefile", "GNUmakefile", "CMakeLists.txt", "Kconfig", "Dockerfile", "Jenkinsfile",
    "meson.build", "SConstruct", "BUILD", "BUILD.bazel", ".config",
}
RESERVED_NON_DOCUMENT_PREFIXES = ("Kconfig.", "Dockerfile.", "Jenkinsfile.")



class GuardError(RuntimeError):
    """Raised when the workspace guard cannot establish a safe baseline."""


def run_git_proc(
    repo: Path,
    args: list[str],
    *,
    input_bytes: bytes | None = None,
) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            ["git", "-C", str(repo), *args],
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise GuardError(str(exc)) from exc


def run_git(repo: Path, args: list[str], *, binary: bool = False) -> bytes | str:
    proc = run_git_proc(repo, args)
    if proc.returncode != 0:
        message = proc.stderr.decode("utf-8", errors="replace").strip()
        raise GuardError(message or f"git {' '.join(args)} failed with exit {proc.returncode}")
    return proc.stdout if binary else proc.stdout.decode("utf-8", errors="replace").strip()


def ensure_git_repo(repo: Path) -> str:
    root = str(run_git(repo, ["rev-parse", "--show-toplevel"]))
    if Path(root).resolve() != repo.resolve():
        raise GuardError(f"--repo must be the Git repository root: {root}")
    return root


def split_nul(data: bytes) -> list[str]:
    return [item.decode("utf-8", errors="surrogateescape") for item in data.split(b"\0") if item]


def dirty_paths(repo: Path) -> dict[str, set[str]]:
    """Return staged, unstaged, and ordinary untracked paths.

    Ignored paths are discovered lazily by ``check-plan`` so large ignored build
    trees are not fingerprinted unless a planned governance operation intersects
    them. Renames are expanded into delete/add paths so both names are protected.
    """

    staged = set(
        split_nul(
            run_git(
                repo,
                ["diff", "--cached", "--name-only", "-z", "--no-renames", "--diff-filter=ACDMRTUXB"],
                binary=True,
            )
        )
    )
    unstaged = set(
        split_nul(
            run_git(
                repo,
                ["diff", "--name-only", "-z", "--no-renames", "--diff-filter=ACDMRTUXB"],
                binary=True,
            )
        )
    )
    untracked = set(split_nul(run_git(repo, ["ls-files", "--others", "--exclude-standard", "-z"], binary=True)))
    return {"staged": staged, "unstaged": unstaged, "untracked": untracked}


def normalize_repo_path(value: str) -> str:
    raw = value.replace("\\", "/").strip()
    if not raw:
        raise GuardError("planned path cannot be empty")
    pure = PurePosixPath(raw)
    if pure.is_absolute() or ".." in pure.parts:
        raise GuardError(f"planned path must stay inside the repository: {value!r}")
    normalized = pure.as_posix()
    if not normalized or normalized == ".":
        raise GuardError("planned path cannot be the repository root")
    return normalized


def resolved_repo_path(repo: Path, rel: str) -> str:
    """Resolve existing symlink ancestors and return a repository-relative path."""

    normalized = normalize_repo_path(rel)
    lexical = Path(os.path.abspath(repo / normalized))
    try:
        lexical.relative_to(repo)
    except ValueError as exc:
        raise GuardError(f"planned path escapes the repository lexically: {rel}") from exc
    try:
        resolved = (repo / normalized).resolve(strict=False)
    except (OSError, RuntimeError) as exc:
        raise GuardError(f"cannot resolve planned path safely: {rel}: {exc}") from exc
    try:
        return resolved.relative_to(repo.resolve()).as_posix()
    except ValueError as exc:
        raise GuardError(f"planned path resolves outside the repository: {rel} -> {resolved}") from exc


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        raise GuardError(f"cannot hash {path}: {exc}") from exc
    return digest.hexdigest()


def directory_listing_hash(path: Path) -> str:
    """Hash immediate directory entries so additions/removals are observable."""

    rows: list[bytes] = []
    try:
        entries = sorted(path.iterdir(), key=lambda item: os.fsencode(item.name))
        for entry in entries:
            info = entry.lstat()
            kind = stat.S_IFMT(info.st_mode)
            rows.append(
                b"\0".join(
                    (
                        os.fsencode(entry.name),
                        str(kind).encode("ascii"),
                        f"{stat.S_IMODE(info.st_mode):04o}".encode("ascii"),
                    )
                )
            )
    except OSError as exc:
        raise GuardError(f"cannot inspect directory {path}: {exc}") from exc
    digest = hashlib.sha256()
    for row in rows:
        digest.update(row)
        digest.update(b"\n")
    return digest.hexdigest()


def fingerprint_worktree_path(path: Path) -> dict[str, Any]:
    """Capture worktree existence, type, mode, content, and symlink target."""

    try:
        info = path.lstat()
    except FileNotFoundError:
        return {"kind": "missing", "exists": False, "mode": None, "sha256": None, "link_target": None}
    except OSError as exc:
        raise GuardError(f"cannot inspect {path}: {exc}") from exc

    mode = f"{stat.S_IMODE(info.st_mode):04o}"
    if stat.S_ISLNK(info.st_mode):
        try:
            target = os.readlink(path)
        except OSError as exc:
            raise GuardError(f"cannot read symlink {path}: {exc}") from exc
        target_bytes = os.fsencode(target)
        return {
            "kind": "symlink",
            "exists": True,
            "mode": mode,
            "sha256": hashlib.sha256(target_bytes).hexdigest(),
            "link_target": target,
        }
    if stat.S_ISREG(info.st_mode):
        return {
            "kind": "file",
            "exists": True,
            "mode": mode,
            "sha256": hash_file(path),
            "link_target": None,
            "st_dev": int(info.st_dev),
            "st_ino": int(info.st_ino),
            "st_nlink": int(info.st_nlink),
        }
    if stat.S_ISDIR(info.st_mode):
        return {
            "kind": "directory",
            "exists": True,
            "mode": mode,
            "sha256": directory_listing_hash(path),
            "link_target": None,
        }
    if stat.S_ISFIFO(info.st_mode):
        kind = "fifo"
    elif stat.S_ISSOCK(info.st_mode):
        kind = "socket"
    elif stat.S_ISCHR(info.st_mode):
        kind = "char-device"
    elif stat.S_ISBLK(info.st_mode):
        kind = "block-device"
    else:
        kind = "special"
    return {
        "kind": kind,
        "exists": True,
        "mode": mode,
        "sha256": None,
        "link_target": None,
        "rdev": int(info.st_rdev),
    }


def index_entries_for_paths(repo: Path, paths: list[str]) -> dict[str, list[dict[str, Any]]]:
    """Return all index stages for each literal repository path."""

    result: dict[str, list[dict[str, Any]]] = {path: [] for path in paths}
    if not paths:
        return result

    for start in range(0, len(paths), 200):
        batch = paths[start : start + 200]
        raw = run_git(
            repo,
            ["--literal-pathspecs", "ls-files", "--stage", "-z", "--", *batch],
            binary=True,
        )
        assert isinstance(raw, bytes)
        for record in raw.split(b"\0"):
            if not record:
                continue
            try:
                metadata, raw_path = record.split(b"\t", 1)
                mode, oid, raw_stage = metadata.decode("ascii").split()
                rel = raw_path.decode("utf-8", errors="surrogateescape")
                stage_number = int(raw_stage)
            except (ValueError, UnicodeDecodeError) as exc:
                raise GuardError(f"cannot parse git index entry: {record!r}") from exc
            result.setdefault(rel, []).append({"mode": mode, "oid": oid, "stage": stage_number})

    for entries in result.values():
        entries.sort(key=lambda item: (item["stage"], item["mode"], item["oid"]))
    return result


def all_index_entries(repo: Path) -> dict[str, list[dict[str, Any]]]:
    """Return the complete Git index, including intent-to-add and conflict stages."""

    raw = run_git(repo, ["ls-files", "--stage", "-z"], binary=True)
    assert isinstance(raw, bytes)
    result: dict[str, list[dict[str, Any]]] = {}
    for record in raw.split(b"\0"):
        if not record:
            continue
        try:
            metadata, raw_path = record.split(b"\t", 1)
            mode, oid, raw_stage = metadata.decode("ascii").split()
            rel = raw_path.decode("utf-8", errors="surrogateescape")
            stage_number = int(raw_stage)
        except (ValueError, UnicodeDecodeError) as exc:
            raise GuardError(f"cannot parse git index entry: {record!r}") from exc
        result.setdefault(rel, []).append({"mode": mode, "oid": oid, "stage": stage_number})
    for entries in result.values():
        entries.sort(key=lambda item: (item["stage"], item["mode"], item["oid"]))
    return dict(sorted(result.items()))


def all_index_flags(repo: Path) -> dict[str, str]:
    """Return the per-path ``git ls-files -v`` tag for the complete index.

    Uppercase ``S`` means skip-worktree. Lowercase tags indicate
    assume-unchanged; lowercase ``s`` can represent both flags. Comparing this
    map closes status/diff blind spots created by index extension flags.
    """

    raw = run_git(repo, ["ls-files", "-v", "-z"], binary=True)
    assert isinstance(raw, bytes)
    result: dict[str, str] = {}
    for record in raw.split(b"\0"):
        if not record:
            continue
        if len(record) < 3 or record[1:2] != b" ":
            raise GuardError(f"cannot parse git index flag record: {record!r}")
        try:
            tag = record[:1].decode("ascii")
        except UnicodeDecodeError as exc:
            raise GuardError(f"cannot parse git index flag tag: {record!r}") from exc
        rel = record[2:].decode("utf-8", errors="surrogateescape")
        result[rel] = tag
    return dict(sorted(result.items()))


def hidden_index_paths(flags: dict[str, str]) -> set[str]:
    """Return paths whose worktree changes may be hidden by Git index flags."""

    return {path for path, tag in flags.items() if tag == "S" or tag.islower()}


def check_ignored_paths(repo: Path, paths: Iterable[str], *, no_index: bool = False) -> set[str]:
    values = sorted({normalize_repo_path(item) for item in paths})
    if not values:
        return set()
    payload = b"\0".join(os.fsencode(item) for item in values) + b"\0"
    command = ["check-ignore"]
    if no_index:
        command.append("--no-index")
    command.extend(["-z", "--stdin"])
    proc = run_git_proc(repo, command, input_bytes=payload)
    if proc.returncode in (0, 1):
        return set(split_nul(proc.stdout))

    message = proc.stderr.decode("utf-8", errors="replace").strip()
    if "beyond a symbolic link" not in message:
        raise GuardError(message or "git check-ignore failed")

    # A single alias/child path can make batched check-ignore abort. Retry
    # individually and skip only pathspecs that Git refuses because they pass
    # through a tracked symlink; their resolved in-repository counterparts are
    # checked separately by the caller.
    result: set[str] = set()
    for value in values:
        one = run_git_proc(
            repo,
            ["check-ignore", *(["--no-index"] if no_index else []), "-z", "--stdin"],
            input_bytes=os.fsencode(value) + b"\0",
        )
        if one.returncode in (0, 1):
            result.update(split_nul(one.stdout))
            continue
        one_message = one.stderr.decode("utf-8", errors="replace").strip()
        if "beyond a symbolic link" in one_message:
            continue
        raise GuardError(one_message or f"git check-ignore failed for {value}")
    return result


def ignored_files_under(repo: Path, rel: str) -> set[str]:
    proc = run_git_proc(
        repo,
        ["ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--", rel],
    )
    if proc.returncode != 0:
        message = proc.stderr.decode("utf-8", errors="replace").strip()
        # Git rejects a pathspec that traverses a tracked symlink. The caller
        # also queries the resolved in-repository path, which is the meaningful
        # location for overlap protection.
        if "beyond a symbolic link" in message:
            return set()
        raise GuardError(message or f"git ls-files failed for {rel}")
    return set(split_nul(proc.stdout))


def existing_ancestors(repo: Path, rel: str) -> list[str]:
    pure = PurePosixPath(normalize_repo_path(rel))
    result: list[str] = []
    current = Path()
    for part in pure.parts:
        current = current / part
        candidate = repo / current
        if candidate.exists() or candidate.is_symlink():
            result.append(current.as_posix())
    return result


def discover_relevant_ignored(repo: Path, planned: Iterable[str]) -> set[str]:
    """Find ignored paths that overlap a planned source/destination.

    This lazy enrollment avoids hashing unrelated ignored build trees while still
    protecting exact ignored files, ignored ancestors, and ignored descendants of
    a planned directory.
    """

    candidates: set[str] = set()
    for rel in planned:
        real_rel = resolved_repo_path(repo, rel)
        queries = {rel, real_rel}
        # ``--no-index`` lets Git evaluate ignore rules for destinations that do
        # not exist yet. Without this, a planned ignored output can be created and
        # remain invisible to both status and final verification.
        candidates.update(check_ignored_paths(repo, queries, no_index=True))
        for query in queries:
            candidates.update(ignored_files_under(repo, query))
        ancestors = existing_ancestors(repo, rel) + existing_ancestors(repo, real_rel)
        candidates.update(check_ignored_paths(repo, ancestors, no_index=True))
        # Add ignored parent directories of discovered files so directory content
        # changes are also observable after a blocked plan is ignored.
        parent_candidates: set[str] = set()
        for item in list(candidates):
            pure = PurePosixPath(item)
            parent_candidates.update(parent.as_posix() for parent in pure.parents if parent.as_posix() != ".")
        candidates.update(check_ignored_paths(repo, parent_candidates, no_index=True))
    # A tracked path can match an ignore pattern under ``--no-index`` but is not
    # status-invisible. Keep only genuinely untracked/missing ignored paths.
    tracked = set(all_index_entries(repo))
    # Missing exact destinations are intentionally retained. They are enrolled as
    # ``kind=missing`` and block the plan before the first write.
    return {item for item in candidates if item not in tracked}


def classify_path_states(
    repo: Path,
    rel: str,
    states: dict[str, set[str]],
    ignored: set[str],
    hidden: set[str],
) -> list[str]:
    result = [name for name in ("staged", "unstaged", "untracked") if rel in states[name]]
    if rel in ignored:
        result.append("ignored")
    if rel in hidden:
        result.append("index-hidden")
    return result


def head_and_branch(repo: Path) -> tuple[str | None, str | None]:
    try:
        head = str(run_git(repo, ["rev-parse", "HEAD"]))
    except GuardError:
        head = None
    branch = str(run_git(repo, ["branch", "--show-current"]))
    return head, branch or None


def gitlink_paths(index_snapshot: dict[str, list[dict[str, Any]]]) -> list[str]:
    return sorted(
        path
        for path, entries in index_snapshot.items()
        if any(entry.get("mode") == "160000" and entry.get("stage") == 0 for entry in entries)
    )


def is_initialized_git_worktree(path: Path) -> bool:
    if not path.is_dir():
        return False
    proc = run_git_proc(path, ["rev-parse", "--show-toplevel"])
    if proc.returncode != 0:
        return False
    root = proc.stdout.decode("utf-8", errors="replace").strip()
    try:
        return Path(root).resolve() == path.resolve()
    except OSError:
        return False


def submodule_status(repo: Path) -> list[str]:
    """Return visible staged/unstaged/untracked state for an initialized submodule."""

    raw = run_git(repo, ["status", "--porcelain=v1", "-z", "--untracked-files=all"], binary=True)
    assert isinstance(raw, bytes)
    return split_nul(raw)


def stage0_gitlink_oid(entries: list[dict[str, Any]]) -> str | None:
    for entry in entries:
        if entry.get("mode") == "160000" and entry.get("stage") == 0:
            return str(entry.get("oid"))
    return None


def capture_submodules(repo: Path, index_snapshot: dict[str, list[dict[str, Any]]]) -> dict[str, dict[str, Any]]:
    """Capture clean, no-touch submodule boundaries and fail closed on hidden state."""

    result: dict[str, dict[str, Any]] = {}
    for rel in gitlink_paths(index_snapshot):
        expected_oid = stage0_gitlink_oid(index_snapshot.get(rel, []))
        sub_repo = repo / rel
        initialized = is_initialized_git_worktree(sub_repo)
        row: dict[str, Any] = {
            "initialized": initialized,
            "gitlink_oid": expected_oid,
        }
        if initialized:
            head, branch = head_and_branch(sub_repo)
            dirty = submodule_status(sub_repo)
            nested_index = all_index_entries(sub_repo)
            nested_gitlinks = gitlink_paths(nested_index)
            if nested_gitlinks:
                raise GuardError(
                    f"nested submodules inside a no-touch submodule are not supported: {rel}: "
                    + ", ".join(nested_gitlinks[:10])
                    + ". Handle the submodule manually or run audit-only mode."
                )
            nested_flags = all_index_flags(sub_repo)
            hidden = sorted(hidden_index_paths(nested_flags))
            if hidden:
                raise GuardError(
                    f"submodule contains assume-unchanged/skip-worktree paths and cannot be safely protected: "
                    f"{rel}: {', '.join(hidden[:10])}. Clear the flags manually or run audit-only mode."
                )
            if dirty or head != expected_oid:
                detail = ", ".join(dirty[:10]) if dirty else f"HEAD {head} differs from gitlink {expected_oid}"
                raise GuardError(
                    f"dirty submodule is not supported by Project Governance takeover: {rel}: {detail}. "
                    "Commit/stash/clean it manually or run audit-only mode."
                )
            row.update({
                "head": head,
                "branch": branch,
                "dirty": [],
                "index_snapshot": nested_index,
                "index_flags_snapshot": nested_flags,
            })
        result[rel] = row
    return result

def config_from_snapshot(repo: Path, raw: dict[str, Any]) -> GovernanceConfig:
    source = raw.get("source")
    return GovernanceConfig(
        repo=repo,
        source_path=(repo / source) if isinstance(source, str) and source else None,
        declared=bool(raw.get("declared")),
        canonical_instruction=raw.get("canonical_instruction"),
        governance_file=str(raw["governance_file"]),
        paths={str(key): str(value) for key, value in dict(raw["paths"]).items()},
    )


def canonical_json_sha256(value: Any) -> str:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def immutable_snapshot(data: dict[str, Any]) -> dict[str, Any]:
    value = data.get("snapshot")
    if not isinstance(value, dict):
        raise GuardError("baseline is missing immutable snapshot data")
    return value


def authorization_state(data: dict[str, Any]) -> dict[str, Any]:
    value = data.get("authorization")
    if not isinstance(value, dict):
        raise GuardError("baseline is missing mutable authorization state")
    return value


def protected_rows(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    snapshot = immutable_snapshot(data)
    authorization = authorization_state(data)
    rows = dict(snapshot["preexisting"])
    rows.update(authorization.get("enrolled_ignored", {}))
    return rows


def make_snapshot(repo: Path) -> dict[str, Any]:
    ensure_git_repo(repo)
    states = dirty_paths(repo)
    index_snapshot = all_index_entries(repo)
    index_flags = all_index_flags(repo)
    hidden = hidden_index_paths(index_flags)
    combined = sorted(set().union(*states.values(), hidden))
    submodule_paths = gitlink_paths(index_snapshot)
    nested = nested_git_roots(repo, combined, submodule_paths)
    if nested:
        raise GuardError(
            "Nested Git worktrees are not supported by Project Governance takeover: "
            + ", ".join(nested)
            + ". Move the governance target outside the nested worktree or handle it manually."
        )
    index_entries = index_entries_for_paths(repo, combined)
    rows: dict[str, dict[str, Any]] = {}
    for rel in combined:
        rows[rel] = {
            "states": classify_path_states(repo, rel, states, set(), hidden),
            "worktree": fingerprint_worktree_path(repo / rel),
            "index": index_entries.get(rel, []),
            "index_flag": index_flags.get(rel),
            "resolved_path": resolved_repo_path(repo, rel),
        }
    head, branch = head_and_branch(repo)
    snapshot = {
        "created_at": datetime.now(timezone.utc).isoformat(),
        "repo": str(repo.resolve()),
        "head": head,
        "branch": branch,
        "preexisting": rows,
        "index_snapshot": index_snapshot,
        "index_flags_snapshot": index_flags,
        "submodules": capture_submodules(repo, index_snapshot),
    }
    return {
        "version": SNAPSHOT_VERSION,
        "snapshot": snapshot,
        "snapshot_sha256": canonical_json_sha256(snapshot),
        "authorization": {
            "revision": 0,
            "approved_paths": [],
            "approved_ignored_snapshot": [],
            "enrolled_ignored": {},
            "governance_config": None,
        },
    }


def ensure_baseline_outside_repo(repo: Path, path: Path) -> Path:
    """Return the resolved baseline path, rejecting repository-owned guard state."""
    repo_real = repo.resolve()
    baseline_real = path.resolve(strict=False)
    try:
        baseline_real.relative_to(repo_real)
    except ValueError:
        return baseline_real
    raise GuardError(
        f"baseline file must live outside the repository checkout: {baseline_real}. "
        "Use /tmp, another external temporary directory, or a CI artifact path outside the checkout."
    )


def save_snapshot(path: Path, data: dict[str, Any]) -> None:
    # check-plan may mutate only authorization state. Never persist a baseline
    # whose sealed immutable snapshot no longer matches its capture-time hash.
    snapshot = immutable_snapshot(data)
    expected_hash = data.get("snapshot_sha256")
    if not isinstance(expected_hash, str) or canonical_json_sha256(snapshot) != expected_hash:
        raise GuardError("immutable snapshot hash mismatch; refusing to persist modified snapshot state")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
    except Exception:
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


def validate_snapshot_data(data: dict[str, Any], repo: Path) -> None:
    if data.get("version") != SNAPSHOT_VERSION:
        raise GuardError(
            f"unsupported baseline version: {data.get('version')!r}; create a new baseline with this workspace_guard.py"
        )
    snapshot = immutable_snapshot(data)
    authorization = authorization_state(data)
    expected_hash = data.get("snapshot_sha256")
    if not isinstance(expected_hash, str) or canonical_json_sha256(snapshot) != expected_hash:
        raise GuardError("immutable snapshot hash mismatch; baseline snapshot data was modified after capture")
    if Path(snapshot.get("repo", "")).resolve() != repo.resolve():
        raise GuardError("baseline belongs to a different repository")
    if not isinstance(snapshot.get("preexisting"), dict):
        raise GuardError("baseline is missing preexisting path data")
    if not isinstance(snapshot.get("index_snapshot"), dict):
        raise GuardError("baseline is missing the complete Git index snapshot")
    if not isinstance(snapshot.get("index_flags_snapshot"), dict):
        raise GuardError("baseline is missing Git index extension-flag data")
    if not isinstance(snapshot.get("submodules"), dict):
        raise GuardError("baseline is missing submodule protection data")
    if not isinstance(authorization.get("approved_paths"), list):
        raise GuardError("baseline is missing the approved governance path allowlist")
    if not isinstance(authorization.get("approved_ignored_snapshot"), list):
        raise GuardError("baseline is missing approved-scope ignored-path data")
    if not isinstance(authorization.get("enrolled_ignored"), dict):
        raise GuardError("baseline is missing lazily enrolled ignored-path protection data")
    if not isinstance(authorization.get("revision"), int) or authorization["revision"] < 0:
        raise GuardError("baseline contains invalid authorization revision data")
    if authorization.get("governance_config") is not None and not isinstance(authorization.get("governance_config"), dict):
        raise GuardError("baseline contains invalid governance configuration data")
    for item in authorization["approved_paths"]:
        if (
            not isinstance(item, dict)
            or not isinstance(item.get("lexical"), str)
            or not isinstance(item.get("resolved"), str)
            or item.get("kind") not in {"file", "directory"}
        ):
            raise GuardError("baseline contains an invalid approved path entry")
    for source_name, rows in (("snapshot", snapshot["preexisting"]), ("authorization", authorization["enrolled_ignored"])):
        for rel, row in rows.items():
            if not isinstance(rel, str) or not isinstance(row, dict):
                raise GuardError(f"baseline contains invalid {source_name} path data")
            if (
                not isinstance(row.get("states"), list)
                or not isinstance(row.get("worktree"), dict)
                or not isinstance(row.get("index"), list)
                or not isinstance(row.get("resolved_path"), str)
                or (row.get("index_flag") is not None and not isinstance(row.get("index_flag"), str))
            ):
                raise GuardError(f"baseline entry is incomplete: {rel}")
    for rel, row in snapshot["submodules"].items():
        if not isinstance(rel, str) or not isinstance(row, dict) or not isinstance(row.get("initialized"), bool):
            raise GuardError(f"baseline contains invalid submodule data: {rel!r}")
        if row.get("gitlink_oid") is not None and not isinstance(row.get("gitlink_oid"), str):
            raise GuardError(f"baseline submodule gitlink is invalid: {rel}")
        if row["initialized"]:
            if (
                not isinstance(row.get("head"), str)
                or row.get("dirty") != []
                or not isinstance(row.get("index_snapshot"), dict)
                or not isinstance(row.get("index_flags_snapshot"), dict)
            ):
                raise GuardError(f"baseline initialized submodule entry is incomplete: {rel}")


def load_snapshot(path: Path, repo: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise GuardError(f"cannot read baseline {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise GuardError(f"baseline root must be a JSON object: {path}")
    validate_snapshot_data(data, repo)
    return data


def enroll_ignored_paths(repo: Path, data: dict[str, Any], paths: Iterable[str]) -> int:
    authorization = authorization_state(data)
    existing = set(immutable_snapshot(data)["preexisting"]) | set(authorization["enrolled_ignored"])
    new_paths = sorted(set(paths) - existing)
    if not new_paths:
        return 0
    index_entries = index_entries_for_paths(repo, new_paths)
    index_flags = all_index_flags(repo)
    ignored_now = check_ignored_paths(repo, new_paths, no_index=True)
    hidden = hidden_index_paths(index_flags)
    empty_states = {"staged": set(), "unstaged": set(), "untracked": set()}
    for rel in new_paths:
        authorization["enrolled_ignored"][rel] = {
            "states": classify_path_states(repo, rel, empty_states, ignored_now, hidden),
            "worktree": fingerprint_worktree_path(repo / rel),
            "index": index_entries.get(rel, []),
            "index_flag": index_flags.get(rel),
            "resolved_path": resolved_repo_path(repo, rel),
        }
    return len(new_paths)


def paths_overlap(a: str, b: str) -> bool:
    pa = PurePosixPath(a)
    pb = PurePosixPath(b)
    return pa == pb or pa in pb.parents or pb in pa.parents


def path_is_under(path: str, root: str) -> bool:
    p = PurePosixPath(path)
    r = PurePosixPath(root)
    return p == r or r in p.parents


def selected_config_paths(repo: Path, config: GovernanceConfig) -> set[str]:
    """Return config paths eligible for exact JSON-file planning in this state."""

    if config.source_path is not None:
        return {config.source_path.relative_to(repo).as_posix()}
    return set(CONFIG_CANDIDATES)


def configured_role_files(config: GovernanceConfig) -> set[str]:
    result = {config.paths["todo"], config.governance_file}
    if config.canonical_instruction is not None:
        result.add(config.canonical_instruction)
    return result


def file_content_violation(path: Path) -> str | None:
    """Reject executable, shebang, binary, hard-linked, symlink, and special-file targets."""

    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    except OSError as exc:
        return f"cannot inspect file safely: {exc}"
    if stat.S_ISLNK(info.st_mode):
        return "symbolic-link files are outside the documentation write whitelist"
    if not stat.S_ISREG(info.st_mode):
        return "only regular documentation files may be modified"
    if info.st_nlink > 1:
        return "hard-linked files are outside the safe documentation write boundary"
    if stat.S_IMODE(info.st_mode) & 0o111:
        return "executable files are outside the documentation write whitelist"
    try:
        with path.open("rb") as handle:
            prefix = handle.read(8192)
    except OSError as exc:
        return f"cannot read file safely: {exc}"
    if prefix.startswith(b"#!"):
        return "shebang files are scripts, not governance documents"
    if b"\x00" in prefix:
        return "binary files are outside the documentation write whitelist"
    return None


def documentation_file_violation(repo: Path, rel: str, config: GovernanceConfig) -> str | None:
    """Return a reason when a file path is not explicitly documentation-only."""

    lexical = normalize_repo_path(rel)
    real = resolved_repo_path(repo, lexical)
    candidate = repo / lexical
    config_paths = selected_config_paths(repo, config)
    is_config = lexical in config_paths and real == lexical
    name = PurePosixPath(lexical).name
    real_name = PurePosixPath(real).name

    if is_config:
        if lexical not in CONFIG_CANDIDATES:
            return "governance configuration must use an approved exact candidate path"
        if PurePosixPath(lexical).suffix.lower() != ".json":
            return "governance configuration must be JSON"
    else:
        if (
            name in RESERVED_NON_DOCUMENT_NAMES
            or real_name in RESERVED_NON_DOCUMENT_NAMES
            or name.startswith(RESERVED_NON_DOCUMENT_PREFIXES)
            or real_name.startswith(RESERVED_NON_DOCUMENT_PREFIXES)
        ):
            return "embedded build/configuration filenames are outside the documentation whitelist"
        lexical_ext = PurePosixPath(lexical).suffix.lower()
        real_ext = PurePosixPath(real).suffix.lower()
        if lexical_ext not in DOCUMENT_EXTENSIONS or real_ext not in DOCUMENT_EXTENSIONS:
            return "file extension is not in the documentation whitelist (.md, .markdown, .rst, .txt)"

    violation = file_content_violation(candidate)
    if violation:
        return violation
    return None

def non_document_paths_under(repo: Path, rel: str, config: GovernanceConfig) -> list[str]:
    """Return existing files/symlinks below a plan that violate the document whitelist."""

    result: set[str] = set()
    roots = {normalize_repo_path(rel), resolved_repo_path(repo, rel)}
    seen: set[Path] = set()
    for item in roots:
        candidate = repo / item
        if candidate.is_symlink():
            result.add(f"{item} (symlink)")
            continue
        if candidate.is_file():
            reason = documentation_file_violation(repo, item, config)
            if reason:
                result.add(f"{item} ({reason})")
            continue
        if not candidate.is_dir():
            continue
        try:
            resolved_root = candidate.resolve()
        except (OSError, RuntimeError):
            result.add(f"{item} (cannot resolve directory safely)")
            continue
        if resolved_root in seen:
            continue
        seen.add(resolved_root)
        for current, dirs, files in os.walk(candidate, followlinks=False):
            current_path = Path(current)
            if ".git" in dirs or ".git" in files:
                # Nested Git topology is reported separately with a clearer error.
                dirs[:] = [name for name in dirs if name != ".git"]
                files = [name for name in files if name != ".git"]
            for name in list(dirs):
                child = current_path / name
                if child.is_symlink():
                    try:
                        child_rel = child.relative_to(repo).as_posix()
                    except ValueError:
                        child_rel = str(child)
                    result.add(f"{child_rel} (symlink directory)")
                    dirs.remove(name)
            for name in files:
                child = current_path / name
                try:
                    child_rel = child.relative_to(repo).as_posix()
                except ValueError:
                    result.add(f"{child} (outside repository)")
                    continue
                reason = documentation_file_violation(repo, child_rel, config)
                if reason:
                    result.add(f"{child_rel} ({reason})")
    return sorted(result)


def config_candidate_plan_violation(
    repo: Path,
    planned: Iterable[str],
    approved: Iterable[dict[str, str]],
    config: GovernanceConfig,
) -> str | None:
    candidates = set(CONFIG_CANDIDATES)
    selected = (
        config.source_path.relative_to(repo).as_posix()
        if config.source_path is not None
        else None
    )
    requested = {normalize_repo_path(item) for item in planned if normalize_repo_path(item) in candidates}
    already = {item["lexical"] for item in approved if item.get("lexical") in candidates}
    combined = requested | already
    if selected is not None:
        invalid = combined - {selected}
        if invalid:
            return (
                f"a governance config is already selected at {selected}; second candidate(s) are forbidden: "
                + ", ".join(sorted(invalid))
            )
    elif len(combined) > 1:
        return "only one governance configuration candidate may be approved: " + ", ".join(sorted(combined))
    return None


def governance_scope_reason(repo: Path, rel: str, config: GovernanceConfig) -> str | None:
    """Return scope evidence only for explicit text documents or safe directories."""

    lexical = normalize_repo_path(rel)
    candidate = repo / lexical
    category_roots = {config.paths[key] for key in ("requirement", "specs", "dev_guide", "analysis", "archive")}

    if candidate.is_symlink():
        return None
    if candidate.is_dir() or lexical in category_roots:
        return "documentation directory"

    if documentation_file_violation(repo, lexical, config) is None:
        return "whitelisted documentation file"
    return None


def approved_path_kind(repo: Path, rel: str, config: GovernanceConfig) -> str:
    candidate = repo / rel
    category_roots = {config.paths[key] for key in ("requirement", "specs", "dev_guide", "analysis", "archive")}
    try:
        info = candidate.lstat()
    except FileNotFoundError:
        return "directory" if rel in category_roots else "file"
    if stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode):
        return "directory"
    return "file"


def approved_path_entries(
    repo: Path,
    planned: Iterable[str],
    config: GovernanceConfig,
) -> list[dict[str, str]]:
    return [
        {
            "lexical": rel,
            "resolved": resolved_repo_path(repo, rel),
            "kind": approved_path_kind(repo, rel, config),
        }
        for rel in sorted(set(planned))
    ]


def path_matches_approved(repo: Path, rel: str, approved: Iterable[dict[str, str]]) -> bool:
    real = resolved_repo_path(repo, rel)
    for item in approved:
        if item["kind"] == "file":
            if rel == item["lexical"] and real == item["resolved"]:
                return True
        elif path_is_under(rel, item["lexical"]) and path_is_under(real, item["resolved"]):
            return True
    return False


def ignored_paths_in_approved_scope(repo: Path, approved: Iterable[dict[str, str]]) -> set[str]:
    result: set[str] = set()
    for item in approved:
        queries = {item["lexical"], item["resolved"]}
        result.update(check_ignored_paths(repo, queries, no_index=True))
        if item["kind"] == "directory":
            for query in queries:
                result.update(ignored_files_under(repo, query))
    return {path for path in result if (repo / path).exists() or (repo / path).is_symlink()}


def nested_git_roots(repo: Path, roots: Iterable[str], official_submodules: Iterable[str]) -> list[str]:
    """Find non-submodule nested repositories or linked worktrees touching roots."""

    repo = repo.resolve()
    submodules = {normalize_repo_path(item) for item in official_submodules}
    found: set[str] = set()

    def is_official(rel: str) -> bool:
        return any(path_is_under(rel, sub) for sub in submodules)

    for raw in roots:
        rel = normalize_repo_path(raw)
        candidate = repo / rel
        probe = candidate if candidate.is_dir() else candidate.parent
        while probe != repo and repo in probe.parents:
            try:
                probe_rel = probe.relative_to(repo).as_posix()
            except ValueError:
                break
            if (probe / ".git").exists() or (probe / ".git").is_symlink():
                if not is_official(probe_rel):
                    found.add(probe_rel)
                break
            probe = probe.parent

        if not candidate.is_dir() or candidate.is_symlink():
            continue
        for current, dirs, files in os.walk(candidate, followlinks=False):
            current_path = Path(current)
            try:
                current_rel = current_path.relative_to(repo).as_posix()
            except ValueError:
                dirs[:] = []
                continue
            if is_official(current_rel):
                dirs[:] = []
                continue
            if ".git" in dirs or ".git" in files:
                found.add(current_rel)
                dirs[:] = []
                continue
            dirs[:] = [name for name in dirs if not (current_path / name).is_symlink()]
    return sorted(found)


def planned_submodule_conflicts(repo: Path, planned: Iterable[str], data: dict[str, Any]) -> dict[str, list[str]]:
    conflicts: dict[str, list[str]] = {}
    for target in planned:
        target_real = resolved_repo_path(repo, target)
        hits: list[str] = []
        for submodule in immutable_snapshot(data).get("submodules", {}):
            submodule_real = resolved_repo_path(repo, submodule)
            if paths_overlap(target, submodule) or paths_overlap(target_real, submodule_real):
                hits.append(submodule)
        if hits:
            conflicts[target] = sorted(set(hits))
    return conflicts


def read_planned_paths(args: argparse.Namespace) -> list[str]:
    values = list(args.path or [])
    if args.paths_from:
        try:
            values.extend(
                line.strip()
                for line in Path(args.paths_from).read_text(encoding="utf-8").splitlines()
                if line.strip() and not line.lstrip().startswith("#")
            )
        except OSError as exc:
            raise GuardError(f"cannot read planned paths: {exc}") from exc
    return sorted({normalize_repo_path(item) for item in values})


def command_snapshot(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    output = ensure_baseline_outside_repo(repo, Path(args.output))
    data = make_snapshot(repo)
    save_snapshot(output, data)
    counts = {key: 0 for key in STATE_ORDER}
    for row in immutable_snapshot(data)["preexisting"].values():
        for state_name in row["states"]:
            counts[state_name] += 1
    print(f"baseline: {output}")
    print(
        "pre-existing "
        f"staged={counts['staged']} unstaged={counts['unstaged']} "
        f"untracked={counts['untracked']} ignored-enrolled={counts['ignored']} "
        f"index-hidden={counts['index-hidden']}"
    )
    print(
        "captured: immutable worktree/index/HEAD/submodule snapshot + SHA-256 seal + empty mutable authorization state"
    )
    print("ignored paths are lazily enrolled and fingerprinted by check-plan when a planned path intersects them")
    return 0


def command_check_plan(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    ensure_git_repo(repo)
    baseline_path = ensure_baseline_outside_repo(repo, Path(args.baseline))
    data = load_snapshot(baseline_path, repo)
    planned = read_planned_paths(args)
    if not planned:
        raise GuardError("check-plan requires at least one planned source or destination path")

    try:
        config = load_config(repo, args.config)
    except ConfigError as exc:
        raise GuardError(f"invalid governance configuration: {exc}") from exc
    config_snapshot = config.as_dict()
    authorization = authorization_state(data)
    if authorization.get("governance_config") is not None and authorization["governance_config"] != config_snapshot:
        print("BLOCKING: governance configuration changed between approved batches.")
        print("Create a fresh baseline after reviewing the configuration change.")
        return 2

    config_plan_error = config_candidate_plan_violation(repo, planned, authorization.get("approved_paths", []), config)
    if config_plan_error:
        print("BLOCKING: invalid governance configuration plan.")
        print(f"- {config_plan_error}")
        return 2

    ignored = discover_relevant_ignored(repo, planned)
    enrolled = enroll_ignored_paths(repo, data, ignored)
    if enrolled:
        save_snapshot(baseline_path, data)

    protected = protected_rows(data)
    conflicts: dict[str, list[str]] = {}
    for target in planned:
        target_real = resolved_repo_path(repo, target)
        hits: list[str] = []
        for existing, row in protected.items():
            if paths_overlap(target, existing) or paths_overlap(target_real, row["resolved_path"]):
                hits.append(existing)
        if hits:
            conflicts[target] = sorted(set(hits))

    submodule_conflicts = planned_submodule_conflicts(repo, planned, data)
    for target, hits in submodule_conflicts.items():
        conflicts.setdefault(target, []).extend(f"submodule:{item}" for item in hits)
        conflicts[target] = sorted(set(conflicts[target]))

    governance_roots = [config.paths[key] for key in ("requirement", "specs", "dev_guide", "analysis", "archive")]
    nested = nested_git_roots(repo, [*planned, *governance_roots], immutable_snapshot(data).get("submodules", {}).keys())
    if nested:
        print("BLOCKING: Nested Git worktrees are not supported by Project Governance takeover.")
        for item in nested:
            print(f"- {item}")
        print("Move the governance target outside the nested worktree or handle it manually.")
        return 2

    if conflicts:
        print("BLOCKING: planned governance edits overlap pre-existing user-owned paths or a submodule worktree.")
        if enrolled:
            print(f"- enrolled {enrolled} relevant ignored path(s) into the baseline before blocking")
        for target, hits in conflicts.items():
            target_real = resolved_repo_path(repo, target)
            alias_note = f" (resolved: {target_real})" if target_real != target else ""
            print(f"- {target}{alias_note}: {', '.join(hits)}")
        print("Skip these paths and continue non-overlapping work, or ask the user to resolve/authorize the overlap.")
        return 2

    outside_scope = {rel: governance_scope_reason(repo, rel, config) for rel in planned}
    outside_scope = {rel: reason for rel, reason in outside_scope.items() if reason is None}
    document_conflicts = {rel: non_document_paths_under(repo, rel, config) for rel in planned}
    document_conflicts = {rel: hits for rel, hits in document_conflicts.items() if hits}
    if outside_scope or document_conflicts:
        print("BLOCKING: planned paths exceed the explicit documentation-file whitelist.")
        for rel in sorted(outside_scope):
            print(f"- {rel}")
        for rel, hits in sorted(document_conflicts.items()):
            print(f"- {rel}: contains non-document target(s): {', '.join(hits[:20])}")
            if len(hits) > 20:
                print(f"  ... and {len(hits) - 20} more")
        print(
            "Only .md, .markdown, .rst, .txt, and explicitly configured governance files are writable. "
            "Executable, shebang, binary, symlink, build, source, and unknown-extension files are denied by default."
        )
        return 2

    entries = approved_path_entries(repo, planned, config)
    existing = {(item["lexical"], item["resolved"], item["kind"]) for item in authorization["approved_paths"]}
    added = 0
    for item in entries:
        key = (item["lexical"], item["resolved"], item["kind"])
        if key not in existing:
            authorization["approved_paths"].append(item)
            existing.add(key)
            added += 1
    authorization["approved_paths"].sort(key=lambda item: (item["lexical"], item["resolved"], item["kind"]))
    authorization["governance_config"] = config_snapshot
    # A successful plan has no overlapping ignored path, but retain the exact
    # observed set so verify can detect status-invisible ignored outputs later.
    authorization["approved_ignored_snapshot"] = sorted(ignored_paths_in_approved_scope(repo, authorization["approved_paths"]))
    authorization["revision"] += 1
    save_snapshot(baseline_path, data)

    suffix = f"; enrolled {enrolled} relevant ignored path(s)" if enrolled else ""
    print(
        f"safe plan: {len(planned)} planned path(s) do not overlap "
        f"{len(protected)} protected path(s), submodules, ignored destinations, or documentation whitelist scope{suffix}"
    )
    print(f"approved allowlist entries added: {added}; total: {len(authorization['approved_paths'])}")
    return 0


def verify_snapshot(repo: Path, data: dict[str, Any]) -> dict[str, Any]:
    snapshot = immutable_snapshot(data)
    authorization = authorization_state(data)
    protected = protected_rows(data)
    current_states = dirty_paths(repo)
    current_index_flags = all_index_flags(repo)
    current_hidden = hidden_index_paths(current_index_flags)
    protected_paths = sorted(protected)
    current_index_for_protected = index_entries_for_paths(repo, protected_paths)
    current_ignored = check_ignored_paths(repo, protected_paths)
    current_head, current_branch = head_and_branch(repo)

    changed_preexisting: list[dict[str, Any]] = []
    for rel in protected_paths:
        before = protected[rel]
        after = {
            "states": classify_path_states(repo, rel, current_states, current_ignored, current_hidden),
            "worktree": fingerprint_worktree_path(repo / rel),
            "index": current_index_for_protected.get(rel, []),
            "index_flag": current_index_flags.get(rel),
            "resolved_path": resolved_repo_path(repo, rel),
        }
        reasons: list[str] = []
        if before["worktree"] != after["worktree"]:
            reasons.append("worktree fingerprint changed")
        if before["index"] != after["index"]:
            reasons.append("Git index mode/blob/stage entries changed")
        if before.get("index_flag") != after.get("index_flag"):
            reasons.append("Git index assume-unchanged/skip-worktree tag changed")
        if before["states"] != after["states"]:
            reasons.append("staged/unstaged/untracked/ignored/index-hidden classification changed")
        if before["resolved_path"] != after["resolved_path"]:
            reasons.append("resolved path changed through a symlink or rename")
        if reasons:
            changed_preexisting.append({"path": rel, "reasons": reasons, "before": before, "after": after})

    submodule_results: list[dict[str, Any]] = []
    for rel, before in sorted(snapshot.get("submodules", {}).items()):
        sub_repo = repo / rel
        initialized = is_initialized_git_worktree(sub_repo)
        reasons: list[str] = []
        if initialized != before["initialized"]:
            reasons.append("submodule initialization state changed")
        if initialized and before["initialized"]:
            head, branch = head_and_branch(sub_repo)
            dirty = submodule_status(sub_repo)
            nested_index = all_index_entries(sub_repo)
            nested_flags = all_index_flags(sub_repo)
            if head != before.get("head"):
                reasons.append("submodule HEAD changed")
            if branch != before.get("branch"):
                reasons.append("submodule branch changed")
            if nested_index != before.get("index_snapshot"):
                reasons.append("submodule complete Git index changed")
            if nested_flags != before.get("index_flags_snapshot"):
                reasons.append("submodule assume-unchanged/skip-worktree flags changed")
            if dirty:
                reasons.append("clean submodule became dirty")
        if reasons:
            row = {"path": rel, "reasons": reasons}
            submodule_results.append(row)
            changed_preexisting.append(
                {
                    "path": rel,
                    "reasons": ["submodule boundary changed: " + "; ".join(reasons)],
                    "before": before,
                    "after": {"initialized": initialized},
                }
            )


    approved = authorization.get("approved_paths", [])
    current_visible = sorted(set().union(*current_states.values()))
    baseline = set(protected_paths)
    introduced_visible = {path for path in current_visible if path not in baseline}
    current_approved_ignored = ignored_paths_in_approved_scope(repo, approved)
    baseline_approved_ignored = set(authorization.get("approved_ignored_snapshot", []))
    new_ignored = current_approved_ignored - baseline_approved_ignored
    removed_ignored = baseline_approved_ignored - current_approved_ignored
    introduced = sorted(introduced_visible | new_ignored)
    retained = [path for path in current_visible if path in baseline]
    unapproved_introduced = sorted(path for path in introduced if not path_matches_approved(repo, path, approved))

    config_raw = authorization.get("governance_config")
    baseline_config = config_from_snapshot(repo, config_raw) if isinstance(config_raw, dict) else None
    config: GovernanceConfig | None = None
    config_validation_error: str | None = None
    config_changed = False
    try:
        config = load_config(repo)
        if baseline_config is not None:
            config_changed = config.as_dict() != baseline_config.as_dict()
    except ConfigError as exc:
        config_validation_error = str(exc)

    scope_violations: list[str] = []
    if config is not None:
        for path in introduced:
            if governance_scope_reason(repo, path, config) is None:
                scope_violations.append(path)

    index_before: dict[str, Any] = snapshot["index_snapshot"]
    index_after = all_index_entries(repo)
    index_changed_paths = sorted(
        path for path in set(index_before) | set(index_after) if index_before.get(path) != index_after.get(path)
    )
    new_index_paths = sorted(set(index_after) - set(index_before))
    removed_index_paths = sorted(set(index_before) - set(index_after))

    flags_before: dict[str, str] = snapshot["index_flags_snapshot"]
    flags_after = current_index_flags
    index_flag_changed_paths = sorted(
        path for path in set(flags_before) | set(flags_after) if flags_before.get(path) != flags_after.get(path)
    )

    head_changed = current_head != snapshot.get("head")
    branch_changed = current_branch != snapshot.get("branch")
    authorization_violations: list[str] = []
    if config_validation_error:
        authorization_violations.append("final governance configuration is invalid: " + config_validation_error)
    elif config_changed:
        # A first configuration file may be created only as an isolated batch.
        selected = config.source_path.relative_to(repo).as_posix() if config and config.source_path else None
        baseline_declared = bool(baseline_config.declared) if baseline_config else False
        if not (
            baseline_config is not None
            and not baseline_declared
            and config is not None
            and config.declared
            and selected in CONFIG_CANDIDATES
            and set(introduced) <= {selected}
            and not index_changed_paths
        ):
            authorization_violations.append(
                "governance configuration changed after planning; use a config-only batch and create a fresh baseline"
            )
    if unapproved_introduced:
        authorization_violations.append(
            "changed paths were not approved by check-plan: " + ", ".join(unapproved_introduced)
        )
    if scope_violations:
        authorization_violations.append(
            "approved-directory changes violated documentation-only file-type scope: " + ", ".join(scope_violations)
        )
    if new_ignored or removed_ignored:
        detail = "ignored-path state changed inside approved scope"
        if new_ignored:
            detail += "; new ignored paths: " + ", ".join(sorted(new_ignored))
        if removed_ignored:
            detail += "; removed ignored paths: " + ", ".join(sorted(removed_ignored))
        authorization_violations.append(detail)
    if index_changed_paths:
        detail = "Git index changed after the baseline (mode/blob/stage entries)"
        if new_index_paths:
            detail += "; new paths were staged or added to the index: " + ", ".join(new_index_paths)
        if removed_index_paths:
            detail += "; paths were removed from the index: " + ", ".join(removed_index_paths)
        remaining = sorted(set(index_changed_paths) - set(new_index_paths) - set(removed_index_paths))
        if remaining:
            detail += "; existing index entries changed: " + ", ".join(remaining)
        authorization_violations.append(detail)
    if index_flag_changed_paths:
        authorization_violations.append(
            "Git index assume-unchanged/skip-worktree tags changed after the baseline: "
            + ", ".join(index_flag_changed_paths)
        )
    if head_changed:
        authorization_violations.append(
            f"HEAD changed after the baseline: {snapshot.get('head') or '(unborn)'} -> {current_head or '(unborn)'}"
        )
    if branch_changed:
        authorization_violations.append(
            f"branch changed after the baseline: {snapshot.get('branch') or '(detached)'} -> {current_branch or '(detached)'}"
        )

    return {
        "preexisting_unchanged": not changed_preexisting,
        "authorization_unchanged": not authorization_violations,
        "changed_preexisting": changed_preexisting,
        "submodule_results": submodule_results,
        "authorization_violations": authorization_violations,
        "index_changed_paths": index_changed_paths,
        "index_flag_changed_paths": index_flag_changed_paths,
        "new_index_paths": new_index_paths,
        "head_before": snapshot.get("head"),
        "head_after": current_head,
        "branch_before": snapshot.get("branch"),
        "branch_after": current_branch,
        "approved_paths": approved,
        "introduced_changes": introduced,
        "new_ignored_changes": sorted(new_ignored),
        "unapproved_introduced_changes": unapproved_introduced,
        "scope_violations": scope_violations,
        "retained_preexisting_paths": retained,
        "current_states": {key: sorted(value) for key, value in current_states.items()},
    }


def command_verify(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    ensure_git_repo(repo)
    baseline_path = ensure_baseline_outside_repo(repo, Path(args.baseline))
    data = load_snapshot(baseline_path, repo)
    result = verify_snapshot(repo, data)
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        if result["preexisting_unchanged"]:
            print(
                f"PASS: all {len(protected_rows(data))} protected path(s) and "
                f"{len(immutable_snapshot(data).get('submodules', {}))} clean submodule boundary/boundaries retain protected state"
            )
        else:
            print("BLOCKING: pre-existing user work, ignored-path content, index flags, or submodule state was modified")
            for row in result["changed_preexisting"]:
                print(f"- {row['path']}: {'; '.join(row['reasons'])}")
        if result["authorization_unchanged"]:
            print(
                "PASS: all observed changes match the approved documentation-only plan, and ignored paths, "
                "Git index entries/flags, HEAD, and branch are unchanged"
            )
        else:
            print("BLOCKING: governance authorization boundary was crossed")
            for reason in result["authorization_violations"]:
                print(f"- {reason}")
        print(f"approved-plan changed paths observed: {len(result['introduced_changes'])}")
        for path in result["introduced_changes"]:
            print(f"- {path}")
    safe = result["preexisting_unchanged"] and result["authorization_unchanged"]
    return 0 if safe else 2


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    snapshot = sub.add_parser(
        "snapshot", help="Capture worktree, index, and staged/unstaged/untracked state for pre-existing work"
    )
    snapshot.add_argument("--repo", default=".")
    snapshot.add_argument("--output", required=True)
    snapshot.set_defaults(func=command_snapshot)

    plan = sub.add_parser(
        "check-plan",
        help="Validate and persist documentation-only planned paths after overlap checks",
    )
    plan.add_argument("--repo", default=".")
    plan.add_argument("--baseline", required=True)
    plan.add_argument("--path", action="append", default=[])
    plan.add_argument("--paths-from")
    plan.add_argument("--config", help="Explicit repository-relative governance JSON file")
    plan.set_defaults(func=command_check_plan)

    verify = sub.add_parser(
        "verify",
        help="Verify protected work, approved-path scope, the complete Git index, HEAD, and branch",
    )
    verify.add_argument("--repo", default=".")
    verify.add_argument("--baseline", required=True)
    verify.add_argument("--json", action="store_true")
    verify.set_defaults(func=command_verify)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return int(args.func(args))
    except GuardError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
