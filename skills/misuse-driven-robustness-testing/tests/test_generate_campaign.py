from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "generate_campaign.py"
SCHEMA = ROOT / "schemas" / "profile.schema.json"


def base_profile() -> dict:
    return {
        "system": "demo",
        "scope": "stateful module",
        "states": ["READY", "RUNNING"],
        "operations": ["start", "stop"],
        "dependencies": ["clock"],
        "claims": [
            {
                "id": "C1",
                "statement": "repeat does not duplicate effects",
                "impact": 4,
                "probability": 3,
                "lenses": ["repeat"],
            }
        ],
        "safety": {
            "environment": "isolated",
            "max_duration_minutes": 10,
            "forbidden": ["production"],
        },
    }


class GenerateCampaignTests(unittest.TestCase):
    def run_generator(self, profile: object, *extra_args: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as tmp:
            profile_path = Path(tmp) / "profile.json"
            profile_path.write_text(json.dumps(profile), encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SCRIPT), str(profile_path), *extra_args],
                text=True,
                capture_output=True,
                check=False,
            )

    def test_valid_profile_generates_model_scenario_and_release_fields(self) -> None:
        result = self.run_generator(base_profile())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("状态：READY, RUNNING", result.stdout)
        self.assertIn("### S01", result.stdout)
        self.assertIn("Oracle 执行状态：NOT-EXECUTED", result.stdout)
        self.assertIn("扰动命中状态：NOT-EXECUTED", result.stdout)
        self.assertIn("Oracle 输出：TODO", result.stdout)
        self.assertIn("- 已验证声明：TODO", result.stdout)
        self.assertIn("- 环境恢复状态：NOT-VERIFIED", result.stdout)
        self.assertIn("- 阻塞项：活动尚未执行", result.stdout)

    def test_string_impact_is_rejected_without_traceback(self) -> None:
        profile = base_profile()
        profile["claims"][0]["impact"] = "4"
        result = self.run_generator(profile)
        self.assertEqual(result.returncode, 2)
        self.assertIn("must be an integer", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_bool_impact_is_rejected(self) -> None:
        profile = base_profile()
        profile["claims"][0]["impact"] = True
        result = self.run_generator(profile)
        self.assertEqual(result.returncode, 2)

    def test_states_string_is_rejected(self) -> None:
        profile = base_profile()
        profile["states"] = "READY"
        result = self.run_generator(profile)
        self.assertEqual(result.returncode, 2)
        self.assertIn("states must be an array of strings", result.stderr)

    def test_safety_string_is_rejected(self) -> None:
        profile = base_profile()
        profile["safety"] = "isolated"
        result = self.run_generator(profile)
        self.assertEqual(result.returncode, 2)
        self.assertIn("safety must be an object", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_invalid_claim_id_is_rejected(self) -> None:
        profile = base_profile()
        profile["claims"][0]["id"] = "1-C"
        result = self.run_generator(profile)
        self.assertEqual(result.returncode, 2)
        self.assertIn("must match", result.stderr)

    def test_duplicate_claim_id_is_rejected(self) -> None:
        profile = base_profile()
        profile["claims"].append(dict(profile["claims"][0]))
        result = self.run_generator(profile)
        self.assertEqual(result.returncode, 2)
        self.assertIn("duplicate claim id", result.stderr)

    def test_duplicate_lens_is_rejected_consistently_with_schema(self) -> None:
        profile = base_profile()
        profile["claims"][0]["lenses"] = ["repeat", "repeat"]
        result = self.run_generator(profile)
        self.assertEqual(result.returncode, 2)
        self.assertIn("duplicate lens", result.stderr)

    def test_unknown_root_field_is_rejected(self) -> None:
        profile = base_profile()
        profile["state"] = ["READY"]
        result = self.run_generator(profile)
        self.assertEqual(result.returncode, 2)
        self.assertIn("profile contains unknown field(s): state", result.stderr)

    def test_unknown_claim_field_is_rejected(self) -> None:
        profile = base_profile()
        profile["claims"][0]["probablity"] = 3
        result = self.run_generator(profile)
        self.assertEqual(result.returncode, 2)
        self.assertIn("claims[0] contains unknown field(s): probablity", result.stderr)

    def test_unknown_safety_field_is_rejected(self) -> None:
        profile = base_profile()
        profile["safety"]["forbiden"] = ["delete data"]
        result = self.run_generator(profile)
        self.assertEqual(result.returncode, 2)
        self.assertIn("safety contains unknown field(s): forbiden", result.stderr)

    def test_markdown_html_links_and_images_are_neutralized(self) -> None:
        profile = base_profile()
        profile["claims"][0]["statement"] = (
            "a|b\n<script>alert(1)</script> "
            "![pixel](https://example.invalid/pixel) [click](http://example.invalid/)"
        )
        result = self.run_generator(profile)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(r"a\|b<br>&lt;script&gt;alert\(1\)&lt;/script&gt;", result.stdout)
        self.assertNotIn("<script>", result.stdout)
        self.assertNotIn("](", result.stdout)
        self.assertNotIn("https://", result.stdout)
        self.assertNotIn("http://", result.stdout)
        self.assertIn("https&#58;//", result.stdout)

    def test_common_gfm_autolinks_are_neutralized(self) -> None:
        profile = base_profile()
        profile["claims"][0]["statement"] = "www.tracker.invalid/p user@example.invalid"
        result = self.run_generator(profile)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("www.tracker.invalid", result.stdout)
        self.assertNotIn("user@example.invalid", result.stdout)
        self.assertIn("www&#46;tracker.invalid", result.stdout)
        self.assertIn("user&#64;example.invalid", result.stdout)

    def test_generator_uses_schema_as_structural_source_of_truth(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("Draft202012Validator", source)
        self.assertIn("schemas\" / \"profile.schema.json", source)
        self.assertNotIn("ROOT_KEYS =", source)
        self.assertNotIn("def bounded_int", source)
        self.assertNotIn("def reject_unknown_keys", source)

    def test_schema_forbids_unknown_properties_at_all_object_levels(self) -> None:
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        self.assertFalse(schema["additionalProperties"])
        self.assertFalse(schema["properties"]["claims"]["items"]["additionalProperties"])
        self.assertFalse(schema["properties"]["safety"]["additionalProperties"])
        claim_schema = schema["properties"]["claims"]["items"]["properties"]
        self.assertTrue(claim_schema["lenses"]["uniqueItems"])
        self.assertEqual(claim_schema["id"]["pattern"], "^[A-Za-z][A-Za-z0-9_.-]*$")

    def test_max_scenarios_reports_coverage_and_omissions(self) -> None:
        profile = base_profile()
        profile["claims"] = [
            {
                "id": "C1", "statement": "first", "impact": 5, "probability": 5,
                "lenses": ["repeat", "timing"],
            },
            {
                "id": "C2", "statement": "second", "impact": 4, "probability": 4,
                "lenses": ["interrupt", "resource"],
            },
        ]
        result = self.run_generator(profile, "--max-scenarios", "2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("coverage: scenarios 2/4", result.stderr)
        self.assertIn("covered claims: C1", result.stderr)
        self.assertIn("omitted claims: C2", result.stderr)
        self.assertIn("C2:interrupt,resource", result.stderr)



if __name__ == "__main__":
    unittest.main()
