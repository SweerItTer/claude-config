#!/usr/bin/env python3
"""Validate a misuse-driven test campaign and its release-gate evidence.

Draft mode reports unfinished content as warnings. ``--strict`` enables a
structure-and-consistency release gate. Visible Markdown is parsed through a Markdown AST.
Optional evidence manifests add reference, lineage and artifact-hash checks. The gate
validates evidence claims and integrity metadata, not evidence authenticity.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, NoReturn

try:
    import mistune
    from jsonschema import Draft202012Validator, FormatChecker
except ImportError:  # pragma: no cover - dependency failure
    mistune = None  # type: ignore[assignment]
    Draft202012Validator = None  # type: ignore[assignment]
    FormatChecker = None  # type: ignore[assignment]

REQUIRED_SECTION_CONCEPTS = {
    "声明": re.compile(r"声明"),
    "状态/行为模型": re.compile(r"状态|行为模型"),
    "场景": re.compile(r"场景"),
    "安全": re.compile(r"安全"),
    "结果/结论": re.compile(r"结果|结论"),
}

CORE_FIELDS = (
    "关联声明",
    "前置状态",
    "正常种子路径",
    "主要误用或故障",
    "操作与时间线",
    "期望不变量",
    "Oracle",
    "Oracle执行状态",
    "Oracle断言总数",
    "Oracle失败数",
    "Oracle输出",
    "扰动命中状态",
    "命中观测来源",
    "扰动落地证据",
    "恢复要求",
    "安全边界与停止条件",
    "复现信息",
    "结果",
)

ALWAYS_SUBSTANTIVE_FIELDS = (
    "关联声明",
    "前置状态",
    "正常种子路径",
    "主要误用或故障",
    "操作与时间线",
    "期望不变量",
    "Oracle",
    "恢复要求",
    "安全边界与停止条件",
    "复现信息",
)

LEGAL_VERDICTS = {
    "PASS-EVIDENCED",
    "FAIL-REPRODUCIBLE",
    "FAIL-NONDETERMINISTIC",
    "INCONCLUSIVE-FAULT-NOT-PROVEN",
    "PARTIAL-ORACLE",
    "BLOCKED-HARNESS",
    "BLOCKED-ENVIRONMENT",
    "NOT-RUN-SAFETY",
    "NOT-RUN",
}
LEGAL_RELEASE_VERDICTS = {"PASS", "CONDITIONAL-PASS", "BLOCKED", "FAIL"}
LEGAL_ORACLE_STATUSES = {"EXECUTED", "PARTIAL", "NOT-EXECUTED"}
LEGAL_LANDING_STATUSES = {"PROVEN", "NOT-PROVEN", "NOT-EXECUTED"}
LEGAL_RECOVERY_STATUSES = {"RESTORED", "PARTIAL", "FAILED", "NOT-REQUIRED", "NOT-VERIFIED"}

EVIDENCE_SCHEMA_PATH = Path(__file__).resolve().parents[1] / "schemas" / "evidence.schema.json"
EVIDENCE_TOKEN_RE = re.compile(r"^EV-[A-Za-z0-9][A-Za-z0-9_.-]*$")
URI_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")
EVIDENCE_REF_SPLIT_RE = re.compile(r"[\s,，、;；/]+")

PLACEHOLDER_RE = re.compile(
    r"(?:\bTODO\b|\bTBD\b|待补充|未填写|尚未填写|待执行|待确认)", re.IGNORECASE
)
NULL_LIKE_VALUES = {
    "无",
    "没有",
    "n/a",
    "na",
    "none",
    "null",
    "不适用",
    "未执行",
    "未测试",
    "未知",
    "x",
    "-",
    "—",
    "/",
}
MISSING_EVIDENCE_PATTERNS = (
    re.compile(r"(?:没有|未)(?:定义|执行|运行|测试|采集|记录|保存|获取|观察|观测|确认|验证|证明|命中|完成|提供)"),
    re.compile(r"(?:未能|无法|不能)(?:证明|确认|验证|获取|观察|观测|复现|执行|记录|命中)"),
    re.compile(r"(?:信息|证据|记录|输出|时间线|复现(?:信息|路径)?)(?:缺失|不存在|未提供|为空)"),
    re.compile(r"(?:缺少|缺失)(?:可执行检查|证据|输出|记录|时间线|复现信息|复现路径)"),
    re.compile(r"\b(?:not executed|not collected|not proven|no evidence|missing evidence|missing output)\b", re.IGNORECASE),
)

FIELD_RE = re.compile(r"^\s*-\s*([^：:\n]+)[：:]\s*(.*)$")
SCENARIO_HEADING_RE = re.compile(r"(?m)^###\s+(S[0-9A-Za-z_-]+)[：:]?\s*([^\n]*)$")
H2_RE = re.compile(r"(?m)^##\s+([^\n]+)$")
FENCE_OPEN_RE = re.compile(r"^\s*(`{3,}|~{3,})(?:[^`~].*)?$")
CLAIM_TOKEN_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]*$")
CLAIM_REF_SPLIT_RE = re.compile(r"[\s,，、;；/]+")

ALIASES = {
    "Oracle 输出": "Oracle输出",
    "Oracle 证据": "Oracle证据",
    "Oracle 执行状态": "Oracle执行状态",
    "Oracle 断言总数": "Oracle断言总数",
    "Oracle 失败数": "Oracle失败数",
    "扰动命中状态": "扰动命中状态",
    "命中观测来源": "命中观测来源",
    "扰动命中证据": "扰动命中证据",
    "复现记录": "复现路径",
    "最小复现": "复现路径",
    "安全/阻塞说明": "阻塞原因",
    "解除阻塞条件": "解除条件",
    "安全替代方案": "替代执行方式",
    "回滚与恢复验证": "恢复验证",
    "回滚/恢复验证": "恢复验证",
    "回滚/恢复步骤": "恢复步骤",
    "最小采集范围及理由": "最小采集范围",
    "存放位置与访问范围": "访问与存放",
    "访问与保存": "访问与存放",
    "保存期限与销毁方式": "保存与销毁",
    "导出复现包复核": "导出复核",
    "脱敏": "脱敏方式",
    "环境恢复结果": "环境恢复证据",
}

SAFETY_REQUIRED_FIELDS = (
    "环境隔离",
    "禁止操作",
    "自动停止条件",
    "恢复验证",
    "证据数据级别",
    "最小采集范围",
    "脱敏方式",
    "访问与存放",
    "保存与销毁",
    "导出复核",
)
RELEASE_REQUIRED_FIELDS = (
    "已验证声明",
    "未验证声明",
    "剩余风险",
    "阻塞项",
    "环境恢复状态",
    "环境恢复证据",
    "发布结论",
)


@dataclass
class Scenario:
    scenario_id: str
    title: str
    fields: dict[str, str] = field(default_factory=dict)
    duplicates: set[str] = field(default_factory=set)
    verdict: str = ""
    claim_ids: set[str] = field(default_factory=set)
    evidence_ids: set[str] = field(default_factory=set)


@dataclass
class ClaimCatalog:
    ids: set[str] = field(default_factory=set)
    statements: dict[str, str] = field(default_factory=dict)
    errors: list[str] = field(default_factory=list)


class ValidationInputError(ValueError):
    pass


def fail_input(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def sha256_file(path: Path, chunk_size: int = 1024 * 1024) -> str:
    """Hash large evidence artifacts without loading them fully into memory."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(chunk_size), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize_unicode(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value)
    return "".join(char for char in normalized if unicodedata.category(char) != "Cf")


def _ast_text(nodes: list[dict[str, Any]] | None) -> str:
    parts: list[str] = []
    for node in nodes or []:
        node_type = node.get("type")
        if node_type in {"text", "codespan"}:
            parts.append(str(node.get("raw", "")))
        elif node_type in {"softbreak", "linebreak"}:
            parts.append(" ")
        elif node_type in {"inline_html", "image"}:
            # HTML/image syntax is data, not a structural field source.
            continue
        else:
            parts.append(_ast_text(node.get("children")))
    return normalize_unicode("".join(parts)).strip()


def _escape_table_cell(value: str) -> str:
    return value.replace("\\", "\\\\").replace("|", "\\|")


def _table_to_markdown(node: dict[str, Any]) -> list[str]:
    children = node.get("children", [])
    head = next((item for item in children if item.get("type") == "table_head"), None)
    body = next((item for item in children if item.get("type") == "table_body"), None)
    if not head:
        return []
    headers = [_escape_table_cell(_ast_text(cell.get("children"))) for cell in head.get("children", [])]
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join("---" for _ in headers) + " |"]
    for row in (body or {}).get("children", []):
        cells = [_escape_table_cell(_ast_text(cell.get("children"))) for cell in row.get("children", [])]
        lines.append("| " + " | ".join(cells) + " |")
    return lines


def _list_item_text(item: dict[str, Any]) -> str:
    chunks: list[str] = []
    for child in item.get("children", []):
        if child.get("type") in {"block_text", "paragraph"}:
            text = _ast_text(child.get("children"))
            if text:
                chunks.append(text)
        # Nested lists and code/html blocks do not create top-level campaign fields.
    return " ".join(chunks).strip()


def strip_non_body_markdown(text: str) -> str:
    """Render only visible top-level Markdown nodes into a deterministic body.

    Fenced/indented code, HTML blocks/comments, block quotes and nested examples
    are ignored by construction rather than removed with regular expressions.
    """
    if mistune is None:
        raise ValidationInputError("missing dependency: mistune>=3.0")
    normalized = normalize_unicode(text)
    markdown = mistune.create_markdown(renderer="ast", plugins=["table"])
    try:
        nodes = markdown(normalized)
    except Exception as exc:  # pragma: no cover - parser defensive path
        raise ValidationInputError(f"cannot parse Markdown: {exc}") from exc
    output: list[str] = []
    for node in nodes:
        node_type = node.get("type")
        if node_type == "heading":
            level = int(node.get("attrs", {}).get("level", 0))
            if level in {1, 2, 3}:
                output.append("#" * level + " " + _ast_text(node.get("children")))
        elif node_type == "table":
            output.extend(_table_to_markdown(node))
        elif node_type == "list":
            for item in node.get("children", []):
                value = _list_item_text(item)
                if value:
                    output.append("- " + value)
        elif node_type == "paragraph":
            value = _ast_text(node.get("children"))
            if value:
                output.append(value)
        elif node_type == "blank_line":
            output.append("")
        elif node_type in {"block_code", "block_html", "block_quote"}:
            continue
        # Unknown block containers are ignored rather than treated as gate data.
    return "\n".join(output)

def normalize_field_name(name: str) -> str:
    cleaned = re.sub(r"[`*_\s]", "", normalize_unicode(name.strip()))
    return ALIASES.get(cleaned, cleaned)


def parse_fields(block: str) -> tuple[dict[str, str], set[str]]:
    fields: dict[str, str] = {}
    duplicates: set[str] = set()
    current_name: str | None = None
    for line in block.splitlines():
        match = FIELD_RE.match(line)
        if match:
            current_name = normalize_field_name(match.group(1))
            value = normalize_unicode(match.group(2).strip())
            if current_name in fields:
                duplicates.add(current_name)
            else:
                fields[current_name] = value
            continue
        if current_name and (line.startswith("  ") or line.startswith("\t")) and line.strip():
            fields[current_name] += "\n" + normalize_unicode(line.strip())
        elif line.strip() and not line.lstrip().startswith("|"):
            current_name = None
    return fields, duplicates


def parse_h2_sections(text: str) -> list[tuple[str, str]]:
    matches = list(H2_RE.finditer(text))
    sections: list[tuple[str, str]] = []
    for index, match in enumerate(matches):
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        sections.append((match.group(1).strip(), text[start:end]))
    return sections


def matching_sections(
    sections: list[tuple[str, str]], pattern: re.Pattern[str]
) -> list[tuple[str, str]]:
    return [(heading, block) for heading, block in sections if pattern.search(heading)]


def parse_scenarios(text: str) -> list[Scenario]:
    matches = list(SCENARIO_HEADING_RE.finditer(text))
    scenarios: list[Scenario] = []
    for match in matches:
        start = match.end()
        next_heading = re.search(r"(?m)^#{2,3}\s+", text[start:])
        end = start + next_heading.start() if next_heading else len(text)
        fields, duplicates = parse_fields(text[start:end])
        scenarios.append(
            Scenario(
                scenario_id=match.group(1),
                title=normalize_unicode(match.group(2).strip()),
                fields=fields,
                duplicates=duplicates,
            )
        )
    return scenarios


def _schema_error_path(error: Any) -> str:
    path = "evidence"
    for part in error.absolute_path:
        path += f"[{part}]" if isinstance(part, int) else f".{part}"
    return path


def load_evidence_manifest(path: Path, *, require_artifacts: bool) -> tuple[set[str], list[str], list[str]]:
    """Validate evidence metadata, lineage, and optionally local artifact hashes."""
    errors: list[str] = []
    warnings: list[str] = []
    if Draft202012Validator is None or FormatChecker is None:
        raise ValidationInputError("missing dependency: jsonschema>=4.20")
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
        schema = json.loads(EVIDENCE_SCHEMA_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValidationInputError(f"evidence file not found: {exc.filename}") from exc
    except UnicodeDecodeError as exc:
        raise ValidationInputError(f"evidence manifest is not valid UTF-8: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ValidationInputError(f"invalid evidence JSON at line {exc.lineno}, column {exc.colno}: {exc.msg}") from exc
    except OSError as exc:
        raise ValidationInputError(f"cannot read evidence manifest/schema: {exc}") from exc

    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    schema_errors = sorted(validator.iter_errors(raw), key=lambda e: list(e.absolute_path))
    if schema_errors:
        first = schema_errors[0]
        raise ValidationInputError(f"{_schema_error_path(first)}: {first.message}")

    entries = raw.get("evidence", [])
    ids: set[str] = set()
    by_id: dict[str, dict[str, Any]] = {}
    for entry in entries:
        eid = entry["id"]
        if eid in ids:
            errors.append(f"evidence manifest: duplicate evidence ID '{eid}'")
            continue
        ids.add(eid)
        by_id[eid] = entry

    for eid, entry in by_id.items():
        for parent in entry.get("parents", []):
            if parent not in ids:
                errors.append(f"evidence manifest: {eid} references unknown parent '{parent}'")
            if parent == eid:
                errors.append(f"evidence manifest: {eid} cannot reference itself as parent")

    visiting: set[str] = set()
    visited: set[str] = set()
    def visit(eid: str, stack: list[str]) -> None:
        if eid in visited or eid not in by_id:
            return
        if eid in visiting:
            cycle = " -> ".join(stack + [eid])
            errors.append(f"evidence manifest: lineage cycle detected: {cycle}")
            return
        visiting.add(eid)
        for parent in by_id[eid].get("parents", []):
            visit(parent, stack + [eid])
        visiting.discard(eid)
        visited.add(eid)
    for eid in sorted(ids):
        visit(eid, [])

    base = path.parent.resolve()
    for eid, entry in by_id.items():
        artifact = entry["artifact"]
        if URI_RE.match(artifact):
            message = f"evidence manifest: {eid} uses remote artifact URI; hash is recorded but not locally recomputed"
            (errors if require_artifacts else warnings).append(message)
            continue
        artifact_path = (base / artifact).resolve()
        try:
            artifact_path.relative_to(base)
        except ValueError:
            errors.append(f"evidence manifest: {eid} artifact escapes manifest directory: {artifact}")
            continue
        if not artifact_path.is_file():
            message = f"evidence manifest: {eid} artifact not found: {artifact}"
            (errors if require_artifacts else warnings).append(message)
            continue
        actual = sha256_file(artifact_path)
        if actual.casefold() != entry["sha256"].casefold():
            errors.append(f"evidence manifest: {eid} SHA-256 mismatch for {artifact}")
    return ids, errors, warnings


def parse_evidence_refs(
    value: str | None,
    *,
    evidence_ids: set[str] | None,
    context: str,
    errors: list[str],
    allow_none: bool,
) -> set[str]:
    if value is None or is_null_like(value):
        if not allow_none:
            errors.append(f"{context}: evidence reference list must not be empty")
        return set()
    cleaned = normalize_unicode(value).strip().strip("`*[]()（）")
    tokens = [token.strip("`*[]()（）") for token in EVIDENCE_REF_SPLIT_RE.split(cleaned) if token.strip()]
    refs: set[str] = set()
    for token in tokens:
        if not EVIDENCE_TOKEN_RE.fullmatch(token):
            errors.append(f"{context}: invalid evidence reference token '{token}'")
            continue
        if token in refs:
            errors.append(f"{context}: duplicate evidence reference '{token}'")
            continue
        if evidence_ids is None:
            errors.append(f"{context}: evidence manifest is required to resolve '{token}'")
            continue
        if token not in evidence_ids:
            errors.append(f"{context}: unknown evidence ID '{token}'")
            continue
        refs.add(token)
    if not refs and not allow_none and tokens:
        # Individual token errors already explain why resolution failed.
        pass
    return refs

def normalized_scalar(value: str) -> str:
    text = normalize_unicode(value).strip().strip("`*_")
    text = re.sub(r"\s+", " ", text)
    return text.casefold().strip("。；;，,：:！!？?()（）[]【】{}")


def is_empty_or_placeholder(value: str | None) -> bool:
    if value is None:
        return True
    stripped = normalize_unicode(value).strip().strip("-—_/\\|`*[]()（）")
    return not stripped or bool(PLACEHOLDER_RE.search(stripped))


def is_null_like(value: str | None) -> bool:
    if value is None:
        return True
    return normalized_scalar(value) in NULL_LIKE_VALUES


def is_substantive(value: str | None) -> bool:
    return not is_empty_or_placeholder(value) and not is_null_like(value)


def is_missing_evidence_statement(value: str | None) -> bool:
    if not is_substantive(value):
        return True
    normalized = normalize_unicode(value or "")
    return any(pattern.search(normalized) for pattern in MISSING_EVIDENCE_PATTERNS)


def weak_oracle(value: str) -> bool:
    normalized = normalize_unicode(value).casefold().strip()
    normalized = re.sub(r"[\s\-—_+，,。；;：:'\"“”‘’()（）\[\]`*]", "", normalized)
    normalized = re.sub(r"^(?:只|仅)?(?:检查|验证|确认)?(?:程序|应用|进程|系统)?", "", normalized)
    normalized = re.sub(r"(?:即可|就行|算通过|通过)$", "", normalized)
    chinese = {"不崩溃", "不发生崩溃", "没有崩溃", "无崩溃", "不会崩溃"}
    english = {"nocrash", "doesnotcrash", "notcrash", "doesntcrash"}
    return normalized in chinese or normalized in english


def split_table_row(line: str) -> list[str]:
    row = line.strip()
    if not row.startswith("|"):
        return []
    cells: list[str] = []
    current: list[str] = []
    escaped = False
    for char in row[1:]:
        if escaped:
            current.append(char)
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == "|":
            cells.append("".join(current).strip())
            current = []
        else:
            current.append(char)
    if escaped:
        current.append("\\")
    if current:
        cells.append("".join(current).strip())
    return cells


def normalize_header(value: str) -> str:
    return re.sub(r"[\s`*_]", "", normalize_unicode(value)).casefold()


def is_table_separator(cells: list[str]) -> bool:
    return bool(cells) and all(re.fullmatch(r":?-{3,}:?", cell.replace(" ", "")) for cell in cells)


def parse_declared_claims(block: str, *, strict: bool) -> ClaimCatalog:
    catalog = ClaimCatalog()
    rows = [(line_no, split_table_row(line)) for line_no, line in enumerate(block.splitlines(), 1)]
    rows = [(line_no, cells) for line_no, cells in rows if cells]
    header_index: int | None = None
    id_index: int | None = None
    statement_index: int | None = None

    for index, (_, cells) in enumerate(rows):
        normalized = [normalize_header(cell) for cell in cells]
        try:
            candidate_id = next(
                i for i, cell in enumerate(normalized) if cell in {"id", "声明id", "claimid"}
            )
            candidate_statement = next(
                i for i, cell in enumerate(normalized) if cell in {"声明", "statement", "claim"}
            )
        except StopIteration:
            continue
        header_index = index
        id_index = candidate_id
        statement_index = candidate_statement
        break

    if header_index is None or id_index is None or statement_index is None:
        if strict:
            catalog.errors.append("声明与风险: claim table must contain required columns 'ID' and '声明'")
        return catalog
    if header_index + 1 >= len(rows) or not is_table_separator(rows[header_index + 1][1]):
        catalog.errors.append("声明与风险: claim table header must be followed by a Markdown separator row")
        return catalog

    for line_no, cells in rows[header_index + 2 :]:
        if is_table_separator(cells):
            continue
        if max(id_index, statement_index) >= len(cells):
            catalog.errors.append(f"声明与风险: malformed claim row at line {line_no}")
            continue
        claim_id = normalize_unicode(cells[id_index].strip("`* "))
        statement = normalize_unicode(cells[statement_index].strip("`* "))
        if not claim_id:
            catalog.errors.append(f"声明与风险: empty claim ID at line {line_no}")
            continue
        if not CLAIM_TOKEN_RE.fullmatch(claim_id):
            catalog.errors.append(
                f"声明与风险: invalid claim ID '{claim_id}' at line {line_no}; expected {CLAIM_TOKEN_RE.pattern}"
            )
            continue
        if not is_substantive(statement):
            catalog.errors.append(f"声明与风险: claim '{claim_id}' has empty or non-substantive statement")
        if claim_id in catalog.ids:
            catalog.errors.append(f"声明与风险: duplicate claim ID '{claim_id}'")
            continue
        catalog.ids.add(claim_id)
        catalog.statements[claim_id] = statement

    if strict and not catalog.ids:
        catalog.errors.append("声明与风险: no valid claim rows found")
    return catalog


def parse_claim_refs(
    value: str | None,
    *,
    declared: set[str],
    context: str,
    errors: list[str],
    allow_none: bool,
) -> set[str]:
    if value is None or is_null_like(value):
        if not allow_none:
            errors.append(f"{context}: claim reference list must not be empty")
        return set()
    cleaned = normalize_unicode(value).strip().strip("`*[]()（）")
    tokens = [token.strip("`*[]()（）") for token in CLAIM_REF_SPLIT_RE.split(cleaned) if token.strip()]
    if not tokens:
        if not allow_none:
            errors.append(f"{context}: claim reference list must not be empty")
        return set()

    refs: set[str] = set()
    for token in tokens:
        if not CLAIM_TOKEN_RE.fullmatch(token):
            errors.append(f"{context}: invalid claim reference token '{token}'")
            continue
        if token not in declared:
            errors.append(f"{context}: unknown claim ID '{token}'")
            continue
        if token in refs:
            errors.append(f"{context}: duplicate claim reference '{token}'")
            continue
        refs.add(token)
    return refs


def parse_nonnegative_int(value: str | None, context: str, errors: list[str]) -> int | None:
    if value is None or is_empty_or_placeholder(value) or is_null_like(value):
        errors.append(f"{context}: must be a non-negative integer")
        return None
    normalized = normalize_unicode(value).strip()
    if not re.fullmatch(r"\d+", normalized):
        errors.append(f"{context}: must be a non-negative integer")
        return None
    return int(normalized)


def add_missing_or_placeholder(
    scenario: Scenario,
    field_name: str,
    errors: list[str],
    warnings: list[str],
    strict: bool,
    allow_placeholders: bool,
) -> None:
    value = scenario.fields.get(field_name)
    if value is None:
        errors.append(f"{scenario.scenario_id}: missing field '{field_name}'")
        return
    if is_empty_or_placeholder(value) and not allow_placeholders:
        target = errors if strict else warnings
        target.append(f"{scenario.scenario_id}: field '{field_name}' is empty or unfinished")


def require_substantive(
    scenario: Scenario,
    field_names: tuple[str, ...],
    reason: str,
    errors: list[str],
) -> None:
    if not all(is_substantive(scenario.fields.get(name)) for name in field_names):
        errors.append(f"{scenario.scenario_id}: {reason}; require {', '.join(field_names)}")


def require_evidence_field(scenario: Scenario, name: str, reason: str, errors: list[str]) -> None:
    value = scenario.fields.get(name)
    if not is_substantive(value) or is_missing_evidence_statement(value):
        errors.append(f"{scenario.scenario_id}: {reason}; '{name}' does not contain affirmative evidence")


def validate_execution_metadata(scenario: Scenario, errors: list[str]) -> tuple[str, int | None, int | None, str]:
    oracle_status = normalize_unicode(scenario.fields.get("Oracle执行状态", "")).strip().upper()
    landing_status = normalize_unicode(scenario.fields.get("扰动命中状态", "")).strip().upper()
    if oracle_status not in LEGAL_ORACLE_STATUSES:
        errors.append(
            f"{scenario.scenario_id}: illegal Oracle execution status '{scenario.fields.get('Oracle执行状态', '')}'"
        )
    if landing_status not in LEGAL_LANDING_STATUSES:
        errors.append(
            f"{scenario.scenario_id}: illegal perturbation landing status '{scenario.fields.get('扰动命中状态', '')}'"
        )
    assertion_total = parse_nonnegative_int(
        scenario.fields.get("Oracle断言总数"), f"{scenario.scenario_id}: Oracle断言总数", errors
    )
    assertion_failures = parse_nonnegative_int(
        scenario.fields.get("Oracle失败数"), f"{scenario.scenario_id}: Oracle失败数", errors
    )
    if assertion_total is not None and assertion_failures is not None and assertion_failures > assertion_total:
        errors.append(f"{scenario.scenario_id}: Oracle失败数 cannot exceed Oracle断言总数")
    return oracle_status, assertion_total, assertion_failures, landing_status


def validate_scenario(
    scenario: Scenario,
    *,
    declared_claims: set[str],
    evidence_ids: set[str] | None,
    strict: bool,
    allow_placeholders: bool,
    errors: list[str],
    warnings: list[str],
) -> None:
    if is_empty_or_placeholder(scenario.title) or is_null_like(scenario.title):
        errors.append(f"{scenario.scenario_id}: scenario title is empty or non-substantive")
    if scenario.duplicates:
        errors.append(
            f"{scenario.scenario_id}: duplicate field(s): {', '.join(sorted(scenario.duplicates))}"
        )

    for field_name in CORE_FIELDS:
        add_missing_or_placeholder(
            scenario, field_name, errors, warnings, strict, allow_placeholders
        )

    verdict_raw = normalize_unicode(scenario.fields.get("结果", "")).strip().upper()
    verdict = verdict_raw.split()[0].strip("`，,。.;；") if verdict_raw else ""
    scenario.verdict = verdict
    if is_empty_or_placeholder(verdict_raw):
        return
    if verdict not in LEGAL_VERDICTS:
        errors.append(f"{scenario.scenario_id}: illegal result status '{verdict_raw}'")
        return
    if strict and verdict == "NOT-RUN":
        errors.append(f"{scenario.scenario_id}: NOT-RUN is not allowed in strict gate mode")

    if strict:
        for field_name in ALWAYS_SUBSTANTIVE_FIELDS:
            value = scenario.fields.get(field_name)
            if not is_empty_or_placeholder(value) and not is_substantive(value):
                errors.append(
                    f"{scenario.scenario_id}: field '{field_name}' must contain substantive content for {verdict}"
                )

    scenario.claim_ids = parse_claim_refs(
        scenario.fields.get("关联声明"),
        declared=declared_claims,
        context=f"{scenario.scenario_id}: 关联声明",
        errors=errors,
        allow_none=not strict,
    )

    oracle = scenario.fields.get("Oracle", "")
    if oracle and is_substantive(oracle) and weak_oracle(oracle):
        target = errors if strict else warnings
        target.append(f"{scenario.scenario_id}: Oracle only checks process survival/no crash")

    if not strict:
        return

    oracle_status, assertion_total, assertion_failures, landing_status = validate_execution_metadata(
        scenario, errors
    )

    if verdict == "PASS-EVIDENCED":
        for name in ("主要误用或故障", "操作与时间线", "Oracle", "复现信息"):
            require_evidence_field(scenario, name, "PASS-EVIDENCED requires meaningful execution content", errors)
        for name in ("Oracle输出", "命中观测来源", "扰动落地证据"):
            require_evidence_field(scenario, name, "PASS-EVIDENCED requires captured affirmative evidence", errors)
        oracle_refs = parse_evidence_refs(scenario.fields.get("Oracle证据"), evidence_ids=evidence_ids, context=f"{scenario.scenario_id}: Oracle证据", errors=errors, allow_none=False)
        landing_refs = parse_evidence_refs(scenario.fields.get("扰动命中证据"), evidence_ids=evidence_ids, context=f"{scenario.scenario_id}: 扰动命中证据", errors=errors, allow_none=False)
        scenario.evidence_ids |= oracle_refs | landing_refs
        if oracle_status != "EXECUTED":
            errors.append(f"{scenario.scenario_id}: PASS-EVIDENCED requires Oracle执行状态=EXECUTED")
        if assertion_total is not None and assertion_total < 1:
            errors.append(f"{scenario.scenario_id}: PASS-EVIDENCED requires Oracle断言总数 >= 1")
        if assertion_failures is not None and assertion_failures != 0:
            errors.append(f"{scenario.scenario_id}: PASS-EVIDENCED requires Oracle失败数 = 0")
        if landing_status != "PROVEN":
            errors.append(f"{scenario.scenario_id}: PASS-EVIDENCED requires 扰动命中状态=PROVEN")

    elif verdict in {"FAIL-REPRODUCIBLE", "FAIL-NONDETERMINISTIC"}:
        if verdict == "FAIL-REPRODUCIBLE":
            require_substantive(
                scenario,
                ("复现路径",),
                "FAIL-REPRODUCIBLE requires a reproduction path or minimal repro",
                errors,
            )
        else:
            require_substantive(
                scenario,
                ("复现信息",),
                "FAIL-NONDETERMINISTIC requires seed/history/timeline capture",
                errors,
            )
        for name in ("Oracle输出", "命中观测来源", "扰动落地证据"):
            require_evidence_field(scenario, name, f"{verdict} requires captured failure evidence", errors)
        oracle_refs = parse_evidence_refs(scenario.fields.get("Oracle证据"), evidence_ids=evidence_ids, context=f"{scenario.scenario_id}: Oracle证据", errors=errors, allow_none=False)
        landing_refs = parse_evidence_refs(scenario.fields.get("扰动命中证据"), evidence_ids=evidence_ids, context=f"{scenario.scenario_id}: 扰动命中证据", errors=errors, allow_none=False)
        scenario.evidence_ids |= oracle_refs | landing_refs
        if oracle_status != "EXECUTED":
            errors.append(f"{scenario.scenario_id}: {verdict} requires Oracle执行状态=EXECUTED")
        if assertion_total is not None and assertion_total < 1:
            errors.append(f"{scenario.scenario_id}: {verdict} requires Oracle断言总数 >= 1")
        if assertion_failures is not None and assertion_failures < 1:
            errors.append(f"{scenario.scenario_id}: {verdict} requires Oracle失败数 >= 1")
        if landing_status != "PROVEN":
            errors.append(f"{scenario.scenario_id}: {verdict} requires 扰动命中状态=PROVEN")

    elif verdict == "INCONCLUSIVE-FAULT-NOT-PROVEN":
        require_substantive(
            scenario,
            ("扰动落地尝试", "未证明原因"),
            "INCONCLUSIVE-FAULT-NOT-PROVEN requires both attempted landing proof and why it failed",
            errors,
        )
        if landing_status != "NOT-PROVEN":
            errors.append(
                f"{scenario.scenario_id}: INCONCLUSIVE-FAULT-NOT-PROVEN requires 扰动命中状态=NOT-PROVEN"
            )

    elif verdict == "PARTIAL-ORACLE":
        require_substantive(
            scenario,
            ("剩余未验证",),
            "PARTIAL-ORACLE requires the unverified part of the claim",
            errors,
        )
        for name in ("Oracle输出", "命中观测来源", "扰动落地证据"):
            require_evidence_field(scenario, name, "PARTIAL-ORACLE requires evidence for the verified portion", errors)
        oracle_refs = parse_evidence_refs(scenario.fields.get("Oracle证据"), evidence_ids=evidence_ids, context=f"{scenario.scenario_id}: Oracle证据", errors=errors, allow_none=False)
        landing_refs = parse_evidence_refs(scenario.fields.get("扰动命中证据"), evidence_ids=evidence_ids, context=f"{scenario.scenario_id}: 扰动命中证据", errors=errors, allow_none=False)
        scenario.evidence_ids |= oracle_refs | landing_refs
        if oracle_status != "PARTIAL":
            errors.append(f"{scenario.scenario_id}: PARTIAL-ORACLE requires Oracle执行状态=PARTIAL")
        if assertion_total is not None and assertion_total < 1:
            errors.append(f"{scenario.scenario_id}: PARTIAL-ORACLE requires Oracle断言总数 >= 1")
        if landing_status != "PROVEN":
            errors.append(f"{scenario.scenario_id}: PARTIAL-ORACLE requires 扰动命中状态=PROVEN")

    elif verdict in {"BLOCKED-HARNESS", "BLOCKED-ENVIRONMENT"}:
        require_substantive(
            scenario,
            ("阻塞原因", "解除条件"),
            f"{verdict} requires a concrete blocking reason and unblock condition",
            errors,
        )
        if oracle_status != "NOT-EXECUTED":
            errors.append(f"{scenario.scenario_id}: {verdict} requires Oracle执行状态=NOT-EXECUTED")
        if landing_status != "NOT-EXECUTED":
            errors.append(f"{scenario.scenario_id}: {verdict} requires 扰动命中状态=NOT-EXECUTED")
        if assertion_total not in {None, 0} or assertion_failures not in {None, 0}:
            errors.append(f"{scenario.scenario_id}: {verdict} requires zero Oracle assertion counts")

    elif verdict == "NOT-RUN-SAFETY":
        require_substantive(
            scenario,
            ("安全阻塞原因", "替代执行方式"),
            "NOT-RUN-SAFETY requires the safety reason and a safer alternative",
            errors,
        )
        if oracle_status != "NOT-EXECUTED":
            errors.append(f"{scenario.scenario_id}: NOT-RUN-SAFETY requires Oracle执行状态=NOT-EXECUTED")
        if landing_status != "NOT-EXECUTED":
            errors.append(f"{scenario.scenario_id}: NOT-RUN-SAFETY requires 扰动命中状态=NOT-EXECUTED")
        if assertion_total not in {None, 0} or assertion_failures not in {None, 0}:
            errors.append(f"{scenario.scenario_id}: NOT-RUN-SAFETY requires zero Oracle assertion counts")


def validate_global_fields(
    section_name: str,
    fields: dict[str, str],
    duplicates: set[str],
    required: tuple[str, ...],
    *,
    strict: bool,
    errors: list[str],
    warnings: list[str],
    null_allowed: set[str] | None = None,
) -> None:
    null_allowed = null_allowed or set()
    if duplicates:
        errors.append(f"{section_name}: duplicate field(s): {', '.join(sorted(duplicates))}")
    for name in required:
        value = fields.get(name)
        if value is None:
            errors.append(f"{section_name}: missing field '{name}'")
        elif is_empty_or_placeholder(value):
            target = errors if strict else warnings
            target.append(f"{section_name}: field '{name}' is empty or unfinished")
        elif is_null_like(value) and name not in null_allowed:
            target = errors if strict else warnings
            target.append(f"{section_name}: field '{name}' must contain substantive content")


def validate_release_consistency(
    release_fields: dict[str, str],
    declared_claims: set[str],
    scenarios: list[Scenario],
    evidence_ids: set[str] | None,
    errors: list[str],
) -> None:
    release_raw = normalize_unicode(release_fields.get("发布结论", "")).strip().upper()
    release_verdict = release_raw.split()[0].strip("`，,。.;；") if release_raw else ""
    if release_verdict not in LEGAL_RELEASE_VERDICTS:
        errors.append(f"结果与发布结论: illegal release verdict '{release_raw}'")
        return

    verified_refs = parse_claim_refs(
        release_fields.get("已验证声明"),
        declared=declared_claims,
        context="结果与发布结论: 已验证声明",
        errors=errors,
        allow_none=True,
    )
    unverified_refs = parse_claim_refs(
        release_fields.get("未验证声明"),
        declared=declared_claims,
        context="结果与发布结论: 未验证声明",
        errors=errors,
        allow_none=True,
    )
    if verified_refs & unverified_refs:
        errors.append("结果与发布结论: a claim cannot be both verified and unverified")
    if verified_refs | unverified_refs != declared_claims:
        missing = sorted(declared_claims - (verified_refs | unverified_refs))
        extra = sorted((verified_refs | unverified_refs) - declared_claims)
        detail = []
        if missing:
            detail.append("missing " + ", ".join(missing))
        if extra:
            detail.append("unknown " + ", ".join(extra))
        errors.append(
            "结果与发布结论: verified and unverified claim sets must cover every declared claim"
            + (": " + "; ".join(detail) if detail else "")
        )

    scenarios_by_claim: dict[str, list[Scenario]] = {claim_id: [] for claim_id in declared_claims}
    for scenario in scenarios:
        for claim_id in scenario.claim_ids:
            scenarios_by_claim.setdefault(claim_id, []).append(scenario)
    expected_verified = {
        claim_id
        for claim_id, related in scenarios_by_claim.items()
        if related and all(item.verdict == "PASS-EVIDENCED" for item in related)
    }
    expected_unverified = declared_claims - expected_verified
    if verified_refs != expected_verified:
        errors.append(
            "结果与发布结论: '已验证声明' must exactly match claims whose associated scenarios are all PASS-EVIDENCED"
        )
    if unverified_refs != expected_unverified:
        errors.append(
            "结果与发布结论: '未验证声明' must exactly match claims not fully verified by all associated scenarios"
        )

    recovery_status = normalize_unicode(release_fields.get("环境恢复状态", "")).strip().upper()
    if recovery_status not in LEGAL_RECOVERY_STATUSES:
        errors.append(
            f"结果与发布结论: illegal environment recovery status '{release_fields.get('环境恢复状态', '')}'"
        )
    recovery_evidence = release_fields.get("环境恢复证据")
    if recovery_status == "NOT-REQUIRED":
        pass
    elif not is_substantive(recovery_evidence) or is_missing_evidence_statement(recovery_evidence):
        errors.append("结果与发布结论: '环境恢复证据' must contain an affirmative check via EV-* evidence reference")
    else:
        parse_evidence_refs(
            recovery_evidence,
            evidence_ids=evidence_ids,
            context="结果与发布结论: 环境恢复证据",
            errors=errors,
            allow_none=False,
        )

    scenario_verdicts = {scenario.verdict for scenario in scenarios}
    failures = {verdict for verdict in scenario_verdicts if verdict.startswith("FAIL-")}
    blocked = {
        verdict
        for verdict in scenario_verdicts
        if verdict.startswith("BLOCKED-")
        or verdict in {"NOT-RUN-SAFETY", "INCONCLUSIVE-FAULT-NOT-PROVEN"}
    }
    partial = {verdict for verdict in scenario_verdicts if verdict == "PARTIAL-ORACLE"}

    if release_verdict == "PASS":
        if failures or blocked or partial:
            errors.append(
                "结果与发布结论: PASS conflicts with non-passing scenario verdicts: "
                + ", ".join(sorted(failures | blocked | partial))
            )
        if expected_verified != declared_claims:
            errors.append("结果与发布结论: PASS requires every declared claim to be fully verified")
        if verified_refs != declared_claims:
            errors.append("结果与发布结论: PASS requires '已验证声明' to list every defined claim")
        if unverified_refs:
            errors.append("结果与发布结论: PASS requires '未验证声明' to be none")
        if not is_null_like(release_fields.get("阻塞项")):
            errors.append("结果与发布结论: PASS requires '阻塞项' to be none")
        if recovery_status != "RESTORED":
            errors.append("结果与发布结论: PASS requires 环境恢复状态=RESTORED")
    elif release_verdict == "CONDITIONAL-PASS":
        if failures or blocked:
            errors.append(
                "结果与发布结论: CONDITIONAL-PASS conflicts with FAIL/BLOCKED/NOT-RUN-SAFETY/INCONCLUSIVE scenarios"
            )
        if not is_substantive(release_fields.get("剩余风险")):
            errors.append("结果与发布结论: CONDITIONAL-PASS requires concrete remaining risk")
        if recovery_status not in {"RESTORED", "NOT-REQUIRED"}:
            errors.append(
                "结果与发布结论: CONDITIONAL-PASS requires 环境恢复状态=RESTORED or NOT-REQUIRED"
            )
    elif release_verdict == "BLOCKED":
        if not blocked and is_null_like(release_fields.get("阻塞项")):
            errors.append("结果与发布结论: BLOCKED requires a blocked scenario or blocking item")
    elif release_verdict == "FAIL":
        if not failures:
            errors.append("结果与发布结论: FAIL requires at least one FAIL-* scenario")


def validate_text(
    text: str, *, strict: bool, allow_placeholders: bool, evidence_ids: set[str] | None = None
) -> tuple[list[str], list[str], int]:
    errors: list[str] = []
    warnings: list[str] = []
    body = strip_non_body_markdown(text)

    sections = parse_h2_sections(body)
    selected_sections: dict[str, tuple[str, str]] = {}
    for concept, pattern in REQUIRED_SECTION_CONCEPTS.items():
        matches = matching_sections(sections, pattern)
        if not matches:
            errors.append(f"missing level-2 section for concept: {concept}")
        elif len(matches) > 1:
            errors.append(
                f"duplicate level-2 sections for concept '{concept}': "
                + ", ".join(heading for heading, _ in matches)
            )
        else:
            selected_sections[concept] = matches[0]

    declaration_section = selected_sections.get("声明")
    catalog = parse_declared_claims(declaration_section[1], strict=strict) if declaration_section else ClaimCatalog()
    errors.extend(catalog.errors)

    scenarios = parse_scenarios(body)
    if not scenarios:
        errors.append("no scenario headings such as '### S01：...' found")

    seen_ids: set[str] = set()
    for scenario in scenarios:
        if scenario.scenario_id in seen_ids:
            errors.append(f"duplicate scenario id: {scenario.scenario_id}")
        seen_ids.add(scenario.scenario_id)
        validate_scenario(
            scenario,
            declared_claims=catalog.ids,
            evidence_ids=evidence_ids,
            strict=strict,
            allow_placeholders=allow_placeholders,
            errors=errors,
            warnings=warnings,
        )

    if strict:
        safety_section = selected_sections.get("安全")
        if safety_section:
            safety_fields, safety_duplicates = parse_fields(safety_section[1])
            validate_global_fields(
                "安全与证据数据",
                safety_fields,
                safety_duplicates,
                SAFETY_REQUIRED_FIELDS,
                strict=True,
                errors=errors,
                warnings=warnings,
            )

        release_section = selected_sections.get("结果/结论")
        if release_section:
            release_fields, release_duplicates = parse_fields(release_section[1])
            validate_global_fields(
                "结果与发布结论",
                release_fields,
                release_duplicates,
                RELEASE_REQUIRED_FIELDS,
                strict=True,
                errors=errors,
                warnings=warnings,
                null_allowed={"已验证声明", "未验证声明", "剩余风险", "阻塞项", "环境恢复证据"},
            )
            if all(name in release_fields for name in RELEASE_REQUIRED_FIELDS):
                validate_release_consistency(release_fields, catalog.ids, scenarios, evidence_ids, errors)

    if strict and warnings:
        errors.extend(f"strict warning: {warning}" for warning in warnings)
    return errors, warnings, len(scenarios)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("campaign", type=Path)
    parser.add_argument(
        "--strict",
        action="store_true",
        help="structure-and-consistency release gate; does not verify evidence truthfulness",
    )
    parser.add_argument(
        "--allow-placeholders",
        action="store_true",
        help="allow TODO/TBD values in draft validation; incompatible with --strict",
    )
    parser.add_argument(
        "--evidence-manifest",
        type=Path,
        help="JSON evidence manifest used to resolve EV-* references and validate lineage/hash metadata",
    )
    parser.add_argument(
        "--require-artifacts",
        action="store_true",
        help="require every evidence artifact to be local, readable and SHA-256 verified; requires --evidence-manifest",
    )
    args = parser.parse_args()

    if args.strict and args.allow_placeholders:
        fail_input("--strict cannot be combined with --allow-placeholders")
    if args.require_artifacts and not args.evidence_manifest:
        fail_input("--require-artifacts requires --evidence-manifest")
    try:
        text = args.campaign.read_text(encoding="utf-8")
    except FileNotFoundError:
        fail_input(f"campaign not found: {args.campaign}")
    except PermissionError:
        fail_input(f"permission denied while reading campaign: {args.campaign}")
    except UnicodeDecodeError as exc:
        fail_input(f"campaign is not valid UTF-8: {exc}")
    except OSError as exc:
        fail_input(f"cannot read campaign {args.campaign}: {exc}")

    evidence_ids: set[str] | None = None
    manifest_errors: list[str] = []
    manifest_warnings: list[str] = []
    if args.evidence_manifest:
        try:
            evidence_ids, manifest_errors, manifest_warnings = load_evidence_manifest(
                args.evidence_manifest, require_artifacts=args.require_artifacts
            )
        except ValidationInputError as exc:
            fail_input(str(exc))

    try:
        errors, warnings, scenario_count = validate_text(
            text,
            strict=args.strict,
            allow_placeholders=args.allow_placeholders and not args.strict,
            evidence_ids=evidence_ids,
        )
    except ValidationInputError as exc:
        fail_input(str(exc))
    errors = manifest_errors + errors
    warnings = manifest_warnings + warnings

    for warning in warnings:
        print(f"WARN: {warning}")
    for error in errors:
        print(f"ERROR: {error}")

    if errors:
        print(f"FAIL: {len(errors)} error(s), {len(warnings)} warning(s)")
        return 1
    print(f"PASS: {scenario_count} scenario(s), {len(warnings)} warning(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
