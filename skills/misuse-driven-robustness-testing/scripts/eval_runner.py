#!/usr/bin/env python3
"""Run deterministic tool evals and optional agent-behavior evals.

Tool eval files never supply arbitrary commands: they select the bundled
validator/generator and paths under the skill directory. Agent behavior suites
require explicit --agent-command and --judge-command adapters supplied by the
caller; commands are executed without a shell.
"""
from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
TOOLS = {
    "validator": ROOT / "scripts" / "validate_campaign.py",
    "generator": ROOT / "scripts" / "generate_campaign.py",
}


class HarnessTimeout(RuntimeError):
    pass


def effective_timeout(case_timeout: float, deadline: float | None) -> float:
    if deadline is None:
        return case_timeout
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise HarnessTimeout("global eval timeout reached")
    return min(case_timeout, remaining)


def safe_path(value: str) -> Path:
    path = (ROOT / value).resolve()
    try:
        path.relative_to(ROOT)
    except ValueError as exc:
        raise ValueError(f"path escapes skill root: {value}") from exc
    return path


def run_tool_case(case: dict[str, Any], timeout: float) -> tuple[bool, str]:
    tool = case.get("tool")
    if tool not in TOOLS:
        return False, f"unknown tool: {tool}"
    argv = [sys.executable, str(TOOLS[tool])]
    for arg in case.get("args", []):
        if isinstance(arg, dict) and "path" in arg:
            argv.append(str(safe_path(arg["path"])))
        elif isinstance(arg, str):
            argv.append(arg)
        else:
            return False, f"unsupported arg: {arg!r}"
    try:
        proc = subprocess.run(argv, text=True, capture_output=True, check=False, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise HarnessTimeout(f"tool case timed out after {timeout:g}s") from exc
    expected = case.get("expect", {})
    problems: list[str] = []
    if proc.returncode != expected.get("exit_code", 0):
        problems.append(f"exit {proc.returncode} != {expected.get('exit_code', 0)}")
    for needle in expected.get("stdout_contains", []):
        if needle not in proc.stdout:
            problems.append(f"stdout missing {needle!r}")
    for needle in expected.get("stderr_contains", []):
        if needle not in proc.stderr:
            problems.append(f"stderr missing {needle!r}")
    for needle in expected.get("stdout_not_contains", []):
        if needle in proc.stdout:
            problems.append(f"stdout unexpectedly contains {needle!r}")
    return not problems, "; ".join(problems) if problems else "ok"


def run_agent_case(case: dict[str, Any], agent_cmd: str, judge_cmd: str, deadline: float) -> tuple[bool, str]:
    try:
        agent_timeout = effective_timeout(max(deadline - time.monotonic(), 1e-9), deadline)
        agent = subprocess.run(
            shlex.split(agent_cmd), input=case["prompt"], text=True, capture_output=True,
            check=False, timeout=agent_timeout
        )
    except subprocess.TimeoutExpired as exc:
        raise HarnessTimeout("agent case exceeded its case timeout") from exc
    if agent.returncode != 0:
        return False, f"agent exit {agent.returncode}: {agent.stderr.strip()}"
    judge_payload = json.dumps({
        "prompt": case["prompt"],
        "output": agent.stdout,
        "expected_output": case.get("expected_output", ""),
        "expectations": case.get("expectations", []),
    }, ensure_ascii=False)
    try:
        judge_timeout = effective_timeout(max(deadline - time.monotonic(), 1e-9), deadline)
        judge = subprocess.run(
            shlex.split(judge_cmd), input=judge_payload, text=True, capture_output=True,
            check=False, timeout=judge_timeout
        )
    except subprocess.TimeoutExpired as exc:
        raise HarnessTimeout("judge case exceeded its case timeout") from exc
    if judge.returncode != 0:
        return False, f"judge exit {judge.returncode}: {judge.stderr.strip()}"
    try:
        result = json.loads(judge.stdout)
    except json.JSONDecodeError as exc:
        return False, f"judge returned invalid JSON: {exc}"
    return bool(result.get("pass")), str(result.get("details", ""))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", type=Path, default=ROOT / "evals" / "tool-evals.json")
    parser.add_argument("--baseline", type=Path, default=None)
    parser.add_argument("--agent-command")
    parser.add_argument("--judge-command")
    parser.add_argument("--allow-skipped", action="store_true", help="allow skipped cases without failing the suite")
    parser.add_argument("--case-timeout", type=float, default=120.0, help="maximum seconds for each tool case or complete agent+judge case")
    parser.add_argument("--global-timeout", type=float, default=1800.0, help="maximum seconds for the entire suite")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.case_timeout <= 0 or args.global_timeout <= 0:
        parser.error("timeouts must be positive")
    deadline = time.monotonic() + args.global_timeout
    suite = json.loads(args.suite.read_text(encoding="utf-8"))
    cases = suite.get("cases", suite.get("evals", []))
    results: list[dict[str, Any]] = []
    for case in cases:
        cid = str(case.get("id"))
        if "tool" in case:
            try:
                timeout = effective_timeout(args.case_timeout, deadline)
                passed, detail = run_tool_case(case, timeout)
                status = "passed" if passed else "failed"
            except HarnessTimeout as exc:
                status, detail = "blocked-harness", str(exc)
            except Exception as exc:
                status, detail = "failed", str(exc)
        elif "prompt" in case:
            if not args.agent_command or not args.judge_command:
                status, detail = "skipped", "agent/judge adapter not provided"
            else:
                try:
                    effective_timeout(args.case_timeout, deadline)
                    case_deadline = min(deadline, time.monotonic() + args.case_timeout)
                    passed, detail = run_agent_case(case, args.agent_command, args.judge_command, case_deadline)
                    status = "passed" if passed else "failed"
                except HarnessTimeout as exc:
                    status, detail = "blocked-harness", str(exc)
                except Exception as exc:
                    status, detail = "failed", str(exc)
        else:
            status, detail = "failed", "case has neither tool nor prompt"
        results.append({"id": cid, "status": status, "detail": detail})

    passed_ids = {r["id"] for r in results if r["status"] == "passed"}
    failed_ids = {r["id"] for r in results if r["status"] in {"failed", "blocked-harness"}}
    regression = False
    regressed_ids: list[str] = []
    if args.baseline and args.baseline.exists():
        baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
        previous = set(map(str, baseline.get("passed_ids", [])))
        regressed_ids = sorted(previous & failed_ids)
        regression = bool(regressed_ids)
    report = {
        "suite": suite.get("name", args.suite.name),
        "total": len(results),
        "passed": sum(r["status"] == "passed" for r in results),
        "failed": sum(r["status"] == "failed" for r in results),
        "blocked_harness": sum(r["status"] == "blocked-harness" for r in results),
        "skipped": sum(r["status"] == "skipped" for r in results),
        "regression": regression,
        "regressed_ids": regressed_ids,
        "results": results,
    }
    rendered = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)
    return 1 if report["failed"] or report["blocked_harness"] or regression or (report["skipped"] and not args.allow_skipped) else 0


if __name__ == "__main__":
    raise SystemExit(main())
