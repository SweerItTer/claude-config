from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "scripts" / "generate_campaign.py"
VALIDATOR = ROOT / "scripts" / "validate_campaign.py"


class ExampleIntegrationTests(unittest.TestCase):
    def test_generated_campaign_matches_snapshot(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(GENERATOR),
                str(ROOT / "examples" / "embedded-wifi-profile.json"),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = (ROOT / "examples" / "embedded-wifi-generated-campaign.md").read_text(
            encoding="utf-8"
        )
        self.assertEqual(result.stdout.rstrip("\n"), expected.rstrip("\n"))

    def test_completed_example_passes_strict_gate(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                "--strict",
                str(ROOT / "examples" / "embedded-wifi-completed-campaign.md"),
                "--evidence-manifest",
                str(ROOT / "examples" / "evidence-manifest.json"),
                "--require-artifacts",
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: 2 scenario(s), 0 warning(s)", result.stdout)


if __name__ == "__main__":
    unittest.main()
