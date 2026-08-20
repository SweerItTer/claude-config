# Project Governance v10.0.0 — Change Log

## Scope

v10 is a maintenance/architecture release. It does not widen write authority. The write-capable profile remains Linux-hosted C/C++ embedded repositories with documentation-only writes.

## 1. Quick vs full regression modes

`evals/test_governance.py` now exposes two explicit modes:

```bash
python3 evals/test_governance.py --quick
python3 evals/test_governance.py --full
```

- `--quick`: four smoke tests covering routing/contract, custom governance config, dirty-work overlap, and a basic planned-write verification path. Target: roughly 5–10 seconds on the validation host.
- `--full`: all 76 current regression test methods, including submodule, symlink, hard-link, ignored-path, nested-worktree, Git-index, configuration, and Markdown-boundary cases.

No flag continues to select the full suite for compatibility.

## 2. SKILL.md reduced through progressive disclosure

The main Skill was reduced from 385 lines to 276 lines (about 28%). Low-level worktree/index/submodule and physical-path guarantees now live in `references/workspace-protection.md`.

The main Skill keeps only the activation router, operating authority, high-level guard workflow, governance workflow, success criteria, and links to detailed references.

## 3. Router-style description

The frontmatter description is now a concise routing rule: repository-wide governance/handover work triggers the Skill; single-document writing/editing, translation, summary, proofreading, formatting, README polishing, and ordinary TODO editing do not.

Safety implementation details were removed from the description and remain in the body/references.

## 4. Workspace guard schema 10: immutable snapshot + mutable authorization

The previous baseline object mixed capture-time repository state with later approved write scopes. Schema 10 separates them explicitly:

```json
{
  "version": 10,
  "snapshot": { "...": "immutable capture-time state" },
  "snapshot_sha256": "...",
  "authorization": { "...": "mutable approved-plan state" }
}
```

- `snapshot` contains capture-time worktree/index/HEAD/submodule state and is sealed with `snapshot_sha256`.
- `authorization` contains approved lexical/resolved paths, lazily enrolled ignored-path fingerprints, bound governance config, and an authorization revision.
- `check-plan` may update authorization only.
- loading or saving guard state fails if the sealed snapshot hash no longer matches.
- governance-config changes after authorization begins still require review and a fresh baseline file.

This is a baseline-schema break; v9 baseline files must be recreated with v10.

## 5. Skill-source self-audit profile

`audit_docs.py` now supports:

```bash
python3 scripts/audit_docs.py --repo . --skill-source
```

This profile audits the Skill package as a Skill source rather than as an application repository. It checks Skill structure/runtime documentation without requiring application `docs/requirement`, TODO, or governance bootstrap files.

Current v10 self-audit result: Blocking 0, Fix 0, Improve 0, Pass 7.

## 6. Embedded scope clarified as a product profile

The Linux C/C++ embedded restriction is now explicitly described as a conservative product/safety choice, not an inherent limitation of Requirement/Spec taxonomy, lifecycle, TODO, or archive governance.

A future generic-core / validated-profile split remains a possible direction, but v10 deliberately does not widen write authority to Rust, Go, Python, or other repository types without a separately tested safety profile.
