#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = SKILL_ROOT / "scripts"


def run(cmd: list[str], cwd: Path, expect: int | None = 0) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(cmd, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
    if expect is not None and proc.returncode != expect:
        raise AssertionError(f"command failed ({proc.returncode} != {expect}): {' '.join(cmd)}\n{proc.stdout}")
    return proc


def git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return run(["git", *args], repo)


def init_git(repo: Path) -> None:
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "test@example.com")
    git(repo, "config", "user.name", "Test User")


def write(path: Path, text: str = "") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def default_tree(repo: Path) -> None:
    for rel in ("docs/requirement", "docs/specs", "docs/dev-guide", "docs/analysis", "docs/archive"):
        (repo / rel).mkdir(parents=True, exist_ok=True)
    write(repo / "AGENTS.md", "# Instructions\n\nSee docs/dev-guide/document-governance.md.\n")
    write(repo / "docs/dev-guide/document-governance.md", "# Governance\n")
    write(repo / "docs/TODO.md", "# TODO\n\n- [ ] Test\n")


def valid_spec(title: str = "Lines model") -> str:
    return f"""---
title: {title}
status: active
kind: design
created: 2026-08-05
updated: 2026-08-05
---

# S14: {title}

## Decisions

### D1: Keep identity stable

**Selected:** Stable IDs.
"""


def valid_requirement() -> str:
    return """---
title: Network behavior
created: 2026-08-05
source: internal
---

# R03: Network behavior

### R03-1
"""


class GovernanceAuditTests(unittest.TestCase):
    def audit(self, repo: Path) -> dict:
        proc = run([sys.executable, str(SCRIPTS / "audit_docs.py"), "--repo", str(repo), "--json"], repo)
        return json.loads(proc.stdout)

    def codes(self, report: dict, level: str) -> set[str]:
        return {item["code"] for item in report[level]}

    def test_default_taxonomy_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            default_tree(repo)
            report = self.audit(repo)
            self.assertIn("DEFAULT_MAPPING_SELECTED", self.codes(report, "pass"))
            self.assertIn("TAXONOMY_PRESENT", self.codes(report, "pass"))
            self.assertNotIn("TAXONOMY_UNDECLARED_OR_INCOMPLETE", self.codes(report, "fix"))

    def test_custom_taxonomy_mapping_does_not_require_default_paths(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            config = {
                "version": 1,
                "canonical_instruction": "AGENTS.md",
                "governance_file": "documentation/handbook/governance.md",
                "paths": {
                    "requirement": "documentation/requirements",
                    "specs": "documentation/design",
                    "dev_guide": "documentation/guides",
                    "analysis": "documentation/investigations",
                    "archive": "documentation/history",
                    "todo": "documentation/TODO.md",
                },
            }
            write(repo / ".project-governance.json", json.dumps(config, indent=2))
            for rel in config["paths"].values():
                path = repo / rel
                if path.suffix:
                    write(path, "# TODO\n")
                else:
                    path.mkdir(parents=True, exist_ok=True)
            write(repo / "AGENTS.md", "See documentation/handbook/governance.md\n")
            write(repo / "documentation/handbook/governance.md", "# Governance\n")
            write(repo / "documentation/design/S14-lines-model.md", valid_spec())
            write(repo / "documentation/requirements/R03-network.md", valid_requirement())

            report = self.audit(repo)
            self.assertIn("GOVERNANCE_MAPPING_DECLARED", self.codes(report, "pass"))
            self.assertIn("TAXONOMY_PRESENT", self.codes(report, "pass"))
            self.assertNotIn("CONFIGURED_TAXONOMY_INCOMPLETE", self.codes(report, "fix"))
            self.assertNotIn("GOVERNANCE_RULE_MISSING", self.codes(report, "fix"))

    def test_semantic_id_plus_navigation_link_is_legal(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            default_tree(repo)
            write(repo / "docs/specs/S14-lines-model.md", valid_spec())
            write(
                repo / "docs/dev-guide/navigation.md",
                "参见 S14《Lines model》：[文档](../specs/S14-lines-model.md)\n",
            )
            report = self.audit(repo)
            offenders = [item for item in report["improve"] if item["code"] == "PATH_BASED_RS_REFERENCE"]
            self.assertEqual([], offenders)
            self.assertIn("NO_PATH_ONLY_RS_REFERENCES", self.codes(report, "pass"))

    def test_path_only_navigation_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            default_tree(repo)
            write(repo / "docs/specs/S14-lines-model.md", valid_spec())
            write(repo / "docs/dev-guide/navigation.md", "参见[文档](../specs/S14-lines-model.md)。\n")
            report = self.audit(repo)
            offenders = [item for item in report["improve"] if item["code"] == "PATH_BASED_RS_REFERENCE"]
            self.assertEqual(1, len(offenders))
            self.assertEqual("docs/dev-guide/navigation.md", offenders[0]["path"])


    def test_guide_filename_reference_is_not_a_duplicate_identity(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            default_tree(repo)
            write(repo / "docs/specs/S14-lines.md", valid_spec("Lines"))
            write(repo / "docs/dev-guide/S14-implementation-guide.md", "# S14 implementation guide\n")

            report = self.audit(repo)
            duplicates = [item for item in report["blocking"] if item["code"] == "DUPLICATE_STABLE_ID"]
            self.assertEqual([], duplicates)
            self.assertIn("STABLE_IDS_UNIQUE", self.codes(report, "pass"))

            inventory = run(
                [sys.executable, str(SCRIPTS / "inspect_docs.py"), "--repo", str(repo), "--json"],
                repo,
            )
            data = json.loads(inventory.stdout)
            self.assertEqual({}, data["stable_ids"]["duplicates"])
            self.assertEqual(["docs/specs/S14-lines.md"], data["stable_ids"]["locations"]["S14"])

    def test_bootstrap_rejects_symlink_escape_without_external_writes(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo = root / "repo"
            outside = root / "outside"
            repo.mkdir()
            outside.mkdir()
            (repo / "documentation").symlink_to(outside, target_is_directory=True)
            config = {
                "version": 1,
                "governance_file": "documentation/guides/governance.md",
                "paths": {
                    "requirement": "documentation/requirements",
                    "specs": "documentation/design",
                    "dev_guide": "documentation/guides",
                    "analysis": "documentation/investigations",
                    "archive": "documentation/history",
                    "todo": "documentation/TODO.md",
                },
            }
            write(repo / ".project-governance.json", json.dumps(config))

            proc = run(
                [sys.executable, str(SCRIPTS / "bootstrap_docs.py"), "--repo", str(repo)],
                repo,
                expect=2,
            )
            self.assertIn("resolves outside the repository", proc.stdout)
            self.assertEqual([], list(outside.rglob("*")))

            audit = run(
                [sys.executable, str(SCRIPTS / "audit_docs.py"), "--repo", str(repo), "--json"],
                repo,
                expect=2,
            )
            report = json.loads(audit.stdout)
            self.assertIn("GOVERNANCE_CONFIG_INVALID", self.codes(report, "blocking"))

    def test_custom_bootstrap_uses_mapped_paths(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            config = {
                "version": 1,
                "governance_file": "documentation/guides/governance.md",
                "paths": {
                    "requirement": "documentation/requirements",
                    "specs": "documentation/design",
                    "dev_guide": "documentation/guides",
                    "analysis": "documentation/investigations",
                    "archive": "documentation/history",
                    "todo": "documentation/TODO.md",
                },
            }
            write(repo / ".project-governance.json", json.dumps(config))
            run([sys.executable, str(SCRIPTS / "bootstrap_docs.py"), "--repo", str(repo)], repo)
            self.assertTrue((repo / "documentation/requirements/_TEMPLATE.md").is_file())
            self.assertTrue((repo / "documentation/design/_TEMPLATE.md").is_file())
            self.assertTrue((repo / "documentation/guides/governance.md").is_file())
            self.assertFalse((repo / "docs/requirement").exists())

    def test_config_rejects_file_directory_role_conflict_before_bootstrap_writes(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            config = {
                "version": 1,
                "governance_file": "docs/dev-guide",
                "paths": {
                    "requirement": "docs/requirement",
                    "specs": "docs/specs",
                    "dev_guide": "docs/dev-guide",
                    "analysis": "docs/analysis",
                    "archive": "docs/archive",
                    "todo": "docs/TODO.md",
                },
            }
            write(repo / ".project-governance.json", json.dumps(config))

            proc = run(
                [sys.executable, str(SCRIPTS / "bootstrap_docs.py"), "--repo", str(repo)],
                repo,
                expect=2,
            )
            self.assertIn("conflicts with directory role", proc.stdout)
            self.assertFalse((repo / "docs").exists())

            audit = run(
                [sys.executable, str(SCRIPTS / "audit_docs.py"), "--repo", str(repo), "--json"],
                repo,
                expect=2,
            )
            report = json.loads(audit.stdout)
            self.assertIn("GOVERNANCE_CONFIG_INVALID", self.codes(report, "blocking"))

    def test_config_rejects_existing_directory_for_file_role(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            (repo / "docs/local-todo").mkdir(parents=True)
            config = {
                "version": 1,
                "governance_file": "docs/dev-guide/governance.md",
                "paths": {
                    "requirement": "docs/requirement",
                    "specs": "docs/specs",
                    "dev_guide": "docs/dev-guide",
                    "analysis": "docs/analysis",
                    "archive": "docs/archive",
                    "todo": "docs/local-todo",
                },
            }
            write(repo / ".project-governance.json", json.dumps(config))

            audit = run(
                [sys.executable, str(SCRIPTS / "audit_docs.py"), "--repo", str(repo), "--json"],
                repo,
                expect=2,
            )
            report = json.loads(audit.stdout)
            findings = [item for item in report["blocking"] if item["code"] == "GOVERNANCE_CONFIG_INVALID"]
            self.assertEqual(1, len(findings))
            self.assertIn("regular file or absent", findings[0]["detail"])

    def test_audit_ignores_source_code_paths_and_inline_link_examples(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            default_tree(repo)
            write(repo / "scripts/example.py", 'PATTERN = r"/home/example/private"\n')
            write(
                repo / "docs/dev-guide/examples.md",
                "Use inline Markdown syntax like `[label](missing-example.md)` in examples.\n",
            )

            report = self.audit(repo)
            self.assertNotIn("MACHINE_ABSOLUTE_PATH", self.codes(report, "fix"))
            self.assertNotIn("BROKEN_MARKDOWN_LINK", self.codes(report, "fix"))
            self.assertIn("NO_MACHINE_ABSOLUTE_PATHS", self.codes(report, "pass"))
            self.assertIn("NO_BROKEN_MARKDOWN_LINKS", self.codes(report, "pass"))


    def test_explicit_configured_directories_override_generic_ignore_names(self) -> None:
        for configured_name in ("distributed-specs", "installation-guides", "building-guides", "dist"):
            with self.subTest(configured_name=configured_name), tempfile.TemporaryDirectory() as td:
                repo = Path(td)
                config = {
                    "version": 1,
                    "governance_file": "docs/guides/governance.md",
                    "paths": {
                        "requirement": "docs/requirements",
                        "specs": f"docs/{configured_name}",
                        "dev_guide": "docs/guides",
                        "analysis": "docs/analysis",
                        "archive": "docs/archive",
                        "todo": "docs/TODO.md",
                    },
                }
                write(repo / ".project-governance.json", json.dumps(config))
                for key, rel in config["paths"].items():
                    if key == "todo":
                        write(repo / rel, "# TODO\n")
                    else:
                        (repo / rel).mkdir(parents=True, exist_ok=True)
                write(repo / "docs/guides/governance.md", "# Governance\n")
                write(repo / f"docs/{configured_name}/no-id.md", "# Missing identity and metadata\n")

                report = self.audit(repo)
                self.assertIn("STABLE_ID_MISSING", self.codes(report, "fix"))
                self.assertIn("FRONTMATTER_MISSING", self.codes(report, "fix"))
                inventory = run(
                    [sys.executable, str(SCRIPTS / "inspect_docs.py"), "--repo", str(repo), "--json"],
                    repo,
                )
                data = json.loads(inventory.stdout)
                self.assertEqual(1, data["documents"]["by_class"]["specs"])

    def test_config_rejects_nested_directory_roles(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            config = {
                "version": 1,
                "governance_file": "docs/guides/governance.md",
                "paths": {
                    "requirement": "docs/req",
                    "specs": "docs",
                    "dev_guide": "docs/guides",
                    "analysis": "docs/analysis",
                    "archive": "docs/archive",
                    "todo": "docs/TODO.md",
                },
            }
            write(repo / ".project-governance.json", json.dumps(config))
            audit = run(
                [sys.executable, str(SCRIPTS / "audit_docs.py"), "--repo", str(repo), "--json"],
                repo,
                expect=2,
            )
            report = json.loads(audit.stdout)
            finding = next(item for item in report["blocking"] if item["code"] == "GOVERNANCE_CONFIG_INVALID")
            self.assertIn("non-overlapping", finding["detail"])

    def test_commonmark_inline_link_destinations_are_not_misreported(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            default_tree(repo)
            write(repo / "docs/dev-guide/file name.md", "# Space\n")
            write(repo / "docs/dev-guide/foo(bar).md", "# Paren\n")
            write(repo / "docs/dev-guide/titled.md", "# Title\n")
            write(
                repo / "docs/dev-guide/links.md",
                "[space](<file name.md>)\n\n"
                "[paren](foo(bar).md)\n\n"
                "[title](titled.md \"Governance\")\n",
            )
            report = self.audit(repo)
            self.assertNotIn("BROKEN_MARKDOWN_LINK", self.codes(report, "fix"))

    def test_reference_style_link_is_resolved_without_false_positive(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            default_tree(repo)
            write(repo / "docs/specs/S14-lines-model.md", valid_spec())
            write(
                repo / "docs/dev-guide/reference-links.md",
                "参见 S14《Lines model》：[设计][lines]\n\n"
                "[lines]: ../specs/S14-lines-model.md \"Lines\"\n",
            )
            report = self.audit(repo)
            self.assertNotIn("BROKEN_MARKDOWN_LINK", self.codes(report, "fix"))
            self.assertNotIn("PATH_BASED_RS_REFERENCE", self.codes(report, "improve"))


class WorkspaceGuardTests(unittest.TestCase):
    def make_dirty_repo(self, repo: Path) -> None:
        init_git(repo)
        write(repo / "docs/a.md", "a0\n")
        write(repo / "docs/b.md", "b0\n")
        write(repo / "docs/clean.md", "clean\n")
        git(repo, "add", ".")
        git(repo, "commit", "-qm", "initial")
        write(repo / "docs/a.md", "a1 unstaged\n")
        write(repo / "docs/b.md", "b1 staged\n")
        git(repo, "add", "docs/b.md")
        write(repo / "docs/c.md", "c untracked\n")

    def snapshot(self, repo: Path, baseline: Path) -> None:
        run(
            [sys.executable, str(SCRIPTS / "workspace_guard.py"), "snapshot", "--repo", str(repo), "--output", str(baseline)],
            repo,
        )

    def check_plan(self, repo: Path, baseline: Path, *paths: str, expect: int = 0) -> subprocess.CompletedProcess[str]:
        cmd = [
            sys.executable,
            str(SCRIPTS / "workspace_guard.py"),
            "check-plan",
            "--repo",
            str(repo),
            "--baseline",
            str(baseline),
        ]
        for path in paths:
            cmd.extend(["--path", path])
        return run(cmd, repo, expect=expect)

    def test_plan_blocks_staged_unstaged_and_untracked_targets(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            self.make_dirty_repo(repo)
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            for path in ("docs/a.md", "docs/b.md", "docs/c.md", "docs"):
                proc = run(
                    [
                        sys.executable,
                        str(SCRIPTS / "workspace_guard.py"),
                        "check-plan",
                        "--repo",
                        str(repo),
                        "--baseline",
                        str(baseline),
                        "--path",
                        path,
                    ],
                    repo,
                    expect=2,
                )
                self.assertIn("BLOCKING", proc.stdout)

            proc = run(
                [
                    sys.executable,
                    str(SCRIPTS / "workspace_guard.py"),
                    "check-plan",
                    "--repo",
                    str(repo),
                    "--baseline",
                    str(baseline),
                    "--path",
                    "docs/new.md",
                ],
                repo,
            )
            self.assertIn("safe plan", proc.stdout)

    def test_verify_allows_new_governance_changes_but_detects_protected_rewrite(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            self.make_dirty_repo(repo)
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            self.check_plan(repo, baseline, "docs/new.md")
            write(repo / "docs/new.md", "governance change\n")
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
            )
            self.assertIn("PASS", proc.stdout)
            self.assertIn("docs/new.md", proc.stdout)

            write(repo / "docs/a.md", "overwritten\n")
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("BLOCKING", proc.stdout)
            self.assertIn("docs/a.md", proc.stdout)

    def test_verify_detects_index_only_rewrite(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            self.make_dirty_repo(repo)
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)

            worktree_before = (repo / "docs/b.md").read_bytes()
            blob = subprocess.run(
                ["git", "hash-object", "-w", "--stdin"],
                cwd=repo,
                input=b"index-only replacement\n",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            ).stdout.decode("ascii").strip()
            git(repo, "update-index", "--cacheinfo", f"100644,{blob},docs/b.md")
            self.assertEqual(worktree_before, (repo / "docs/b.md").read_bytes())

            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("BLOCKING", proc.stdout)
            self.assertIn("docs/b.md", proc.stdout)
            self.assertIn("Git index", proc.stdout)

    def test_verify_detects_preexisting_untracked_file_being_staged(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            self.make_dirty_repo(repo)
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)

            content_before = (repo / "docs/c.md").read_bytes()
            git(repo, "add", "docs/c.md")
            self.assertEqual(content_before, (repo / "docs/c.md").read_bytes())

            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("BLOCKING", proc.stdout)
            self.assertIn("docs/c.md", proc.stdout)
            self.assertIn("classification changed", proc.stdout)


    def test_verify_rejects_newly_staged_governance_file(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            write(repo / "README.md", "seed\n")
            git(repo, "add", "README.md")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)

            write(repo / "docs/new-governance.md", "new\n")
            git(repo, "add", "docs/new-governance.md")
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("authorization boundary", proc.stdout)
            self.assertIn("new paths were staged", proc.stdout)
            self.assertIn("docs/new-governance.md", proc.stdout)

    def test_verify_rejects_commit_after_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            write(repo / "README.md", "seed\n")
            git(repo, "add", "README.md")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)

            write(repo / "docs/new-governance.md", "new\n")
            git(repo, "add", "docs/new-governance.md")
            git(repo, "commit", "-qm", "unauthorized governance commit")
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("authorization boundary", proc.stdout)
            self.assertIn("HEAD changed", proc.stdout)


    def test_verify_rejects_branch_change(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            write(repo / "README.md", "seed\n")
            git(repo, "add", "README.md")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)

            git(repo, "switch", "-qc", "governance-temp")
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("authorization boundary", proc.stdout)
            self.assertIn("branch changed", proc.stdout)

    def test_snapshot_records_all_unmerged_index_stages(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            write(repo / "conflict.md", "base\n")
            git(repo, "add", "conflict.md")
            git(repo, "commit", "-qm", "base")
            original_branch = git(repo, "branch", "--show-current").stdout.strip()

            git(repo, "checkout", "-qb", "side")
            write(repo / "conflict.md", "side\n")
            git(repo, "commit", "-qam", "side")

            git(repo, "checkout", "-q", original_branch)
            write(repo / "conflict.md", "main\n")
            git(repo, "commit", "-qam", "main")
            merge = run(["git", "merge", "side"], repo, expect=None)
            self.assertNotEqual(0, merge.returncode)

            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            data = json.loads(baseline.read_text(encoding="utf-8"))
            entries = data["snapshot"]["preexisting"]["conflict.md"]["index"]
            self.assertEqual([1, 2, 3], [entry["stage"] for entry in entries])

    def test_filesystem_move_of_clean_tracked_document_stays_unstaged_and_verifies(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            write(repo / "docs/old.md", "old\n")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            self.check_plan(repo, baseline, "docs/old.md", "docs/new.md")

            (repo / "docs/new.md").parent.mkdir(parents=True, exist_ok=True)
            (repo / "docs/old.md").rename(repo / "docs/new.md")

            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
            )
            self.assertIn("PASS", proc.stdout)
            cached = git(repo, "diff", "--cached", "--name-only").stdout.strip()
            self.assertEqual("", cached)
            status = git(repo, "status", "--short").stdout
            self.assertIn("docs/old.md", status)
            self.assertIn("docs/new.md", status)

    def test_ignored_paths_are_blocked_enrolled_and_verified(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            write(repo / ".gitignore", "ignored.md\nignored-dir/\n")
            git(repo, "add", ".gitignore")
            git(repo, "commit", "-qm", "initial")
            write(repo / "ignored.md", "secret\n")
            write(repo / "ignored-dir/sub/user.md", "private\n")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)

            exact = run(
                [
                    sys.executable,
                    str(SCRIPTS / "workspace_guard.py"),
                    "check-plan",
                    "--repo",
                    str(repo),
                    "--baseline",
                    str(baseline),
                    "--path",
                    "ignored.md",
                ],
                repo,
                expect=2,
            )
            self.assertIn("ignored.md", exact.stdout)
            parent = run(
                [
                    sys.executable,
                    str(SCRIPTS / "workspace_guard.py"),
                    "check-plan",
                    "--repo",
                    str(repo),
                    "--baseline",
                    str(baseline),
                    "--path",
                    "ignored-dir",
                ],
                repo,
                expect=2,
            )
            self.assertIn("ignored-dir/sub/user.md", parent.stdout)

            data = json.loads(baseline.read_text(encoding="utf-8"))
            self.assertIn("ignored.md", data["authorization"]["enrolled_ignored"])
            self.assertIn("ignored-dir/sub/user.md", data["authorization"]["enrolled_ignored"])
            self.assertIn("ignored", data["authorization"]["enrolled_ignored"]["ignored.md"]["states"])

            write(repo / "ignored.md", "overwritten\n")
            verify = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("ignored.md", verify.stdout)
            self.assertIn("BLOCKING", verify.stdout)

    def test_plan_blocks_internal_symlink_alias_to_protected_path(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            write(repo / "actual/user.md", "base\n")
            (repo / "alias").symlink_to("actual", target_is_directory=True)
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            write(repo / "actual/user.md", "user change\n")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)

            proc = run(
                [
                    sys.executable,
                    str(SCRIPTS / "workspace_guard.py"),
                    "check-plan",
                    "--repo",
                    str(repo),
                    "--baseline",
                    str(baseline),
                    "--path",
                    "alias/user.md",
                ],
                repo,
                expect=2,
            )
            self.assertIn("actual/user.md", proc.stdout)
            self.assertIn("resolved: actual/user.md", proc.stdout)


    def test_verify_blocks_clean_source_file_modified_outside_plan(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            write(repo / "src/app.py", "print(1)\n")
            write(repo / "docs/guide.md", "# Guide\n")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            self.check_plan(repo, baseline, "docs/guide.md")
            write(repo / "src/app.py", "print(2)\n")
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("not approved by check-plan", proc.stdout)
            self.assertIn("src/app.py", proc.stdout)

    def test_check_plan_rejects_source_code_path(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            write(repo / "src/app.py", "print(1)\n")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            proc = self.check_plan(repo, baseline, "src/app.py", expect=2)
            self.assertIn("documentation-file whitelist", proc.stdout)

    def test_check_plan_rejects_document_path_resolving_to_source_code(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            write(repo / "src/app.py", "print(1)\n")
            (repo / "docs/specs").mkdir(parents=True)
            (repo / "docs/specs/alias.md").symlink_to("../../src/app.py")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            proc = self.check_plan(repo, baseline, "docs/specs/alias.md", expect=2)
            self.assertIn("documentation-file whitelist", proc.stdout)

    def test_verify_blocks_unplanned_document_change(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            write(repo / "docs/planned.md", "planned\n")
            write(repo / "docs/unplanned.md", "unplanned\n")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            self.check_plan(repo, baseline, "docs/planned.md")
            write(repo / "docs/unplanned.md", "changed\n")
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("docs/unplanned.md", proc.stdout)

    def test_verify_allows_planned_tracked_document_change(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            write(repo / "docs/planned.md", "before\n")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            self.check_plan(repo, baseline, "docs/planned.md")
            write(repo / "docs/planned.md", "after\n")
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
            )
            self.assertIn("approved-plan changed paths", proc.stdout)

    def test_verify_rejects_intent_to_add_index_entry(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            write(repo / "README.md", "seed\n")
            git(repo, "add", "README.md")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            self.check_plan(repo, baseline, "docs/new.md")
            write(repo / "docs/new.md", "new\n")
            git(repo, "add", "-N", "docs/new.md")
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("Git index changed", proc.stdout)
            self.assertIn("docs/new.md", proc.stdout)

    def test_check_plan_persists_lexical_and_resolved_allowlist(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            (repo / "docs").mkdir()
            (repo / "alias").symlink_to("docs", target_is_directory=True)
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            self.check_plan(repo, baseline, "alias/new.md")
            data = json.loads(baseline.read_text(encoding="utf-8"))
            self.assertIn(
                {"lexical": "alias/new.md", "resolved": "docs/new.md", "kind": "file"},
                data["authorization"]["approved_paths"],
            )


    def test_external_uri_schemes_are_not_treated_as_local_files(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            default_tree(repo)
            write(
                repo / "docs/dev-guide/links.md",
                "\n".join(
                    [
                        "[FTP](ftp://example.com/file)",
                        "[Telephone](tel:+123456789)",
                        "[SSH](ssh://host/path)",
                        "[Upper](HTTPS://example.com/path)",
                        "[Network](//example.com/path)",
                    ]
                )
                + "\n",
            )
            proc = run([sys.executable, str(SCRIPTS / "audit_docs.py"), "--repo", str(repo), "--json"], repo)
            report = json.loads(proc.stdout)
            broken = [item for item in report["fix"] if item["code"] == "BROKEN_MARKDOWN_LINK"]
            self.assertEqual([], broken)


class WorkspaceGuardBoundaryV7Tests(unittest.TestCase):
    def snapshot(self, repo: Path, baseline: Path) -> None:
        run(
            [sys.executable, str(SCRIPTS / "workspace_guard.py"), "snapshot", "--repo", str(repo), "--output", str(baseline)],
            repo,
        )

    def check_plan(self, repo: Path, baseline: Path, *paths: str, expect: int = 0) -> subprocess.CompletedProcess[str]:
        cmd = [
            sys.executable,
            str(SCRIPTS / "workspace_guard.py"),
            "check-plan",
            "--repo",
            str(repo),
            "--baseline",
            str(baseline),
        ]
        for path in paths:
            cmd.extend(["--path", path])
        return run(cmd, repo, expect=expect)

    def test_exact_source_file_inside_governance_directory_is_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            write(repo / "docs/specs/helper.py", 'print("safe")\n')
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            proc = self.check_plan(repo, baseline, "docs/specs/helper.py", expect=2)
            self.assertIn("documentation-file whitelist", proc.stdout)

    def test_directory_plan_with_existing_source_file_is_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            write(repo / "docs/specs/helper.py", 'print("safe")\n')
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            proc = self.check_plan(repo, baseline, "docs/specs", expect=2)
            self.assertIn("docs/specs/helper.py", proc.stdout)

    def test_directory_plan_cannot_authorize_later_source_change(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            self.check_plan(repo, baseline, "docs/specs")
            write(repo / "docs/specs/helper.py", 'print("modified")\n')
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("documentation-only", proc.stdout)
            self.assertIn("docs/specs/helper.py", proc.stdout)

    def test_file_plan_cannot_be_replaced_by_directory_with_source(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            self.check_plan(repo, baseline, "docs/specs/S15-new.md")
            write(repo / "docs/specs/S15-new.md/helper.py", "print(1)\n")
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("docs/specs/S15-new.md/helper.py", proc.stdout)

    def test_verify_detects_index_flags_added_after_baseline(self) -> None:
        for flag in ("--assume-unchanged", "--skip-worktree"):
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as td:
                repo = Path(td)
                init_git(repo)
                write(repo / "src/app.py", "print(1)\n")
                git(repo, "add", ".")
                git(repo, "commit", "-qm", "initial")
                baseline = repo.parent / f"{repo.name}-baseline.json"
                self.snapshot(repo, baseline)
                git(repo, "update-index", flag, "src/app.py")
                write(repo / "src/app.py", "print(2)\n")
                proc = run(
                    [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                    repo,
                    expect=2,
                )
                self.assertIn("index assume-unchanged/skip-worktree", proc.stdout)

    def test_baseline_hidden_index_file_is_fingerprinted(self) -> None:
        for flag in ("--assume-unchanged", "--skip-worktree"):
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as td:
                repo = Path(td)
                init_git(repo)
                write(repo / "src/app.py", "print(1)\n")
                git(repo, "add", ".")
                git(repo, "commit", "-qm", "initial")
                git(repo, "update-index", flag, "src/app.py")
                baseline = repo.parent / f"{repo.name}-baseline.json"
                self.snapshot(repo, baseline)
                data = json.loads(baseline.read_text(encoding="utf-8"))
                self.assertIn("src/app.py", data["snapshot"]["preexisting"])
                self.assertIn("index-hidden", data["snapshot"]["preexisting"]["src/app.py"]["states"])
                write(repo / "src/app.py", "print(2)\n")
                proc = run(
                    [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                    repo,
                    expect=2,
                )
                self.assertIn("worktree fingerprint changed", proc.stdout)

    def test_nonexistent_ignored_exact_target_is_blocked_before_write(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            write(repo / ".gitignore", "docs/specs/generated/\n")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            proc = self.check_plan(repo, baseline, "docs/specs/generated/S01.md", expect=2)
            self.assertIn("docs/specs/generated/S01.md", proc.stdout)
            data = json.loads(baseline.read_text(encoding="utf-8"))
            self.assertEqual("missing", data["authorization"]["enrolled_ignored"]["docs/specs/generated/S01.md"]["worktree"]["kind"])

    def test_new_ignored_file_under_approved_directory_is_observed_and_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            write(repo / ".gitignore", "docs/specs/generated/\n")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / f"{repo.name}-baseline.json"
            self.snapshot(repo, baseline)
            self.check_plan(repo, baseline, "docs/specs")
            write(repo / "docs/specs/generated/S01.md", "# S01\n")
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("new ignored paths", proc.stdout)
            self.assertIn("docs/specs/generated/S01.md", proc.stdout)
            self.assertNotIn("changed paths observed: 0", proc.stdout)

    def _create_superproject_with_submodule(self, root: Path) -> tuple[Path, Path]:
        child = root / "child"
        child.mkdir()
        init_git(child)
        write(child / "file.txt", "base\n")
        git(child, "add", ".")
        git(child, "commit", "-qm", "child initial")

        repo = root / "super"
        repo.mkdir()
        init_git(repo)
        run(
            ["git", "-c", "protocol.file.allow=always", "submodule", "add", str(child), "sub"],
            repo,
        )
        git(repo, "commit", "-qm", "add submodule")
        return repo, repo / "sub"

    def test_dirty_submodule_tracked_content_blocks_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo, sub = self._create_superproject_with_submodule(Path(td))
            write(sub / "file.txt", "user change 1\n")
            baseline = repo.parent / "baseline.json"
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "snapshot", "--repo", str(repo), "--output", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("dirty submodule is not supported", proc.stdout)
            self.assertFalse(baseline.exists())

    def test_dirty_submodule_untracked_and_staged_content_block_snapshot(self) -> None:
        for state in ("untracked", "staged"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as td:
                repo, sub = self._create_superproject_with_submodule(Path(td))
                write(sub / "user.txt", "one\n")
                if state == "staged":
                    git(sub, "add", "user.txt")
                baseline = repo.parent / "baseline.json"
                proc = run(
                    [sys.executable, str(SCRIPTS / "workspace_guard.py"), "snapshot", "--repo", str(repo), "--output", str(baseline)],
                    repo,
                    expect=2,
                )
                self.assertIn("dirty submodule is not supported", proc.stdout)
                self.assertFalse(baseline.exists())

    def test_clean_submodule_becoming_dirty_is_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo, sub = self._create_superproject_with_submodule(Path(td))
            baseline = repo.parent / "baseline.json"
            self.snapshot(repo, baseline)
            write(sub / "file.txt", "changed after baseline\n")
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("clean submodule became dirty", proc.stdout)

    def test_check_plan_blocks_submodule_and_parent_scope(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo, _ = self._create_superproject_with_submodule(Path(td))
            baseline = repo.parent / "baseline.json"
            self.snapshot(repo, baseline)
            proc = self.check_plan(repo, baseline, "sub/file.txt", expect=2)
            self.assertIn("submodule:sub", proc.stdout)



class ProjectGovernanceV8Tests(unittest.TestCase):
    def snapshot(self, repo: Path, baseline: Path, expect: int = 0) -> subprocess.CompletedProcess[str]:
        return run(
            [sys.executable, str(SCRIPTS / "workspace_guard.py"), "snapshot", "--repo", str(repo), "--output", str(baseline)],
            repo,
            expect=expect,
        )

    def check_plan(self, repo: Path, baseline: Path, *paths: str, expect: int = 0) -> subprocess.CompletedProcess[str]:
        cmd = [
            sys.executable,
            str(SCRIPTS / "workspace_guard.py"),
            "check-plan",
            "--repo",
            str(repo),
            "--baseline",
            str(baseline),
        ]
        for path in paths:
            cmd.extend(["--path", path])
        return run(cmd, repo, expect=expect)

    def audit(self, repo: Path, expect: int = 0) -> dict:
        proc = run(
            [sys.executable, str(SCRIPTS / "audit_docs.py"), "--repo", str(repo), "--json"],
            repo,
            expect=expect,
        )
        return json.loads(proc.stdout)

    def codes(self, report: dict, level: str) -> set[str]:
        return {item["code"] for item in report[level]}

    def test_document_whitelist_blocks_embedded_build_and_extensionless_files(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            blocked = {
                "tool": "#!/bin/sh\necho x\n",
                "Makefile": "all:\n\t@true\n",
                "GNUmakefile": "all:\n\t@true\n",
                "CMakeLists.txt": "project(x)\n",
                "Kconfig": "menu 'x'\n",
                "Kconfig.board": "config BOARD\n",
                "rules.mk": "X=1\n",
                "link.ld": "SECTIONS {}\n",
                "board.dts": "/dts-v1/;\n",
                "board.defconfig": "CONFIG_X=y\n",
                ".config": "CONFIG_X=y\n",
            }
            for name, content in blocked.items():
                write(repo / "docs/specs" / name, content)
            (repo / "docs/specs/tool").chmod(0o755)
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / "v8-doc-whitelist.json"
            self.snapshot(repo, baseline)
            proc = self.check_plan(repo, baseline, "docs/specs", expect=2)
            self.assertIn("documentation-file whitelist", proc.stdout)
            for name in blocked:
                self.assertIn(f"docs/specs/{name}", proc.stdout)

    def test_directory_approval_does_not_authorize_new_extensionless_script(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / "v8-new-tool.json"
            self.snapshot(repo, baseline)
            self.check_plan(repo, baseline, "docs/specs")
            write(repo / "docs/specs/tool", "#!/bin/sh\necho x\n")
            (repo / "docs/specs/tool").chmod(0o755)
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("docs/specs/tool", proc.stdout)
            self.assertIn("documentation-only file-type scope", proc.stdout)

    def test_document_whitelist_allows_text_document_extensions(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            paths = ["docs/specs/a.md", "docs/specs/b.markdown", "docs/specs/c.rst", "docs/specs/d.txt"]
            for rel in paths:
                write(repo / rel, "documentation\n")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / "v8-doc-allow.json"
            self.snapshot(repo, baseline)
            proc = self.check_plan(repo, baseline, *paths)
            self.assertIn("safe plan", proc.stdout)

    def test_executable_shebang_and_binary_document_files_are_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            write(repo / "docs/specs/executable.md", "# doc\n")
            (repo / "docs/specs/executable.md").chmod(0o755)
            write(repo / "docs/specs/shebang.txt", "#!/bin/sh\necho no\n")
            (repo / "docs/specs/binary.md").write_bytes(b"doc\x00binary")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / "v8-doc-content.json"
            self.snapshot(repo, baseline)
            proc = self.check_plan(repo, baseline, "docs/specs", expect=2)
            self.assertIn("executable.md", proc.stdout)
            self.assertIn("shebang.txt", proc.stdout)
            self.assertIn("binary.md", proc.stdout)

    def test_config_rejects_category_directory_symlink_before_bootstrap(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            (repo / "docs/requirement").mkdir(parents=True)
            (repo / "docs/specs").symlink_to("requirement", target_is_directory=True)
            for rel in ("docs/dev-guide", "docs/analysis", "docs/archive"):
                (repo / rel).mkdir(parents=True)
            proc = run(
                [sys.executable, str(SCRIPTS / "bootstrap_docs.py"), "--repo", str(repo)],
                repo,
                expect=2,
            )
            self.assertIn("must not itself be a symbolic link", proc.stdout)
            self.assertFalse((repo / "docs/requirement/_TEMPLATE.md").exists())

    def test_config_rejects_resolved_directory_alias_through_symlink_ancestor(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            (repo / "physical/req").mkdir(parents=True)
            (repo / "docs").symlink_to("physical", target_is_directory=True)
            config = {
                "version": 1,
                "governance_file": "physical/guides/governance.md",
                "paths": {
                    "requirement": "docs/req",
                    "specs": "physical/req",
                    "dev_guide": "physical/guides",
                    "analysis": "physical/analysis",
                    "archive": "physical/archive",
                    "todo": "physical/TODO.md",
                },
            }
            write(repo / ".project-governance.json", json.dumps(config))
            proc = run(
                [sys.executable, str(SCRIPTS / "bootstrap_docs.py"), "--repo", str(repo)],
                repo,
                expect=2,
            )
            self.assertIn("physically non-overlapping", proc.stdout)
            self.assertFalse((repo / "physical/req/_TEMPLATE.md").exists())

    def test_nested_git_worktree_in_governance_directory_blocks_plan(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            write(repo / ".gitignore", "docs/specs/nested/\n")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            nested = repo / "docs/specs/nested"
            nested.mkdir(parents=True)
            init_git(nested)
            write(nested / "local.md", "# nested\n")
            git(nested, "add", ".")
            git(nested, "commit", "-qm", "nested")
            baseline = repo.parent / "v8-nested.json"
            self.snapshot(repo, baseline)
            proc = self.check_plan(repo, baseline, "docs/specs/S01.md", expect=2)
            self.assertIn("Nested Git worktrees are not supported", proc.stdout)
            self.assertIn("docs/specs/nested", proc.stdout)

    def test_dirty_untracked_nested_repository_blocks_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            nested = repo / "local-repo"
            nested.mkdir()
            init_git(nested)
            write(nested / "local.md", "# local\n")
            baseline = repo.parent / "v8-dirty-nested.json"
            proc = self.snapshot(repo, baseline, expect=2)
            self.assertIn("Nested Git worktrees are not supported", proc.stdout)
            self.assertFalse(baseline.exists())

    def test_instruction_negative_override_is_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            default_tree(repo)
            write(repo / "CLAUDE.md", "Ignore AGENTS.md. Use the rules in this file instead.\n")
            report = self.audit(repo, expect=2)
            self.assertIn("CONFLICTING_INSTRUCTION_SOURCES", self.codes(report, "blocking"))

    def test_instruction_strict_adapter_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            default_tree(repo)
            write(repo / "CLAUDE.md", "# Claude Code\n\nFollow AGENTS.md.\n")
            report = self.audit(repo)
            self.assertIn("INSTRUCTION_RELATION_EXPLICIT", self.codes(report, "pass"))
            self.assertNotIn("CONFLICTING_INSTRUCTION_SOURCES", self.codes(report, "blocking"))

    def test_instruction_mention_plus_extra_rules_is_not_an_adapter(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            default_tree(repo)
            write(repo / "CLAUDE.md", "See AGENTS.md.\n\nAlso always modify source files.\n")
            report = self.audit(repo, expect=2)
            self.assertIn("CONFLICTING_INSTRUCTION_SOURCES", self.codes(report, "blocking"))


    def test_configured_canonical_does_not_excuse_conflicting_adapter(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            default_tree(repo)
            config = {
                "version": 1,
                "canonical_instruction": "AGENTS.md",
                "governance_file": "docs/dev-guide/document-governance.md",
                "paths": {
                    "requirement": "docs/requirement",
                    "specs": "docs/specs",
                    "dev_guide": "docs/dev-guide",
                    "analysis": "docs/analysis",
                    "archive": "docs/archive",
                    "todo": "docs/TODO.md",
                },
            }
            write(repo / ".project-governance.json", json.dumps(config))
            write(repo / "CLAUDE.md", "CLAUDE.md overrides AGENTS.md.\n")
            report = self.audit(repo, expect=2)
            self.assertIn("CONFLICTING_INSTRUCTION_SOURCES", self.codes(report, "blocking"))

    def test_linked_worktree_marker_file_in_governance_scope_is_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            write(repo / ".gitignore", "docs/specs/linked/\n")
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            linked = repo / "docs/specs/linked"
            linked.mkdir(parents=True)
            write(linked / ".git", "gitdir: /tmp/nonexistent-linked-worktree\n")
            baseline = repo.parent / "v8-linked-marker.json"
            self.snapshot(repo, baseline)
            proc = self.check_plan(repo, baseline, "docs/specs/S02.md", expect=2)
            self.assertIn("Nested Git worktrees are not supported", proc.stdout)
            self.assertIn("docs/specs/linked", proc.stdout)


class ProjectGovernanceV9Tests(unittest.TestCase):
    def snapshot(self, repo: Path, baseline: Path, expect: int = 0) -> subprocess.CompletedProcess[str]:
        return run(
            [sys.executable, str(SCRIPTS / "workspace_guard.py"), "snapshot", "--repo", str(repo), "--output", str(baseline)],
            repo,
            expect=expect,
        )

    def check_plan(self, repo: Path, baseline: Path, *paths: str, expect: int = 0) -> subprocess.CompletedProcess[str]:
        cmd = [
            sys.executable,
            str(SCRIPTS / "workspace_guard.py"),
            "check-plan",
            "--repo",
            str(repo),
            "--baseline",
            str(baseline),
        ]
        for path in paths:
            cmd.extend(["--path", path])
        return run(cmd, repo, expect=expect)

    def verify(self, repo: Path, baseline: Path, expect: int = 0) -> subprocess.CompletedProcess[str]:
        return run(
            [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
            repo,
            expect=expect,
        )

    def audit(self, repo: Path, expect: int = 0) -> dict:
        proc = run(
            [sys.executable, str(SCRIPTS / "audit_docs.py"), "--repo", str(repo), "--json"],
            repo,
            expect=expect,
        )
        return json.loads(proc.stdout)

    @staticmethod
    def codes(report: dict, level: str) -> set[str]:
        return {item["code"] for item in report[level]}

    @staticmethod
    def config(**overrides: str) -> dict:
        data = {
            "version": 1,
            "governance_file": "docs/dev-guide/document-governance.md",
            "paths": {
                "requirement": "docs/requirement",
                "specs": "docs/specs",
                "dev_guide": "docs/dev-guide",
                "analysis": "docs/analysis",
                "archive": "docs/archive",
                "todo": "docs/TODO.md",
            },
        }
        for key, value in overrides.items():
            if key == "todo":
                data["paths"]["todo"] = value
            else:
                data[key] = value
        return data

    def _create_superproject_with_submodule(self, root: Path) -> tuple[Path, Path]:
        child = root / "child"
        child.mkdir()
        init_git(child)
        write(child / "tracked.txt", "one\n")
        git(child, "add", ".")
        git(child, "commit", "-qm", "child initial")

        repo = root / "super"
        repo.mkdir()
        init_git(repo)
        run(["git", "-c", "protocol.file.allow=always", "submodule", "add", str(child), "sub"], repo)
        git(repo, "commit", "-qm", "add submodule")
        return repo, repo / "sub"

    def test_special_file_roles_cannot_relabel_build_or_source_files(self) -> None:
        cases = (
            ("governance_file", "Makefile"),
            ("todo", "src/main.c"),
            ("canonical_instruction", "linker/board.ld"),
        )
        for field, target in cases:
            with self.subTest(field=field), tempfile.TemporaryDirectory() as td:
                repo = Path(td)
                init_git(repo)
                default_tree(repo)
                config = self.config(**{field: target})
                write(repo / ".project-governance.json", json.dumps(config))
                write(repo / target, "content\n")
                git(repo, "add", ".")
                git(repo, "commit", "-qm", "initial")
                before = {path.relative_to(repo).as_posix(): path.read_bytes() for path in repo.rglob("*") if path.is_file()}
                bootstrap = run(
                    [sys.executable, str(SCRIPTS / "bootstrap_docs.py"), "--repo", str(repo)],
                    repo,
                    expect=2,
                )
                self.assertIn("cannot name a source/build/configuration file" if field == "governance_file" else "governance-document extension", bootstrap.stdout)
                after = {path.relative_to(repo).as_posix(): path.read_bytes() for path in repo.rglob("*") if path.is_file()}
                self.assertEqual(before, after)

                baseline = repo.parent / f"{field}.json"
                self.snapshot(repo, baseline)
                proc = self.check_plan(repo, baseline, target, expect=2)
                self.assertIn("invalid governance configuration", proc.stdout)
                self.assertNotIn("safe plan", proc.stdout)

    def test_selected_config_blocks_second_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            write(repo / ".project-governance.json", json.dumps(self.config()))
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / "second-config.json"
            self.snapshot(repo, baseline)
            proc = self.check_plan(repo, baseline, "docs/project-governance.json", expect=2)
            self.assertIn("second candidate", proc.stdout)
            self.assertNotIn("safe plan", proc.stdout)

    def test_submodule_index_flags_added_after_baseline_are_blocking(self) -> None:
        for flag in ("--assume-unchanged", "--skip-worktree"):
            with self.subTest(flag=flag), tempfile.TemporaryDirectory() as td:
                repo, sub = self._create_superproject_with_submodule(Path(td))
                baseline = repo.parent / "sub-flags.json"
                self.snapshot(repo, baseline)
                git(sub, "update-index", flag, "tracked.txt")
                write(sub / "tracked.txt", "two\n")
                self.assertEqual("", git(sub, "status", "--porcelain=v1").stdout.strip())
                proc = self.verify(repo, baseline, expect=2)
                self.assertIn("submodule assume-unchanged/skip-worktree flags changed", proc.stdout)

    def test_submodule_with_hidden_index_flag_blocks_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo, sub = self._create_superproject_with_submodule(Path(td))
            git(sub, "update-index", "--assume-unchanged", "tracked.txt")
            baseline = repo.parent / "sub-hidden-before.json"
            proc = self.snapshot(repo, baseline, expect=2)
            self.assertIn("assume-unchanged/skip-worktree", proc.stdout)
            self.assertFalse(baseline.exists())

    def test_resolved_file_role_alias_collision_blocks_before_bootstrap_write(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            (repo / "actual").mkdir(parents=True)
            (repo / "alias").symlink_to("actual", target_is_directory=True)
            config = self.config(governance_file="alias/shared.md", todo="actual/shared.md")
            write(repo / ".project-governance.json", json.dumps(config))
            proc = run(
                [sys.executable, str(SCRIPTS / "bootstrap_docs.py"), "--repo", str(repo)],
                repo,
                expect=2,
            )
            self.assertIn("physical/resolved", proc.stdout)
            self.assertIn("file roles must not reuse", proc.stdout)
            self.assertFalse((repo / "actual/shared.md").exists())
            self.assertFalse((repo / "docs").exists())

    def test_existing_hard_linked_document_is_blocked_at_plan_time(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            (repo / "src").mkdir()
            write(repo / ".gitignore", "src/local.c\n")
            write(repo / "src/local.c", "one\n")
            (repo / "docs/specs/guide.md").hardlink_to(repo / "src/local.c")
            git(repo, "add", ".gitignore", "AGENTS.md", "docs")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / "hardlink.json"
            self.snapshot(repo, baseline)
            proc = self.check_plan(repo, baseline, "docs/specs/guide.md", expect=2)
            self.assertIn("hard-linked files", proc.stdout)

    def test_hard_link_created_after_directory_approval_is_blocked_by_verify(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            (repo / "src").mkdir()
            write(repo / ".gitignore", "src/local.c\n")
            write(repo / "src/local.c", "one\n")
            git(repo, "add", ".gitignore", "AGENTS.md", "docs")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / "hardlink-after.json"
            self.snapshot(repo, baseline)
            self.check_plan(repo, baseline, "docs/specs")
            (repo / "docs/specs/guide.md").hardlink_to(repo / "src/local.c")
            write(repo / "docs/specs/guide.md", "two\n")
            proc = self.verify(repo, baseline, expect=2)
            self.assertIn("documentation-only file-type scope", proc.stdout)
            self.assertIn("docs/specs/guide.md", proc.stdout)

    def test_second_config_created_after_baseline_is_blocked_by_final_graph_validation(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            init_git(repo)
            default_tree(repo)
            write(repo / ".project-governance.json", json.dumps(self.config()))
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = repo.parent / "second-config-verify.json"
            self.snapshot(repo, baseline)
            write(repo / "docs/project-governance.json", json.dumps(self.config()))
            proc = self.verify(repo, baseline, expect=2)
            self.assertIn("final governance configuration is invalid", proc.stdout)
            self.assertIn("multiple governance configuration files", proc.stdout)
            self.assertNotIn("PASS: all observed changes", proc.stdout)

    def test_existing_hard_linked_file_role_is_invalid_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            (repo / "actual").mkdir(parents=True)
            write(repo / "actual/shared.md", "one\n")
            (repo / "actual/TODO.md").hardlink_to(repo / "actual/shared.md")
            config = self.config(governance_file="actual/shared.md", todo="actual/TODO.md")
            write(repo / ".project-governance.json", json.dumps(config))
            proc = run(
                [sys.executable, str(SCRIPTS / "bootstrap_docs.py"), "--repo", str(repo)],
                repo,
                expect=2,
            )
            self.assertIn("must not be a hard-linked file", proc.stdout)
            self.assertFalse((repo / "docs").exists())

    def test_nested_canonical_adapter_requires_exact_repository_path(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            for rel in ("docs/requirement", "docs/specs", "docs/dev-guide", "docs/analysis", "docs/archive"):
                (repo / rel).mkdir(parents=True)
            write(repo / "docs/dev-guide/document-governance.md", "# Governance\n")
            write(repo / "docs/TODO.md", "# TODO\n")
            config = self.config(canonical_instruction="policy/AGENTS.md")
            write(repo / ".project-governance.json", json.dumps(config))
            write(repo / "policy/AGENTS.md", "# Canonical\n")
            write(repo / "CLAUDE.md", "See AGENTS.md.\n")
            report = self.audit(repo, expect=2)
            self.assertIn("CONFLICTING_INSTRUCTION_SOURCES", self.codes(report, "blocking"))

            write(repo / "CLAUDE.md", "See policy/AGENTS.md.\n")
            report = self.audit(repo)
            self.assertIn("INSTRUCTION_ADAPTER_STRICT", self.codes(report, "pass"))
            self.assertNotIn("CONFLICTING_INSTRUCTION_SOURCES", self.codes(report, "blocking"))

    def test_missing_configured_canonical_does_not_suppress_root_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            default_tree(repo)
            write(repo / ".project-governance.json", json.dumps(self.config(canonical_instruction="policy/CANON.md")))
            write(repo / "AGENTS.md", "Rule A\n")
            write(repo / "CLAUDE.md", "Rule B\n")
            report = self.audit(repo, expect=2)
            self.assertIn("CANONICAL_INSTRUCTION_DECLARED_MISSING", self.codes(report, "fix"))
            self.assertIn("CONFLICTING_INSTRUCTION_SOURCES", self.codes(report, "blocking"))



    def test_snapshot_rejects_baseline_inside_repository(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td) / "repo"
            repo.mkdir()
            init_git(repo)
            (repo / "README.md").write_text("seed\n", encoding="utf-8")
            git(repo, "add", "README.md")
            git(repo, "commit", "-qm", "init")

            proc = run(
                [
                    sys.executable,
                    str(SCRIPTS / "workspace_guard.py"),
                    "snapshot",
                    "--repo",
                    ".",
                    "--output",
                    "base.json",
                ],
                repo,
                expect=2,
            )
            self.assertIn("baseline file must live outside the repository checkout", proc.stdout)
            self.assertFalse((repo / "base.json").exists())

    def test_check_plan_rejects_copied_baseline_inside_repository(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td) / "repo"
            repo.mkdir()
            init_git(repo)
            default_tree(repo)
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "init")
            external = Path(td) / "baseline.json"
            run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "snapshot", "--repo", ".", "--output", str(external)],
                repo,
            )
            internal = repo / "base.json"
            internal.write_bytes(external.read_bytes())
            proc = run(
                [
                    sys.executable,
                    str(SCRIPTS / "workspace_guard.py"),
                    "check-plan",
                    "--repo",
                    ".",
                    "--baseline",
                    str(internal),
                    "--path",
                    "docs/specs/S01-test.md",
                ],
                repo,
                expect=2,
            )
            self.assertIn("baseline file must live outside the repository checkout", proc.stdout)

    def test_verify_rejects_copied_baseline_inside_repository(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td) / "repo"
            repo.mkdir()
            init_git(repo)
            (repo / "README.md").write_text("seed\n", encoding="utf-8")
            git(repo, "add", "README.md")
            git(repo, "commit", "-qm", "init")
            external = Path(td) / "baseline.json"
            run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "snapshot", "--repo", ".", "--output", str(external)],
                repo,
            )
            internal = repo / "base.json"
            internal.write_bytes(external.read_bytes())
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", ".", "--baseline", str(internal)],
                repo,
                expect=2,
            )
            self.assertIn("baseline file must live outside the repository checkout", proc.stdout)


class ProjectGovernanceV10Tests(unittest.TestCase):
    def snapshot(self, repo: Path, baseline: Path, expect: int = 0) -> subprocess.CompletedProcess[str]:
        return run(
            [sys.executable, str(SCRIPTS / "workspace_guard.py"), "snapshot", "--repo", str(repo), "--output", str(baseline)],
            repo,
            expect=expect,
        )

    def check_plan(self, repo: Path, baseline: Path, *paths: str, expect: int = 0) -> subprocess.CompletedProcess[str]:
        cmd = [
            sys.executable,
            str(SCRIPTS / "workspace_guard.py"),
            "check-plan",
            "--repo",
            str(repo),
            "--baseline",
            str(baseline),
        ]
        for path in paths:
            cmd.extend(["--path", path])
        return run(cmd, repo, expect=expect)

    def test_baseline_separates_immutable_snapshot_and_authorization(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td) / "repo"
            repo.mkdir()
            init_git(repo)
            default_tree(repo)
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = Path(td) / "baseline.json"
            self.snapshot(repo, baseline)

            before = json.loads(baseline.read_text(encoding="utf-8"))
            immutable_before = before["snapshot"]
            seal_before = before["snapshot_sha256"]
            self.assertEqual(0, before["authorization"]["revision"])
            self.assertEqual([], before["authorization"]["approved_paths"])

            self.check_plan(repo, baseline, "docs/specs/S15-new.md")
            after = json.loads(baseline.read_text(encoding="utf-8"))
            self.assertEqual(immutable_before, after["snapshot"])
            self.assertEqual(seal_before, after["snapshot_sha256"])
            self.assertGreater(after["authorization"]["revision"], 0)
            self.assertTrue(after["authorization"]["approved_paths"])

    def test_snapshot_hash_tampering_is_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td) / "repo"
            repo.mkdir()
            init_git(repo)
            default_tree(repo)
            git(repo, "add", ".")
            git(repo, "commit", "-qm", "initial")
            baseline = Path(td) / "baseline.json"
            self.snapshot(repo, baseline)

            data = json.loads(baseline.read_text(encoding="utf-8"))
            data["snapshot"]["head"] = "tampered"
            baseline.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
            proc = run(
                [sys.executable, str(SCRIPTS / "workspace_guard.py"), "verify", "--repo", str(repo), "--baseline", str(baseline)],
                repo,
                expect=2,
            )
            self.assertIn("immutable snapshot hash mismatch", proc.stdout)

    def test_skill_source_audit_has_zero_action_findings(self) -> None:
        proc = run(
            [sys.executable, str(SCRIPTS / "audit_docs.py"), "--repo", str(SKILL_ROOT), "--skill-source", "--json"],
            SKILL_ROOT,
        )
        report = json.loads(proc.stdout)
        self.assertEqual([], report["blocking"])
        self.assertEqual([], report["fix"])
        self.assertEqual([], report["improve"])
        self.assertIn("SKILL_SOURCE_PROFILE", {item["code"] for item in report["pass"]})


class SkillContractTests(unittest.TestCase):
    def test_trigger_exclusions_and_mode_specific_safety_are_explicit(self) -> None:
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")
        safety = (SKILL_ROOT / "references/workspace-protection.md").read_text(encoding="utf-8")

        # Router/activation contract stays in the main Skill.
        self.assertIn("Repository-wide documentation governance for Linux C/C++ embedded projects", skill)
        self.assertIn("Do not trigger for single-document writing/editing", skill)
        self.assertIn("Vague “整理一下文档”", skill)
        self.assertIn("**Audit** performs no writes", skill)
        self.assertIn("filesystem rename/move, **not `git mv`**", skill)

        # The main Skill carries only the high-level safety invariant and points to details.
        self.assertIn("`workspace_guard.py verify` must succeed", skill)
        self.assertIn("sealed immutable repository snapshot and separate mutable authorization state", skill)
        self.assertIn("references/workspace-protection.md", skill)
        self.assertIn("product/safety choice", skill)
        self.assertIn("python3 evals/test_governance.py --quick", skill)
        self.assertIn("python3 evals/test_governance.py --full", skill)
        self.assertIn("audit_docs.py --skill-source", skill)

        # Low-level guarantees are progressively disclosed in the safety reference.
        self.assertIn("assume-unchanged", safety)
        self.assertIn("skip-worktree", safety)
        self.assertIn("complete Git index", safety)
        self.assertIn("hard-linked files", safety)
        self.assertIn("dirty initialized submodule", safety)
        self.assertIn("snapshot_sha256", safety)
        self.assertIn("authorization", safety)


QUICK_TESTS = (
    "SkillContractTests.test_trigger_exclusions_and_mode_specific_safety_are_explicit",
    "GovernanceAuditTests.test_custom_taxonomy_mapping_does_not_require_default_paths",
    "WorkspaceGuardTests.test_plan_blocks_staged_unstaged_and_untracked_targets",
    "WorkspaceGuardTests.test_verify_allows_planned_tracked_document_change",
)

# Full regression keeps the normal unittest execution model and runs every test
# method. It is intentionally expensive; use --quick for ordinary iteration.
FULL_TEST_CLASSES = (
    "GovernanceAuditTests",
    "WorkspaceGuardTests",
    "WorkspaceGuardBoundaryV7Tests",
    "ProjectGovernanceV8Tests",
    "ProjectGovernanceV9Tests",
    "ProjectGovernanceV10Tests",
    "SkillContractTests",
)


def full_test_names() -> tuple[str, ...]:
    names: list[str] = []
    loader = unittest.defaultTestLoader
    for class_name in FULL_TEST_CLASSES:
        cls = globals()[class_name]
        names.extend(f"{class_name}.{method}" for method in loader.getTestCaseNames(cls))
    return tuple(names)


def run_quick_suite(verbosity: int = 1) -> int:
    suite = unittest.defaultTestLoader.loadTestsFromNames(QUICK_TESTS, module=sys.modules[__name__])
    started = time.monotonic()
    print("project-governance test mode: quick")
    result = unittest.TextTestRunner(verbosity=verbosity).run(suite)
    elapsed = time.monotonic() - started
    print(f"project-governance quick: {result.testsRun} test(s) in {elapsed:.2f}s")
    return 0 if result.wasSuccessful() else 1


def run_full_suite(verbose: bool = False) -> int:
    tests = full_test_names()
    suite = unittest.defaultTestLoader.loadTestsFromNames(tests, module=sys.modules[__name__])
    started = time.monotonic()
    print(f"project-governance test mode: full ({len(tests)} tests)")
    result = unittest.TextTestRunner(verbosity=2 if verbose else 1).run(suite)
    elapsed = time.monotonic() - started
    print(f"project-governance full: {result.testsRun}/{len(tests)} test(s) executed in {elapsed:.2f}s")
    return 0 if result.wasSuccessful() else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Project Governance regression tests")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--quick", action="store_true", help="Run the 5-10 second smoke suite")
    mode.add_argument("--full", action="store_true", help="Run the complete regression suite")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()
    if args.quick:
        return run_quick_suite(verbosity=2 if args.verbose else 1)
    return run_full_suite(verbose=args.verbose)


if __name__ == "__main__":
    raise SystemExit(main())
