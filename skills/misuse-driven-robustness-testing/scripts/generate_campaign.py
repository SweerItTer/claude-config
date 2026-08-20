#!/usr/bin/env python3
"""Generate a framework-neutral misuse-driven testing campaign skeleton.

The script validates a small JSON profile, then renders a Markdown workbook.
Validation rules are sourced from schemas/profile.schema.json. It does not execute tests, shell commands, downloads, or fault injection.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
from pathlib import Path
from typing import Any, NoReturn

try:
    from jsonschema import Draft202012Validator
except ImportError as exc:  # pragma: no cover - dependency failure
    Draft202012Validator = None  # type: ignore[assignment]

LENS_LABELS = {
    "misunderstanding": "误解与误配置",
    "input": "输入畸变",
    "sequence": "跳步与乱序",
    "repeat": "重复与回放",
    "interrupt": "中断与恢复",
    "timing": "并发与时序",
    "resource": "资源与容量",
    "environment": "依赖与环境",
    "ownership": "身份、所有权与陈旧引用",
    "observability": "可观测性与假成功",
}

PROMPTS = {
    "misunderstanding": "用户如何误解字段、单位、按钮或默认值？失败后是否保留上一次有效状态？",
    "input": "哪些空值、边界、超长、截断、编码异常或语义矛盾输入可能突破声明？",
    "sequence": "哪些跳步、倒序、旧请求晚到或禁止状态调用可能突破声明？",
    "repeat": "重复点击、自动重试、重复通知或回放会不会产生重复副作用？",
    "interrupt": "在有副作用的每个阶段终止、断网或重启后，系统处于什么状态？",
    "timing": "并发、重入、超时边界、延迟或乱序到达是否会改变结果？",
    "resource": "队列、内存、句柄、线程、磁盘或日志接近上限时声明是否仍成立？",
    "environment": "依赖慢、错、半可用，或时钟、权限、配置漂移时会怎样？",
    "ownership": "对象重建、撤权、切租户或旧句柄继续使用时是否越界？",
    "observability": "如何独立证明动作生效、故障落地且 Oracle 检查了真实目标？",
}

SCHEMA_PATH = Path(__file__).resolve().parents[1] / "schemas" / "profile.schema.json"


class ProfileError(ValueError):
    """A user-facing profile validation error."""


def fail(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(2)


def _json_path(error: Any) -> str:
    path = "profile"
    for part in error.absolute_path:
        path += f"[{part}]" if isinstance(part, int) else f".{part}"
    return path


def _load_schema() -> dict[str, Any]:
    if Draft202012Validator is None:
        raise ProfileError("missing dependency: jsonschema>=4.20")
    try:
        return json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ProfileError(f"cannot load profile schema: {exc}") from exc


def validate_profile(raw: Any) -> dict[str, Any]:
    """Validate structural rules from the JSON Schema, then apply semantic defaults.

    Type, range, enum, unknown-field and duplicate-lens rules intentionally live
    in profile.schema.json. Python only handles cross-item semantics (claim ID
    uniqueness) and normalization/defaults that JSON Schema does not mutate.
    """
    schema = _load_schema()
    validator = Draft202012Validator(schema)
    schema_errors = sorted(validator.iter_errors(raw), key=lambda e: list(e.absolute_path))
    if schema_errors:
        first = schema_errors[0]
        path = _json_path(first)
        if first.validator == "additionalProperties":
            names = re.findall(r"'([^']+)'", first.message)
            raise ProfileError(f"{path} contains unknown field(s): {', '.join(names)}")
        if first.validator == "uniqueItems" and path.endswith(".lenses"):
            values = list(first.instance) if isinstance(first.instance, list) else []
            duplicate = next((item for item in values if values.count(item) > 1), "unknown")
            raise ProfileError(f"{path} contains duplicate lens: {duplicate}")
        if first.validator == "pattern":
            raise ProfileError(f"{path} must match {first.validator_value}")
        if first.validator == "type":
            if path == "profile.states":
                raise ProfileError("states must be an array of strings")
            if path == "profile.operations":
                raise ProfileError("operations must be an array of strings")
            if path == "profile.dependencies":
                raise ProfileError("dependencies must be an array of strings")
            if path == "profile.safety":
                raise ProfileError("safety must be an object")
            expected = first.validator_value
            if expected == "integer":
                raise ProfileError(f"{path} must be an integer")
        raise ProfileError(f"{path}: {first.message}")
    assert isinstance(raw, dict)

    seen_ids: set[str] = set()
    claims: list[dict[str, Any]] = []
    for index, claim_raw in enumerate(raw["claims"]):
        claim_id = claim_raw["id"].strip()
        if claim_id in seen_ids:
            raise ProfileError(f"duplicate claim id: {claim_id}")
        seen_ids.add(claim_id)
        claims.append({
            "id": claim_id,
            "statement": claim_raw["statement"].strip(),
            "impact": claim_raw["impact"],
            "probability": claim_raw["probability"],
            "lenses": list(claim_raw.get("lenses", LENS_LABELS.keys())),
        })

    safety_raw = raw.get("safety") or {}
    return {
        "system": raw["system"].strip(),
        "scope": raw.get("scope", "未填写").strip() if isinstance(raw.get("scope", "未填写"), str) else "未填写",
        "states": [item.strip() for item in raw.get("states", [])],
        "operations": [item.strip() for item in raw.get("operations", [])],
        "dependencies": [item.strip() for item in raw.get("dependencies", [])],
        "claims": claims,
        "safety": {
            "environment": safety_raw.get("environment", "TODO").strip() if isinstance(safety_raw.get("environment", "TODO"), str) else "TODO",
            "max_duration_minutes": safety_raw.get("max_duration_minutes", "TODO"),
            "forbidden": [item.strip() for item in safety_raw.get("forbidden", [])],
        },
    }


def load_profile(path: Path) -> dict[str, Any]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"profile not found: {path}")
    except PermissionError:
        fail(f"permission denied while reading profile: {path}")
    except UnicodeDecodeError as exc:
        fail(f"profile is not valid UTF-8: {exc}")
    except OSError as exc:
        fail(f"cannot read profile {path}: {exc}")
    except json.JSONDecodeError as exc:
        fail(f"invalid JSON at line {exc.lineno}, column {exc.colno}: {exc.msg}")

    try:
        return validate_profile(raw)
    except ProfileError as exc:
        fail(str(exc))


def md_inline(value: Any) -> str:
    """Render untrusted text as plain Markdown text, not active links/images/HTML."""
    text = str(value).replace("\r\n", "\n").replace("\r", "\n")
    text = html.escape(text, quote=False)
    # Backslash-escape Markdown control characters and table delimiters.
    text = re.sub(r"([\\|`*_\[\]()!#~])", r"\\\1", text)
    # Break URI schemes and common GFM autolink forms so renderers do not issue remote requests.
    text = re.sub(
        r"(?i)\b(https?|ftp|mailto):",
        lambda match: f"{match.group(1)}&#58;",
        text,
    )
    text = re.sub(r"(?i)\bwww\.", "www&#46;", text)
    text = re.sub(
        r"(?i)([A-Z0-9._%+\-]+)@([A-Z0-9.\-]+\.[A-Z]{2,})",
        lambda match: f"{match.group(1)}&#64;{match.group(2)}",
        text,
    )
    return text.replace("\n", "<br>")


def md_list(values: list[str], empty: str = "待补充") -> str:
    return ", ".join(md_inline(item) for item in values) if values else empty


def coverage_summary(profile: dict[str, Any], max_scenarios: int) -> dict[str, Any]:
    ranked_claims = sorted(
        profile["claims"], key=lambda item: item["impact"] * item["probability"], reverse=True
    )
    planned = [(claim["id"], lens) for claim in ranked_claims for lens in claim["lenses"]]
    selected = planned[:max_scenarios]
    selected_set = set(selected)
    covered_claims = [claim["id"] for claim in ranked_claims if any(cid == claim["id"] for cid, _ in selected)]
    omitted_claims = [claim["id"] for claim in ranked_claims if claim["id"] not in covered_claims]
    omitted_lenses: dict[str, list[str]] = {}
    for claim in ranked_claims:
        missing = [lens for lens in claim["lenses"] if (claim["id"], lens) not in selected_set]
        if missing:
            omitted_lenses[claim["id"]] = missing
    return {
        "covered_claims": covered_claims,
        "omitted_claims": omitted_claims,
        "omitted_lenses": omitted_lenses,
        "selected_scenarios": len(selected),
        "planned_scenarios": len(planned),
        "truncated": len(selected) < len(planned),
    }


def render_coverage_summary(report: dict[str, Any]) -> str:
    covered = ",".join(report["covered_claims"]) or "none"
    omitted_claims = ",".join(report["omitted_claims"]) or "none"
    omitted_lenses = "; ".join(
        f"{claim}:{','.join(lenses)}" for claim, lenses in report["omitted_lenses"].items()
    ) or "none"
    return (
        f"coverage: scenarios {report['selected_scenarios']}/{report['planned_scenarios']}; "
        f"covered claims: {covered}; omitted claims: {omitted_claims}; omitted lenses: {omitted_lenses}"
    )


def build_markdown(profile: dict[str, Any], max_scenarios: int) -> str:
    lines = [
        f"# 误用驱动鲁棒性测试活动：{md_inline(profile['system'])}",
        "",
        "## 0. 元信息",
        "",
        f"- 系统 / 模块：{md_inline(profile['system'])}",
        f"- 范围：{md_inline(profile['scope'])}",
        "- 版本 / Commit：TODO",
        "- 环境：TODO",
        "- 负责人：TODO",
        "- 时间预算：TODO",
        "- 本次明确不覆盖：TODO",
        "",
        "## 1. 声明与风险",
        "",
        "| ID | 声明 | 影响 | 可能性 | 风险分 |",
        "|---|---|---:|---:|---:|",
    ]
    ranked_claims = sorted(
        profile["claims"], key=lambda item: item["impact"] * item["probability"], reverse=True
    )
    for claim in ranked_claims:
        lines.append(
            f"| {md_inline(claim['id'])} | {md_inline(claim['statement'])} | "
            f"{claim['impact']} | {claim['probability']} | {claim['impact'] * claim['probability']} |"
        )

    lines.extend(
        [
            "",
            "## 2. 轻量行为模型",
            "",
            f"- 状态：{md_list(profile['states'], 'TODO')}",
            f"- 操作：{md_list(profile['operations'], 'TODO')}",
            f"- 外部依赖：{md_list(profile['dependencies'], 'TODO')}",
            "- 持久化对象：TODO",
            "- 权限 / 所有权：TODO",
            "- 可注入故障点：TODO",
            "- 可观测信号：TODO",
            "",
            "## 3. 场景",
            "",
        ]
    )

    scenario_no = 0
    for claim in ranked_claims:
        for lens in claim["lenses"]:
            if scenario_no >= max_scenarios:
                break
            scenario_no += 1
            lines.extend(
                [
                    f"### S{scenario_no:02d}：{md_inline(claim['id'])} × {LENS_LABELS[lens]}",
                    "",
                    f"- 关联声明：{md_inline(claim['id'])}",
                    f"- 思考提示：{PROMPTS[lens]}",
                    "- 前置状态：TODO",
                    "- 正常种子路径：TODO",
                    "- 主要误用或故障：TODO（先保持一个主要扰动）",
                    "- 操作与时间线：TODO",
                    "- 期望不变量：TODO",
                    "- Oracle：TODO（不要只写‘不崩溃’）",
                    "- Oracle 执行状态：NOT-EXECUTED",
                    "- Oracle 断言总数：0",
                    "- Oracle 失败数：0",
                    "- Oracle 输出：TODO",
                "- Oracle 证据：TODO",
                    "- 扰动命中状态：NOT-EXECUTED",
                    "- 命中观测来源：TODO",
                    "- 扰动落地证据：TODO",
                "- 扰动命中证据：TODO",
                    "- 扰动落地尝试：TODO（INCONCLUSIVE-FAULT-NOT-PROVEN 时填写）",
                    "- 未证明原因：TODO（INCONCLUSIVE-FAULT-NOT-PROVEN 时填写）",
                    "- 恢复要求：TODO",
                    "- 安全边界与停止条件：TODO",
                    "- 复现信息：TODO（版本 / 输入 / Seed / 操作历史 / 时间线）",
                    "- 复现路径：TODO（FAIL-REPRODUCIBLE 时填写）",
                    "- 安全阻塞原因：TODO（NOT-RUN-SAFETY 时填写）",
                    "- 替代执行方式：TODO（NOT-RUN-SAFETY 时填写）",
                    "- 阻塞原因：TODO（BLOCKED-* 时填写）",
                    "- 解除条件：TODO（BLOCKED-* 时填写）",
                    "- 剩余未验证：TODO（PARTIAL-ORACLE 时填写）",
                    "- 结果：NOT-RUN",
                    "- 责任分类：TODO",
                    "- 回归沉淀：TODO",
                    "",
                ]
            )
        if scenario_no >= max_scenarios:
            break

    safety = profile["safety"]
    lines.extend(
        [
            "## 4. 安全与证据数据",
            "",
            f"- 环境隔离：{md_inline(safety['environment'])}",
            "- 允许修改的数据 / 文件 / 设备：TODO",
            f"- 禁止操作：{md_list(safety['forbidden'], 'TODO')}",
            f"- 最大运行时长：{md_inline(safety['max_duration_minutes'])} 分钟",
            "- 最大并发 / 请求 / 资源：TODO",
            "- 自动停止条件：TODO",
            "- 恢复步骤：TODO",
            "- 恢复验证：TODO",
            "- 证据数据级别：TODO",
            "- 最小采集范围：TODO",
            "- 脱敏方式：TODO",
            "- 访问与存放：TODO",
            "- 保存与销毁：TODO",
            "- 导出复核：TODO",
            "",
            "## 5. 结果与发布结论",
            "",
            "- 已验证声明：TODO",
            "- 未验证声明：TODO",
            "- 剩余风险：TODO",
            "- 阻塞项：活动尚未执行",
            "- 环境恢复状态：NOT-VERIFIED",
            "- 环境恢复证据：活动尚未执行，待完成恢复检查",
            "- 发布结论：BLOCKED",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=Path, help="JSON system profile")
    parser.add_argument("-o", "--output", type=Path, help="output Markdown path")
    parser.add_argument("--max-scenarios", type=int, default=20)
    args = parser.parse_args()

    if args.max_scenarios < 1:
        fail("--max-scenarios must be positive")
    profile = load_profile(args.profile)
    report = coverage_summary(profile, args.max_scenarios)
    markdown = build_markdown(profile, args.max_scenarios)
    print(render_coverage_summary(report), file=sys.stderr)
    if args.output:
        try:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(markdown, encoding="utf-8")
        except OSError as exc:
            fail(f"cannot write output {args.output}: {exc}")
        print(args.output)
    else:
        print(markdown)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
