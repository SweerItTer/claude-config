from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]

from scripts.validate_campaign import ValidationInputError, load_evidence_manifest, validate_text


class EvidenceManifestTests(unittest.TestCase):
    def copy_example(self, tmp: Path) -> Path:
        (tmp / "artifacts").mkdir()
        for item in (ROOT / "examples" / "artifacts").iterdir():
            shutil.copy2(item, tmp / "artifacts" / item.name)
        target = tmp / "evidence.json"
        target.write_text((ROOT / "examples" / "evidence-manifest.json").read_text(encoding="utf-8"), encoding="utf-8")
        return target

    def test_valid_manifest_verifies_local_hashes(self) -> None:
        ids, errors, warnings = load_evidence_manifest(
            ROOT / "examples" / "evidence-manifest.json", require_artifacts=True
        )
        self.assertIn("EV-RECOVERY", ids)
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])

    def test_hash_mismatch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            manifest = self.copy_example(tmp)
            (tmp / "artifacts" / "s01-oracle.log").write_text("tampered\n", encoding="utf-8")
            _, errors, _ = load_evidence_manifest(manifest, require_artifacts=True)
            self.assertTrue(any("SHA-256 mismatch" in item for item in errors))

    def test_duplicate_evidence_id_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            manifest = self.copy_example(tmp)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["evidence"].append(dict(data["evidence"][0]))
            manifest.write_text(json.dumps(data), encoding="utf-8")
            _, errors, _ = load_evidence_manifest(manifest, require_artifacts=False)
            self.assertTrue(any("duplicate evidence ID" in item for item in errors))

    def test_unknown_parent_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            manifest = self.copy_example(tmp)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["evidence"][0]["parents"] = ["EV-MISSING"]
            manifest.write_text(json.dumps(data), encoding="utf-8")
            _, errors, _ = load_evidence_manifest(manifest, require_artifacts=False)
            self.assertTrue(any("unknown parent" in item for item in errors))

    def test_lineage_cycle_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            manifest = self.copy_example(tmp)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["evidence"][0]["parents"] = [data["evidence"][1]["id"]]
            data["evidence"][1]["parents"] = [data["evidence"][0]["id"]]
            manifest.write_text(json.dumps(data), encoding="utf-8")
            _, errors, _ = load_evidence_manifest(manifest, require_artifacts=False)
            self.assertTrue(any("lineage cycle" in item for item in errors))

    def test_artifact_path_escape_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            manifest = self.copy_example(tmp)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["evidence"][0]["artifact"] = "../outside.log"
            manifest.write_text(json.dumps(data), encoding="utf-8")
            _, errors, _ = load_evidence_manifest(manifest, require_artifacts=False)
            self.assertTrue(any("escapes manifest directory" in item for item in errors))

    def test_remote_artifact_cannot_satisfy_require_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            manifest = self.copy_example(tmp)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["evidence"][0]["artifact"] = "s3://bucket/evidence.log"
            manifest.write_text(json.dumps(data), encoding="utf-8")
            _, errors, _ = load_evidence_manifest(manifest, require_artifacts=True)
            self.assertTrue(any("remote artifact URI" in item for item in errors))

    def test_invalid_timestamp_is_schema_error(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            manifest = self.copy_example(tmp)
            data = json.loads(manifest.read_text(encoding="utf-8"))
            data["evidence"][0]["captured_at"] = "yesterday"
            manifest.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaises(ValidationInputError):
                load_evidence_manifest(manifest, require_artifacts=False)

    def test_pass_campaign_requires_manifest_for_ev_refs(self) -> None:
        text = (ROOT / "examples" / "embedded-wifi-completed-campaign.md").read_text(encoding="utf-8")
        errors, _, _ = validate_text(text, strict=True, allow_placeholders=False, evidence_ids=None)
        self.assertTrue(any("evidence manifest is required" in item for item in errors))

    def test_unknown_campaign_evidence_id_is_rejected(self) -> None:
        text = (ROOT / "examples" / "embedded-wifi-completed-campaign.md").read_text(encoding="utf-8")
        text = text.replace("EV-S01-ORACLE", "EV-DOES-NOT-EXIST", 1)
        ids, _, _ = load_evidence_manifest(ROOT / "examples" / "evidence-manifest.json", require_artifacts=False)
        errors, _, _ = validate_text(text, strict=True, allow_placeholders=False, evidence_ids=ids)
        self.assertTrue(any("unknown evidence ID" in item for item in errors))

    def test_artifact_hashing_does_not_use_read_bytes(self) -> None:
        with mock.patch.object(Path, "read_bytes", side_effect=AssertionError("read_bytes must not be used")):
            ids, errors, warnings = load_evidence_manifest(
                ROOT / "examples" / "evidence-manifest.json", require_artifacts=True
            )
        self.assertIn("EV-RECOVERY", ids)
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])



if __name__ == "__main__":
    unittest.main()
