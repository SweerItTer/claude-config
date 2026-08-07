from __future__ import annotations

import json
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts" / "eval_runner.py"


class EvalRunnerTests(unittest.TestCase):
    def test_deterministic_suite_passes(self) -> None:
        result = subprocess.run(
            [sys.executable, str(RUNNER), "--suite", str(ROOT / "evals" / "tool-evals.json")],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["failed"], 0)
        self.assertGreaterEqual(report["passed"], 7)
        self.assertFalse(report["regression"])

    def test_baseline_detects_regression(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            suite = {
                "name": "broken",
                "cases": [
                    {
                        "id": "T01",
                        "tool": "generator",
                        "args": [{"path": "evals/fixtures/invalid-profile.json"}],
                        "expect": {"exit_code": 0},
                    }
                ],
            }
            suite_path = tmp / "suite.json"
            baseline_path = tmp / "baseline.json"
            suite_path.write_text(json.dumps(suite), encoding="utf-8")
            baseline_path.write_text(json.dumps({"passed_ids": ["T01"]}), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(RUNNER), "--suite", str(suite_path), "--baseline", str(baseline_path)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 1)
            report = json.loads(result.stdout)
            self.assertTrue(report["regression"])
            self.assertEqual(report["regressed_ids"], ["T01"])

    def test_agent_suite_fails_when_all_cases_are_skipped_by_default(self) -> None:
        result = subprocess.run(
            [sys.executable, str(RUNNER), "--suite", str(ROOT / "evals" / "evals.json")],
            text=True, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertGreater(report["skipped"], 0)
        self.assertEqual(report["passed"], 0)

    def test_allow_skipped_requires_explicit_flag(self) -> None:
        result = subprocess.run(
            [
                sys.executable, str(RUNNER), "--suite", str(ROOT / "evals" / "evals.json"),
                "--allow-skipped",
            ],
            text=True, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertGreater(report["skipped"], 0)

    def test_agent_timeout_is_blocked_harness_and_fails_suite(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            suite = {"name": "timeout", "evals": [{"id": "A01", "prompt": "hello"}]}
            suite_path = tmp / "suite.json"
            suite_path.write_text(json.dumps(suite), encoding="utf-8")
            agent_cmd = shlex.join([sys.executable, "-c", "import time; time.sleep(2)"])
            judge_cmd = shlex.join([sys.executable, "-c", 'print("{\"pass\": true}")'])
            result = subprocess.run(
                [
                    sys.executable, str(RUNNER), "--suite", str(suite_path),
                    "--agent-command", agent_cmd, "--judge-command", judge_cmd,
                    "--case-timeout", "0.1", "--global-timeout", "1",
                ],
                text=True, capture_output=True, check=False, timeout=5,
            )
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report["blocked_harness"], 1)
            self.assertEqual(report["results"][0]["status"], "blocked-harness")



if __name__ == "__main__":
    unittest.main()
