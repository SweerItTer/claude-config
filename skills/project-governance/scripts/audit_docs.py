#!/usr/bin/env python3
"""Audit project documentation governance with evidence-based findings."""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import unquote, urlsplit

from governance_config import (
    ConfigError,
    GovernanceConfig,
    common_governance_root,
    load_config,
)

FRONTMATTER_RE = re.compile(r"\A---\s*\n(.*?)\n---\s*\n?", re.DOTALL)
ID_RE = re.compile(r"(?<![A-Z0-9])([RS]\d{2,})(?!\d)")
IDENTITY_FILENAME_RE = re.compile(r"^([RS]\d{2,})(?:$|[-_. ])")
VERSIONED_NAME_RE = re.compile(r"(?:^|[-_.])(v\d+|final|latest|new|old)(?:[-_.]|$)", re.IGNORECASE)
ABSOLUTE_PATH_RE = re.compile(r"(?:/home/[^\s)`'\"]+|/Users/[^\s)`'\"]+|[A-Za-z]:\\Users\\[^\s)`'\"]+)")
SESSION_STATE_RE = re.compile(
    r"\b(resume checklist|next session|session checkpoint|continue next time|agent memory)\b|下次会话|会话断点|续接清单",
    re.IGNORECASE,
)
DECISION_RE = re.compile(r"^#{2,6}\s+D\d+\b|^[-*]\s*\*\*D\d+\*\*", re.MULTILINE)
FENCED_CODE_RE = re.compile(r"(^|\n)[ \t]*(```|~~~).*?\n.*?\n[ \t]*\2[ \t]*(?=\n|$)", re.DOTALL)
INLINE_CODE_RE = re.compile(r"(`+)(?!`)(.*?)(?<!`)\1(?!`)", re.DOTALL)
IGNORED_DIRS = {".git", ".hg", ".svn", "node_modules", ".venv", "venv", "vendor", "build", "install", "dist"}
VALID_SPEC_STATUS = {"draft", "active", "implemented", "archived"}
VALID_SPEC_KIND = {"design", "plan"}


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


def iter_document_files(repo: Path, config: GovernanceConfig) -> Iterable[Path]:
    """Yield documentation and instruction text, never source-code files.

    Governance audit may report documentation defects, but it must not create
    findings that pressure the Agent to edit Python, shell, JSON, or YAML source.
    """

    suffixes = {".md", ".markdown", ".mdx", ".rst", ".txt"}
    instruction_names = {
        "AGENTS.md",
        "CLAUDE.md",
        "CONTRIBUTING.md",
        "OPENCODE.md",
        ".cursorrules",
        ".windsurfrules",
    }
    for path in repo.rglob("*"):
        if not path.is_file() or is_ignored(path, repo, config):
            continue
        if path.suffix.lower() in suffixes or path.name in instruction_names:
            yield path


def iter_markdown_under(*roots: Path) -> Iterable[Path]:
    seen: set[Path] = set()
    for root in roots:
        if not root.is_dir():
            continue
        for path in root.rglob("*.md"):
            resolved = path.resolve()
            if resolved not in seen:
                seen.add(resolved)
                yield path


def parse_frontmatter(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8", errors="replace")
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


def add(
    report: dict[str, list[dict[str, Any]]],
    level: str,
    code: str,
    detail: str,
    path: Path | None = None,
    repair: str | None = None,
) -> None:
    item: dict[str, Any] = {"code": code, "detail": detail}
    if path is not None:
        item["path"] = path.as_posix()
    if repair:
        item["repair"] = repair
    report[level].append(item)


@dataclass(frozen=True)
class MarkdownLink:
    label: str
    destination: str
    start: int
    end: int
    destination_start: int
    destination_end: int
    reference_style: bool = False


def _is_escaped(text: str, index: int) -> bool:
    backslashes = 0
    index -= 1
    while index >= 0 and text[index] == "\\":
        backslashes += 1
        index -= 1
    return backslashes % 2 == 1


def _find_balanced_bracket(text: str, start: int) -> int | None:
    depth = 0
    for index in range(start, len(text)):
        char = text[index]
        if _is_escaped(text, index):
            continue
        if char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
            if depth == 0:
                return index
    return None


def _normalize_reference_label(label: str) -> str:
    return " ".join(label.split()).casefold()


def _unescape_destination(value: str) -> str:
    return re.sub(r"\\([\\`*{}\[\]()#+.!_<> ])", r"\1", value)


def _parse_link_title(text: str, index: int) -> int | None:
    if index >= len(text):
        return None
    opener = text[index]
    if opener in {'"', "'"}:
        index += 1
        while index < len(text):
            if text[index] == opener and not _is_escaped(text, index):
                return index + 1
            index += 1
        return None
    if opener == "(":
        depth = 1
        index += 1
        while index < len(text):
            if _is_escaped(text, index):
                index += 1
                continue
            if text[index] == "(":
                depth += 1
            elif text[index] == ")":
                depth -= 1
                if depth == 0:
                    return index + 1
            index += 1
    return None


def _parse_inline_destination(text: str, open_paren: int) -> tuple[str, int, int, int] | None:
    index = open_paren + 1
    while index < len(text) and text[index].isspace():
        index += 1
    if index >= len(text):
        return None

    if text[index] == "<":
        destination_start = index + 1
        index += 1
        while index < len(text):
            if text[index] == ">" and not _is_escaped(text, index):
                destination_end = index
                index += 1
                break
            if text[index] in "\r\n":
                return None
            index += 1
        else:
            return None
    else:
        destination_start = index
        depth = 0
        while index < len(text):
            char = text[index]
            if _is_escaped(text, index):
                index += 1
                continue
            if char == "(":
                depth += 1
            elif char == ")":
                if depth == 0:
                    destination_end = index
                    destination = _unescape_destination(text[destination_start:destination_end])
                    return destination, destination_start, destination_end, index + 1
                depth -= 1
            elif char.isspace() and depth == 0:
                destination_end = index
                break
            index += 1
        else:
            return None

    while index < len(text) and text[index].isspace():
        index += 1
    if index < len(text) and text[index] == ")":
        destination = _unescape_destination(text[destination_start:destination_end])
        return destination, destination_start, destination_end, index + 1

    title_end = _parse_link_title(text, index)
    if title_end is None:
        return None
    index = title_end
    while index < len(text) and text[index].isspace():
        index += 1
    if index >= len(text) or text[index] != ")":
        return None
    destination = _unescape_destination(text[destination_start:destination_end])
    return destination, destination_start, destination_end, index + 1


def _parse_definition_destination(text: str, start: int, end: int) -> tuple[str, int, int] | None:
    index = start
    while index < end and text[index] in " \t":
        index += 1
    if index >= end:
        return None
    if text[index] == "<":
        destination_start = index + 1
        close = text.find(">", destination_start, end)
        if close < 0:
            return None
        return _unescape_destination(text[destination_start:close]), destination_start, close

    destination_start = index
    depth = 0
    while index < end:
        char = text[index]
        if _is_escaped(text, index):
            index += 1
            continue
        if char == "(":
            depth += 1
        elif char == ")" and depth:
            depth -= 1
        elif char in " \t" and depth == 0:
            break
        index += 1
    if index == destination_start:
        return None
    return _unescape_destination(text[destination_start:index]), destination_start, index


def reference_definitions(text: str) -> tuple[dict[str, tuple[str, int, int]], list[tuple[int, int]]]:
    definitions: dict[str, tuple[str, int, int]] = {}
    spans: list[tuple[int, int]] = []
    pattern = re.compile(r"(?m)^[ \t]{0,3}\[([^\]\n]+)\]:[ \t]*(.*)$")
    for match in pattern.finditer(text):
        parsed = _parse_definition_destination(text, match.start(2), match.end(2))
        if parsed is None:
            continue
        destination, start, end = parsed
        definitions.setdefault(_normalize_reference_label(match.group(1)), (destination, start, end))
        spans.append((match.start(), match.end()))
    return definitions, spans


def parse_markdown_links(text: str) -> list[MarkdownLink]:
    definitions, definition_lines = reference_definitions(text)
    links: list[MarkdownLink] = []
    index = 0
    while index < len(text):
        open_bracket = text.find("[", index)
        if open_bracket < 0:
            break
        if _is_escaped(text, open_bracket) or any(start <= open_bracket < end for start, end in definition_lines):
            index = open_bracket + 1
            continue
        close_bracket = _find_balanced_bracket(text, open_bracket)
        if close_bracket is None:
            break
        label = text[open_bracket + 1 : close_bracket]
        cursor = close_bracket + 1

        if cursor < len(text) and text[cursor] == "(":
            parsed = _parse_inline_destination(text, cursor)
            if parsed is not None:
                destination, destination_start, destination_end, link_end = parsed
                links.append(
                    MarkdownLink(label, destination, open_bracket, link_end, destination_start, destination_end)
                )
                index = link_end
                continue

        reference_label: str | None = None
        link_end = close_bracket + 1
        if cursor < len(text) and text[cursor] == "[":
            ref_end = _find_balanced_bracket(text, cursor)
            if ref_end is not None:
                raw_reference = text[cursor + 1 : ref_end]
                reference_label = raw_reference if raw_reference else label
                link_end = ref_end + 1
        else:
            normalized = _normalize_reference_label(label)
            if normalized in definitions:
                reference_label = label

        if reference_label is not None:
            definition = definitions.get(_normalize_reference_label(reference_label))
            if definition is not None:
                destination, destination_start, destination_end = definition
                links.append(
                    MarkdownLink(
                        label,
                        destination,
                        open_bracket,
                        link_end,
                        destination_start,
                        destination_end,
                        reference_style=True,
                    )
                )
                index = link_end
                continue
        index = close_bracket + 1
    return links


def resolve_link(path: Path, raw_target: str) -> Path | None:
    target = raw_target.strip()
    if not target or target.startswith("#"):
        return None

    # CommonMark destinations may use any absolute URI scheme, not only HTTP.
    # Network-path references (//host/path) are external as well. Online
    # reachability belongs to a separate link checker; this audit checks only
    # repository-relative and file-relative destinations.
    parsed = urlsplit(target)
    if parsed.scheme or parsed.netloc or target.startswith("//"):
        return None

    local_target = unquote(parsed.path).strip()
    if not local_target:
        return None
    return (path.parent / local_target).resolve()


def configured_category(path: Path, config: GovernanceConfig) -> str | None:
    for key in ("requirement", "specs", "dev_guide", "analysis", "archive"):
        if is_under(path, config.path(key)):
            return key
    return None


def strip_fenced_code(text: str) -> str:
    return FENCED_CODE_RE.sub("\n", text)


def strip_inline_code(text: str) -> str:
    return INLINE_CODE_RE.sub("", text)


def strip_markdown_code(text: str) -> str:
    """Remove fenced and inline code before interpreting Markdown links/references."""

    return strip_inline_code(strip_fenced_code(text))


def visible_markdown_text(paragraph: str) -> str:
    """Keep link labels but remove inline/reference destinations before looking for semantic IDs."""

    links = sorted(parse_markdown_links(paragraph), key=lambda item: (item.start, item.end))
    if not links:
        return paragraph
    chunks: list[str] = []
    cursor = 0
    for link in links:
        if link.start < cursor:
            continue
        chunks.append(paragraph[cursor:link.start])
        chunks.append(link.label)
        cursor = link.end
    chunks.append(paragraph[cursor:])
    return "".join(chunks)


def paragraph_for_offset(text: str, offset: int) -> str:
    start = text.rfind("\n\n", 0, offset)
    end = text.find("\n\n", offset)
    return text[start + 2 if start >= 0 else 0 : end if end >= 0 else len(text)]


def semantic_reference_present(paragraph: str, prefix: str, target_id: str | None) -> bool:
    visible = visible_markdown_text(paragraph)
    ids = set(ID_RE.findall(visible))
    if target_id:
        return target_id in ids
    return any(item.startswith(prefix) for item in ids)


def path_based_reference_findings(path: Path, text: str, config: GovernanceConfig) -> list[str]:
    """Return path-only R/S references while allowing semantic ID plus navigation links."""
    clean = strip_markdown_code(text)
    findings: list[str] = []
    seen_spans: set[tuple[int, int]] = set()

    # Markdown links can use ../ paths, balanced parentheses, titles, or references.
    links = parse_markdown_links(clean)
    _, definition_lines = reference_definitions(clean)
    for link in links:
        target = resolve_link(path, link.destination)
        if target is None:
            continue
        category = None
        prefix = None
        if is_under(target, config.specs_dir):
            category, prefix = "specs", "S"
        elif is_under(target, config.requirement_dir):
            category, prefix = "requirement", "R"
        if category is None or "_TEMPLATE" in target.name:
            seen_spans.add((link.destination_start, link.destination_end))
            continue
        paragraph = paragraph_for_offset(clean, link.start)
        target_ids = [item for item in ID_RE.findall(target.stem) if item.startswith(prefix)]
        target_id = target_ids[0] if target_ids else None
        if not semantic_reference_present(paragraph, prefix, target_id):
            findings.append(link.destination)
        seen_spans.add((link.destination_start, link.destination_end))
    for start, end in definition_lines:
        seen_spans.add((start, end))

    # Also catch visible bare repository paths outside Markdown link destinations.
    for category, prefix, directory in (
        ("specs", "S", config.paths["specs"]),
        ("requirement", "R", config.paths["requirement"]),
    ):
        pattern = re.compile(rf"(?<![\w./-]){re.escape(directory.rstrip('/'))}/[^\s)`'\"]+\.md")
        for match in pattern.finditer(clean):
            if any(start <= match.start() < end for start, end in seen_spans):
                continue
            if "_TEMPLATE.md" in match.group(0):
                continue
            paragraph = paragraph_for_offset(clean, match.start())
            target_ids = [item for item in ID_RE.findall(Path(match.group(0)).stem) if item.startswith(prefix)]
            target_id = target_ids[0] if target_ids else None
            if not semantic_reference_present(paragraph, prefix, target_id):
                findings.append(match.group(0))

    return list(dict.fromkeys(findings))


NEGATIVE_AUTHORITY_RE = re.compile(
    r"\b(ignore|disregard|override|supersede|do\s+not\s+follow|don['’]t\s+follow)\b",
    re.IGNORECASE,
)


def instruction_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace").strip()


def symlink_points_to(path: Path, target: Path, repo: Path) -> bool:
    if not path.is_symlink():
        return False
    try:
        resolved = path.resolve(strict=True)
        resolved.relative_to(repo.resolve())
        return resolved == target.resolve(strict=True)
    except (OSError, RuntimeError, ValueError):
        return False


def _resolve_adapter_destination(repo: Path, adapter: Path, destination: str) -> Path | None:
    raw = destination.strip()
    parsed = urlsplit(raw)
    if parsed.scheme or parsed.netloc or raw.startswith("#"):
        return None
    value = unquote(parsed.path)
    if not value:
        return None
    try:
        resolved = (adapter.parent / value).resolve(strict=False)
        resolved.relative_to(repo.resolve())
    except (OSError, RuntimeError, ValueError):
        return None
    return resolved


def is_strict_instruction_adapter(text: str, canonical: Path, adapter: Path, repo: Path) -> bool:
    """Accept only a one-purpose adapter that resolves to the exact canonical path."""

    if NEGATIVE_AUTHORITY_RE.search(text):
        return False
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    while lines and lines[0].startswith("#"):
        lines.pop(0)
    if len(lines) != 1:
        return False
    line = lines[0].strip()
    canonical_resolved = canonical.resolve(strict=False)

    links = parse_markdown_links(line)
    if links:
        if len(links) != 1:
            return False
        link = links[0]
        wrapper = line[: link.start] + "{LINK}" + line[link.end :]
        wrapper_patterns = (
            r"(?i)^(?:follow|use|see)\s+(?:the\s+)?(?:canonical\s+)?(?:repository\s+)?(?:instructions?\s+(?:in|at)\s+)?\{LINK\}(?:\s+as\s+the\s+canonical\s+repository\s+instructions?)?\.?$",
            r"^\{LINK\}\.?$",
        )
        if not any(re.fullmatch(pattern, wrapper) for pattern in wrapper_patterns):
            return False
        resolved = _resolve_adapter_destination(repo, adapter, link.destination)
        return resolved == canonical_resolved

    plain_patterns = (
        r"(?i)^(?:follow|use|see)\s+(?:the\s+)?(?:canonical\s+)?(?:repository\s+)?(?:instructions?\s+(?:in|at)\s+)?`?([^`\s]+)`?(?:\s+as\s+the\s+canonical\s+repository\s+instructions?)?\.?$",
        r"^@(.+)$",
    )
    destination: str | None = None
    for pattern in plain_patterns:
        match = re.fullmatch(pattern, line)
        if match:
            destination = match.group(1).rstrip(".")
            break
    if destination is None:
        return False
    resolved = _resolve_adapter_destination(repo, adapter, destination)
    return resolved == canonical_resolved

def report_instruction_pair(
    repo: Path,
    canonical: Path,
    adapter: Path,
    report: dict[str, list[dict[str, Any]]],
) -> None:
    canonical_rel = canonical.relative_to(repo).as_posix()
    adapter_rel = adapter.relative_to(repo).as_posix()
    if symlink_points_to(adapter, canonical, repo):
        add(
            report,
            "pass",
            "INSTRUCTION_ADAPTER_SYMLINK",
            f"{adapter_rel} is a symlink to canonical instruction {canonical_rel}.",
            adapter.relative_to(repo),
        )
        return
    if adapter.is_symlink():
        add(
            report,
            "blocking",
            "INSTRUCTION_ADAPTER_UNSAFE_SYMLINK",
            f"{adapter_rel} is a symlink, but not to canonical instruction {canonical_rel} inside the repository.",
            adapter.relative_to(repo),
            f"Point it directly to {canonical_rel} or replace it with a strict one-line adapter.",
        )
        return
    canonical_text = instruction_text(canonical)
    adapter_text = instruction_text(adapter)
    if adapter_text == canonical_text:
        add(
            report,
            "improve",
            "DUPLICATED_INSTRUCTION_SOURCE",
            f"{adapter_rel} duplicates {canonical_rel}; the files agree now but can drift.",
            adapter.relative_to(repo),
            f"Replace {adapter_rel} with a symlink or strict adapter to {canonical_rel}.",
        )
        return
    if is_strict_instruction_adapter(adapter_text, canonical, adapter, repo):
        add(
            report,
            "pass",
            "INSTRUCTION_ADAPTER_STRICT",
            f"{adapter_rel} is a strict adapter to canonical instruction {canonical_rel}.",
            adapter.relative_to(repo),
        )
        return
    detail = f"{adapter_rel} is an independent instruction source and is not a strict adapter to {canonical_rel}."
    if NEGATIVE_AUTHORITY_RE.search(adapter_text):
        detail += " It contains an explicit ignore/override relationship."
    add(
        report,
        "blocking",
        "CONFLICTING_INSTRUCTION_SOURCES",
        detail,
        adapter.relative_to(repo),
        f"Use a filesystem symlink, declare {canonical_rel} as canonical and make {adapter_rel} a strict adapter, or remove the competing rules.",
    )


def audit_root_instruction_pair(
    repo: Path,
    report: dict[str, list[dict[str, Any]]],
) -> None:
    agents = repo / "AGENTS.md"
    claude = repo / "CLAUDE.md"
    present = [path for path in (agents, claude) if path.exists() or path.is_symlink()]
    if len(present) == 2:
        if symlink_points_to(claude, agents, repo):
            add(report, "pass", "INSTRUCTION_RELATION_EXPLICIT", "CLAUDE.md is a symlink to AGENTS.md.")
        elif symlink_points_to(agents, claude, repo):
            add(report, "pass", "INSTRUCTION_RELATION_EXPLICIT", "AGENTS.md is a symlink to CLAUDE.md.")
        elif (
            not agents.is_symlink()
            and not claude.is_symlink()
            and is_strict_instruction_adapter(instruction_text(claude), agents, claude, repo)
        ):
            add(report, "pass", "INSTRUCTION_RELATION_EXPLICIT", "CLAUDE.md is a strict adapter to AGENTS.md.")
        elif (
            not agents.is_symlink()
            and not claude.is_symlink()
            and is_strict_instruction_adapter(instruction_text(agents), claude, agents, repo)
        ):
            add(report, "pass", "INSTRUCTION_RELATION_EXPLICIT", "AGENTS.md is a strict adapter to CLAUDE.md.")
        elif not agents.is_symlink() and not claude.is_symlink() and instruction_text(agents) == instruction_text(claude):
            add(
                report,
                "improve",
                "DUPLICATED_INSTRUCTION_SOURCE",
                "AGENTS.md and CLAUDE.md are identical copies but have no durable canonical relationship.",
                repair="Declare one canonical source and replace the other with a symlink or strict adapter.",
            )
        else:
            add(
                report,
                "blocking",
                "CONFLICTING_INSTRUCTION_SOURCES",
                "AGENTS.md and CLAUDE.md are independent instruction files without a strict canonical relationship.",
                repair="Choose one canonical source and make the other a filesystem symlink or strict one-line adapter.",
            )
    elif len(present) == 1:
        if present[0].is_symlink():
            add(
                report,
                "blocking",
                "CANONICAL_INSTRUCTION_UNSAFE_SYMLINK",
                f"The only instruction file, {present[0].name}, is a symlink without an explicit canonical declaration.",
                present[0].relative_to(repo),
            )
        else:
            add(report, "pass", "CANONICAL_INSTRUCTION_PRESENT", "At least one repository instruction file is present.")
    else:
        add(
            report,
            "improve",
            "CANONICAL_INSTRUCTION_MISSING",
            "No AGENTS.md or CLAUDE.md instruction source is present.",
            repair="Create one canonical repository instruction file and keep tool-specific files as strict adapters.",
        )


def audit_instruction_authority(
    repo: Path,
    config: GovernanceConfig,
    report: dict[str, list[dict[str, Any]]],
) -> None:
    agents = repo / "AGENTS.md"
    claude = repo / "CLAUDE.md"

    if config.canonical_instruction:
        canonical = config.canonical_instruction_path
        assert canonical is not None
        if canonical.exists() and canonical.is_file() and not canonical.is_symlink():
            add(
                report,
                "pass",
                "CANONICAL_INSTRUCTION_DECLARED",
                f"Canonical instruction source is declared as {config.canonical_instruction}.",
                Path(config.canonical_instruction),
            )
            for candidate in (agents, claude):
                if not candidate.exists() and not candidate.is_symlink():
                    continue
                if candidate.resolve(strict=False) == canonical.resolve(strict=False):
                    continue
                report_instruction_pair(repo, canonical, candidate, report)
        else:
            add(
                report,
                "fix",
                "CANONICAL_INSTRUCTION_DECLARED_MISSING",
                f"Configured canonical instruction file is missing or not a regular file: {config.canonical_instruction}.",
                Path(config.canonical_instruction),
                "Create the declared regular file or correct .project-governance.json.",
            )
            audit_root_instruction_pair(repo, report)
    else:
        audit_root_instruction_pair(repo, report)


def audit_skill_source(repo: Path) -> dict[str, list[dict[str, Any]]]:
    """Audit the Skill package as a Skill source tree, not as an application repository."""

    report: dict[str, list[dict[str, Any]]] = {"blocking": [], "fix": [], "improve": [], "pass": []}
    skill_md = repo / "SKILL.md"
    if not skill_md.is_file():
        add(report, "blocking", "SKILL_MD_MISSING", "Skill source mode requires SKILL.md at the repository root.", Path("SKILL.md"))
        return report

    fm = parse_frontmatter(skill_md)
    missing = sorted({"name", "description"} - set(fm))
    if missing:
        add(report, "fix", "SKILL_FRONTMATTER_MISSING", f"SKILL.md is missing frontmatter fields: {', '.join(missing)}.", Path("SKILL.md"))
    else:
        add(report, "pass", "SKILL_FRONTMATTER_PRESENT", "SKILL.md declares name and description.", Path("SKILL.md"))

    runtime_docs: list[Path] = [skill_md]
    for root_name in ("references", "assets"):
        root = repo / root_name
        if root.is_dir():
            runtime_docs.extend(path for path in root.rglob("*.md") if path.is_file())

    absolute_count = 0
    broken_count = 0
    scanned_links = 0
    for path in sorted(set(runtime_docs)):
        rel = path.relative_to(repo)
        text = path.read_text(encoding="utf-8", errors="replace")
        if ABSOLUTE_PATH_RE.search(text):
            absolute_count += 1
            add(report, "fix", "MACHINE_ABSOLUTE_PATH", "Contains a developer-machine absolute path.", rel)
        if path.suffix.lower() in {".md", ".markdown", ".mdx"}:
            seen: set[tuple[str, int, int]] = set()
            for link in parse_markdown_links(strip_markdown_code(text)):
                key = (link.destination, link.destination_start, link.destination_end)
                if key in seen:
                    continue
                seen.add(key)
                resolved = resolve_link(path, link.destination)
                if resolved is None:
                    continue
                scanned_links += 1
                if not resolved.exists():
                    broken_count += 1
                    add(report, "fix", "BROKEN_MARKDOWN_LINK", f"Broken relative link: {link.destination}.", rel)

    if absolute_count == 0:
        add(report, "pass", "NO_MACHINE_ABSOLUTE_PATHS", "No developer-machine absolute paths were detected in Skill runtime documentation.", Path("."))
    if broken_count == 0:
        add(report, "pass", "NO_BROKEN_MARKDOWN_LINKS", f"Checked {scanned_links} relative Markdown links in Skill runtime documentation; none were broken.", Path("."))

    if (repo / "scripts").is_dir():
        add(report, "pass", "SKILL_SCRIPTS_PRESENT", "Bundled deterministic scripts directory is present.", Path("scripts"))
    if (repo / "references").is_dir():
        add(report, "pass", "SKILL_REFERENCES_PRESENT", "Progressively loaded reference material is present.", Path("references"))
    if (repo / "evals" / "evals.json").is_file():
        add(report, "pass", "SKILL_EVALS_PRESENT", "Evaluation scenarios are present in the source package.", Path("evals/evals.json"))

    add(
        report,
        "pass",
        "SKILL_SOURCE_PROFILE",
        "Skill-source audit profile is active; application-repository taxonomy, TODO, and canonical-instruction requirements are intentionally not applied.",
        Path("."),
    )
    for key in report:
        report[key].sort(key=lambda item: (item.get("path", ""), item["code"], item["detail"]))
    return report

def audit(repo: Path, explicit_config: str | None = None) -> dict[str, list[dict[str, Any]]]:
    report: dict[str, list[dict[str, Any]]] = {"blocking": [], "fix": [], "improve": [], "pass": []}
    try:
        config = load_config(repo, explicit_config)
    except ConfigError as exc:
        add(
            report,
            "blocking",
            "GOVERNANCE_CONFIG_INVALID",
            str(exc),
            repair=(
                "Keep one valid governance configuration whose lexical paths and resolved symlink destinations "
                "remain inside the repository."
            ),
        )
        return report

    if config.declared:
        add(
            report,
            "pass",
            "GOVERNANCE_MAPPING_DECLARED",
            "Repository-specific documentation responsibilities are explicitly mapped.",
            config.source_path.relative_to(repo) if config.source_path else None,
        )
    else:
        add(
            report,
            "pass",
            "DEFAULT_MAPPING_SELECTED",
            "No repository mapping file was found; default paths are used only as the fallback governance layout.",
        )

    audit_instruction_authority(repo, config, report)

    directory_keys = ("requirement", "specs", "dev_guide", "analysis", "archive")
    missing_dirs = [config.paths[key] for key in directory_keys if not config.path(key).is_dir()]
    if missing_dirs:
        code = "CONFIGURED_TAXONOMY_INCOMPLETE" if config.declared else "TAXONOMY_UNDECLARED_OR_INCOMPLETE"
        repair = (
            "Create the missing configured directories or correct the mapping file."
            if config.declared
            else "If the repository has a coherent custom taxonomy, declare it in .project-governance.json; otherwise bootstrap the default directories."
        )
        add(
            report,
            "fix",
            code,
            f"Missing governed directories: {', '.join(missing_dirs)}.",
            repair=repair,
        )
    else:
        add(
            report,
            "pass",
            "TAXONOMY_PRESENT",
            "All configured documentation responsibilities have directories.",
            common_governance_root(config).relative_to(repo) if common_governance_root(config) else Path("."),
        )

    id_paths: dict[str, list[Path]] = defaultdict(list)
    numbered: list[tuple[Path, str, dict[str, str], str]] = []
    all_governed_md = list(
        iter_markdown_under(
            config.requirement_dir,
            config.specs_dir,
            config.dev_guide_dir,
            config.analysis_dir,
            config.archive_dir,
        )
    )
    for path in all_governed_md:
        if is_ignored(path, repo, config) or path.name.startswith("_TEMPLATE"):
            continue
        rel = path.relative_to(repo)
        identity_match = IDENTITY_FILENAME_RE.match(path.stem)
        identity = identity_match.group(1) if identity_match else None

        # A stable identity is owned only by a Requirement, Spec, or archived
        # Requirement/Spec. Guides and analyses may mention S14/R03 in their
        # filenames without becoming a second identity-bearing document.
        if is_under(path, config.requirement_dir):
            numbered.append((path, "R", parse_frontmatter(path), "active"))
            if identity and identity.startswith("R"):
                id_paths[identity].append(rel)
        elif is_under(path, config.specs_dir):
            numbered.append((path, "S", parse_frontmatter(path), "active"))
            if identity and identity.startswith("S"):
                id_paths[identity].append(rel)
        elif is_under(path, config.archive_dir) and identity:
            numbered.append((path, identity[0], parse_frontmatter(path), "archive"))
            id_paths[identity].append(rel)

    duplicates = {stable_id: paths for stable_id, paths in id_paths.items() if len(paths) > 1}
    for stable_id, paths in sorted(duplicates.items()):
        add(
            report,
            "blocking",
            "DUPLICATE_STABLE_ID",
            f"{stable_id} appears in {len(paths)} paths: {', '.join(p.as_posix() for p in paths)}.",
            repair="Resolve identity collision without silently renumbering an established document.",
        )
    if id_paths and not duplicates:
        add(report, "pass", "STABLE_IDS_UNIQUE", f"Checked {len(id_paths)} R/S IDs across active and archived documents; all are unique.")

    metadata_pass = 0
    updated_dates = Counter()
    for path, prefix, fm, location in numbered:
        rel = path.relative_to(repo)
        stem_ids = [item for item in ID_RE.findall(path.stem) if item.startswith(prefix)]
        if not stem_ids:
            add(report, "fix", "STABLE_ID_MISSING", f"Expected a {prefix} ID at the start of the filename.", rel, f"Assign or restore a stable {prefix} ID using repository evidence.")
        elif not path.stem.startswith(stem_ids[0]):
            add(report, "fix", "STABLE_ID_NOT_PREFIX", f"Filename contains {stem_ids[0]} but does not begin with it.", rel, "Rename with a filesystem move so the stable ID is the filename prefix; leave the Git index unstaged for review.")

        required = {"title", "created", "source"} if prefix == "R" else {"title", "status", "kind", "created", "updated"}
        missing = sorted(required - set(fm))
        if missing:
            add(report, "fix", "FRONTMATTER_MISSING", f"Missing fields: {', '.join(missing)}.", rel, "Add values supported by file content or Git history; leave unknown optional values blank.")
        else:
            metadata_pass += 1

        if prefix == "S":
            status = fm.get("status")
            kind = fm.get("kind")
            if status and status not in VALID_SPEC_STATUS:
                add(report, "fix", "SPEC_STATUS_INVALID", f"Invalid status: {status}.", rel, f"Use one of: {', '.join(sorted(VALID_SPEC_STATUS))}.")
            if kind and kind not in VALID_SPEC_KIND:
                add(report, "fix", "SPEC_KIND_INVALID", f"Invalid kind: {kind}.", rel, f"Use one of: {', '.join(sorted(VALID_SPEC_KIND))}.")
            if location == "archive" and status and status != "archived":
                add(report, "fix", "ARCHIVE_STATUS_MISMATCH", f"Archived Spec has status {status!r}.", rel, "Set status to archived if the document is truly no longer maintained.")
            if location == "active" and fm.get("updated"):
                updated_dates[fm["updated"]] += 1
            text = path.read_text(encoding="utf-8", errors="replace")
            if not DECISION_RE.search(text):
                add(report, "improve", "DECISION_RECORDS_ABSENT", "No numbered Dn decision record was detected.", rel, "Add decision records only for actual consequential choices; do not invent them.")

    if metadata_pass:
        add(report, "pass", "NUMBERED_METADATA_VALID", f"{metadata_pass} numbered documents contain the required default metadata.")

    root = common_governance_root(config)
    loose: list[Path] = []
    if root and root.is_dir():
        protected = {config.todo_file.resolve(), config.governance_path.resolve()}
        if config.source_path:
            protected.add(config.source_path.resolve())
        for path in root.glob("*.md"):
            if path.resolve() not in protected:
                loose.append(path.relative_to(repo))
    if len(loose) > 10:
        add(report, "fix", "DOCS_TOP_LEVEL_DUMP", f"Governance root contains {len(loose)} loose Markdown files.", root.relative_to(repo) if root else None, "Classify them by responsibility or document an explicit top-level policy.")
    elif loose:
        add(report, "improve", "DOCS_TOP_LEVEL_LOOSE", f"Top-level documentation candidates: {', '.join(p.name for p in loose)}.", root.relative_to(repo) if root else None, "Review whether each belongs in a governed category.")
    elif root:
        add(report, "pass", "DOCS_TOP_LEVEL_CLEAN", "No loose top-level Markdown documents were found outside configured special files.", root.relative_to(repo))

    absolute_count = broken_count = versioned_count = session_count = path_only_count = scanned_links = 0
    for path in sorted(set(iter_document_files(repo, config))):
        rel = path.relative_to(repo)
        text = path.read_text(encoding="utf-8", errors="replace")

        if ABSOLUTE_PATH_RE.search(text):
            absolute_count += 1
            add(report, "fix", "MACHINE_ABSOLUTE_PATH", "Contains a developer-machine absolute path.", rel, "Replace repository-local paths with relative paths; retain deployment paths such as /etc only when intentional.")

        if path.suffix.lower() in {".md", ".markdown", ".mdx"}:
            if VERSIONED_NAME_RE.search(path.stem):
                versioned_count += 1
                add(report, "fix", "VERSIONED_FILENAME", "Filename encodes lifecycle or version.", rel, "Use a stable ID, status, supersedes metadata, and Git history.")

            if SESSION_STATE_RE.search(text) and not is_under(path, config.archive_dir):
                session_count += 1
                add(report, "fix", "SESSION_STATE_COMMITTED", "Contains session-resume or temporary Agent-state language.", rel, "Promote durable facts to Requirement, Spec, guide, or TODO; keep transient state outside committed governance.")

            path_refs = path_based_reference_findings(path, text, config)
            if path_refs and not is_under(path, config.archive_dir):
                path_only_count += 1
                add(
                    report,
                    "improve",
                    "PATH_BASED_RS_REFERENCE",
                    f"Uses a Requirement or Spec path without a visible matching semantic ID: {', '.join(path_refs[:3])}.",
                    rel,
                    "Add a visible stable identity such as S14《Title》 or R03《Title》; keep the relative link as optional navigation.",
                )

            seen_link_targets: set[tuple[str, int, int]] = set()
            for link in parse_markdown_links(strip_markdown_code(text)):
                key = (link.destination, link.destination_start, link.destination_end)
                if key in seen_link_targets:
                    continue
                seen_link_targets.add(key)
                resolved = resolve_link(path, link.destination)
                if resolved is None:
                    continue
                scanned_links += 1
                if not resolved.exists():
                    broken_count += 1
                    add(report, "fix", "BROKEN_MARKDOWN_LINK", f"Broken relative link: {link.destination}.", rel, "Repair the link; for R/S documents keep semantic identity independent of the path.")

    if absolute_count == 0:
        add(report, "pass", "NO_MACHINE_ABSOLUTE_PATHS", "No developer-machine absolute paths were detected.", Path("."))
    if broken_count == 0:
        add(report, "pass", "NO_BROKEN_MARKDOWN_LINKS", f"Checked {scanned_links} relative Markdown links; none were broken.", root.relative_to(repo) if root else Path("."))
    if versioned_count == 0:
        add(report, "pass", "NO_VERSIONED_FILENAMES", "No v2/final/latest/new/old lifecycle filenames were detected.", root.relative_to(repo) if root else Path("."))
    if session_count == 0:
        add(report, "pass", "NO_SESSION_STATE", "No obvious session-resume state was detected in maintained documents.", root.relative_to(repo) if root else Path("."))
    if path_only_count == 0:
        add(report, "pass", "NO_PATH_ONLY_RS_REFERENCES", "No maintained document used a Requirement or Spec path without a visible matching semantic ID.", root.relative_to(repo) if root else Path("."))

    if updated_dates:
        date, count = updated_dates.most_common(1)[0]
        total = sum(updated_dates.values())
        if total >= 5 and count / total >= 0.8:
            add(report, "improve", "UPDATED_DATE_CLUSTER", f"{count} of {total} active Specs share updated={date}; this may be a bulk refresh.", config.specs_dir.relative_to(repo), "Confirm the date reflects substantive changes rather than migration cosmetics.")

    todo = config.todo_file
    if todo.exists():
        text = todo.read_text(encoding="utf-8", errors="replace")
        lines = len(text.splitlines())
        completed = len(re.findall(r"^\s*[-*]\s*\[[xX]\]", text, re.MULTILINE))
        pending = len(re.findall(r"^\s*[-*]\s*\[ \]", text, re.MULTILINE))
        if completed:
            add(report, "fix", "TODO_COMPLETED_HISTORY", f"TODO contains {completed} completed checklist item(s).", todo.relative_to(repo), f"Move completed history under {config.paths['archive']} and keep pending work here.")
        elif lines > 200:
            add(report, "improve", "TODO_LARGE", f"TODO has {lines} lines and may need decomposition or archival.", todo.relative_to(repo), "Keep current actionable work and move history or durable rules to their configured destinations.")
        else:
            add(report, "pass", "TODO_CURRENT", f"TODO contains {pending} pending and no completed checklist items.", todo.relative_to(repo))
    else:
        add(report, "improve", "TODO_MISSING", f"Configured TODO file was not found: {config.paths['todo']}.", Path(config.paths["todo"]), "Create it only if the project uses a repository-local work queue.")

    for key in report:
        report[key].sort(key=lambda item: (item.get("path", ""), item["code"], item["detail"]))
    return report


def print_text(report: dict[str, list[dict[str, Any]]]) -> None:
    labels = (("blocking", "Blocking"), ("fix", "Fix"), ("improve", "Improve"), ("pass", "Pass"))
    for key, label in labels:
        items = report[key]
        print(f"## {label} ({len(items)})")
        if not items:
            print("- None")
            print()
            continue
        for item in items:
            location = f" [{item['path']}]" if item.get("path") else ""
            print(f"- {item['code']}{location}: {item['detail']}")
            if item.get("repair"):
                print(f"  - Repair: {item['repair']}")
        print()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", help="Repository root")
    parser.add_argument("--config", help="Explicit repository-relative governance JSON file")
    parser.add_argument("--skill-source", action="store_true", help="Audit a Skill package instead of an application repository")
    parser.add_argument("--json", action="store_true", help="Emit JSON")
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    if not repo.exists() or not repo.is_dir():
        parser.error(f"Repository path is not a directory: {repo}")

    report = audit_skill_source(repo) if args.skill_source else audit(repo, args.config)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print_text(report)
    return 2 if report["blocking"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
