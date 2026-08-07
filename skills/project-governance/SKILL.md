---
name: project-governance
description: >-
  Repository-wide documentation governance for Linux C/C++ embedded projects: takeover, bootstrap, audit, Requirement/Spec IDs, lifecycle, taxonomy, TODO/archive hygiene, and migration. Trigger for explicit /project-governance requests or clear repository-wide documentation governance/handover work. Do not trigger for single-document writing/editing, translation, summary, proofreading, formatting, README polishing, or ordinary TODO edits.
compatibility: Linux and Python 3.9 or newer are required for bundled safety scripts. Git is required for write-capable takeover of existing files. Non-Git automation is limited to audit and non-overwriting creation-only bootstrap unless the user explicitly accepts weaker rollback guarantees.
metadata:
  version: "10.0.0"
---

# Project Governance

Turn an inherited or drifting repository into documentation that the next person or Agent can understand and maintain.

## Modes

Resolve mode before writing:

| Intent | Mode | Authority |
|---|---|---|
| Explicit `/project-governance` | Takeover | Safe repository documentation edits |
| Clear repository handover / whole-doc-system cleanup | Takeover | Safe repository documentation edits |
| No coherent governance system | Bootstrap within Takeover | Create rules, then organize |
| “Audit only”, “inspect”, “do not modify” | Audit | None |
| Exact ID, lifecycle, archive, or governed-file action | Targeted maintenance | Exact named scope only |
| Vague “整理一下文档” | Triage | None until scope/write intent is clear |

Do not expand Targeted maintenance into repository-wide cleanup. For Triage, ask one concise question that resolves repository-wide vs single-document scope and inspect-only vs modify.

Read `references/takeover-workflow.md` before Takeover or Bootstrap.

## Operating contract

An explicit Takeover asks the Agent to inspect, establish safety, then complete all unambiguous documentation-only organization rather than stopping at recommendations.

Authorized work:

- inventory, classification, migration, and reference repair;
- governance mapping and repository-carried documentation rules;
- Requirement/Spec templates, stable IDs, lifecycle, TODO, and archive hygiene;
- concise updates to the configured canonical repository instruction document.

Not authorized:

- source, build, board, linker, Device Tree, tool, generated, executable, submodule, or nested-worktree content;
- deletion or semantic rewriting of uncertain material;
- inventing product or architecture decisions;
- staging, committing, switching branches, pushing, stashing, resetting, restoring, or cleaning;
- writes outside the repository through symlinks or physical aliases.

Continue safe non-overlapping work when one item is ambiguous. Leave that item unchanged and report the narrow unresolved decision.

## Product profile

The write-capable profile is **deliberately** limited to Linux-hosted C/C++ embedded repositories. This is a conservative product/safety choice, not a claim that Requirement/Spec taxonomy, lifecycle, or TODO/archive governance is inherently C/C++-specific. Do not silently generalize write authority to Rust, Go, Python, or other repository profiles; a future core/profile split may reuse the generic governance model with separately validated safety rules.

## Git-backed write safety

Before the first write, create guard state outside the repository:

```bash
BASELINE="$(mktemp -t project-governance-baseline.XXXXXX.json)"
python3 "$SKILL_DIR/scripts/workspace_guard.py" snapshot --repo . --output "$BASELINE"
```

Before every write batch, list every source and destination path and approve the plan:

```bash
python3 "$SKILL_DIR/scripts/workspace_guard.py" check-plan \
  --repo . --baseline "$BASELINE" --paths-from /tmp/project-governance-paths.txt
```

After every batch and at the end:

```bash
python3 "$SKILL_DIR/scripts/workspace_guard.py" verify --repo . --baseline "$BASELINE"
```

`workspace_guard.py verify` must succeed. Never stage governance changes automatically.

The guard state contains a sealed immutable repository snapshot and separate mutable authorization state. `check-plan` may update authorization only; modification of the sealed snapshot is Blocking. Governance-config changes after authorization has begun require review and a fresh baseline.

A dirty initialized submodule blocks write-capable Takeover even when outside the planned documentation scope. Audit remains available.

Read `references/workspace-protection.md` for protected worktree/index state, ignored paths, document whitelist, symlink/hardlink rules, submodules, nested worktrees, configuration immutability, and failure handling.

## Audit and non-Git modes

**Audit** performs no writes, creates no baseline, and never references `$BASELINE`:

```bash
python3 "$SKILL_DIR/scripts/inspect_docs.py" --repo .
python3 "$SKILL_DIR/scripts/audit_docs.py" --repo .
```

**Non-Git** repositories do not run `workspace_guard.py`. Automatic work is limited to read-only audit and creation-only non-overwriting bootstrap. Moving or rewriting existing files requires explicit acceptance of weaker rollback/attribution guarantees.

## Takeover workflow

### 1. Inspect the repository

Read, when present:

- repository instruction files such as `AGENTS.md` / `CLAUDE.md`;
- `README.md`, `CONTRIBUTING.md`;
- `.project-governance.json` or `docs/project-governance.json`;
- the complete documentation tree, including docs outside `docs/`;
- templates, TODO files, and relevant documentation Git history.

Run:

```bash
python3 "$SKILL_DIR/scripts/inspect_docs.py" --repo .
python3 "$SKILL_DIR/scripts/audit_docs.py" --repo .
```

In Audit mode, report now and stop.

Do not overwrite a coherent project-specific system merely because it differs from the defaults.

### 2. Recognize or declare governance mapping

Read `references/governance-config.md` and `references/taxonomy-and-lifecycle.md`.

Default responsibilities only when no coherent equivalent exists:

| Responsibility | Default path | Identity |
|---|---|---|
| Required behavior / acceptance constraints | `docs/requirement/` | `Rxx` |
| Design / architecture / implementation decisions | `docs/specs/` | `Sxx` |
| Repeatable procedures | `docs/dev-guide/` | none |
| One-time investigation / evidence | `docs/analysis/` | none |
| Completed / superseded history | `docs/archive/` | preserve prior R/S ID |

If the repository uses different paths, declare them instead of forcing a migration merely for naming consistency.

When bootstrapping:

```bash
python3 "$SKILL_DIR/scripts/bootstrap_docs.py" --repo .
```

Bootstrap must validate the whole configured path graph before the first write and must not overwrite existing files.

### 3. Build a migration map

Before moves or rewrites, build:

| Current path | Responsibility | Stable ID | Target | Action | Evidence | Confidence |
|---|---|---|---|---|---|---|

For Git-backed work, put every source and destination in `check-plan` before the batch.

Only Requirements, Specs, and archived Requirement/Spec documents own R/S identity. A guide named `S14-implementation-guide.md` may refer to S14 but is not another S14.

Find the next ID with:

```bash
python3 "$SKILL_DIR/scripts/next_doc_id.py" --repo . --prefix S
python3 "$SKILL_DIR/scripts/next_doc_id.py" --repo . --prefix R
```

Use evidence in order: existing ID → explicit `created` → first Git commit → documented project order → unresolved. Never invent chronology.

### 4. Organize in reviewable batches

Read `references/migration-playbook.md` before moves.

Safe operations include:

- create missing configured directories/templates;
- move clearly classifiable clean tracked documents with a filesystem rename/move, **not `git mv`**;
- preserve established R/S IDs;
- add metadata only from available evidence;
- replace `v2` / `final` / `latest` filenames with lifecycle and supersession metadata;
- archive completed/superseded material without deleting history;
- keep TODO current and move completed history to archive;
- repair references affected by moves.

Do not touch protected paths, renumber established IDs, merge uncertain content, choose between conflicting decisions, or modernize archive prose without need.

### 5. Apply identity and lifecycle

Requirements use `Rxx`; Specs use `Sxx`; consequential Spec decisions use `Dn` and are referenced as `Sxx-Dn`.

Use visible semantic identity in prose; a relative link may remain navigation:

```markdown
参见 S14《Lines model》：[文档](docs/specs/S14-lines-model.md)
```

Do not use a path as the only identity, and do not create `S08_v2_final.md`. See `references/taxonomy-and-lifecycle.md` for lifecycle, supersession, decision records, TODO, and archive rules.

### 6. Verify

For Git-backed writes:

```bash
python3 "$SKILL_DIR/scripts/workspace_guard.py" verify --repo . --baseline "$BASELINE"
python3 "$SKILL_DIR/scripts/audit_docs.py" --repo .
git diff --check
git diff --name-status
git status --short
```

Also run the repository's documentation build/link checker when one exists.

Do not claim success while mode-appropriate verification fails or Blocking findings remain.

## Report format

For Takeover / Bootstrap:

```markdown
## Project governance takeover
### Mode and safety profile
### Governance mapping
### Created
### Moved or renamed
### Normalized
### Archived
### Skipped: protected work
### Left unchanged intentionally
### Unresolved decisions
### Verification
```

Audit omits write/baseline sections. For every changed file, state the reason and new responsibility. Report actual commands/results, skipped paths, mapping source, and unresolved Blocking findings.

## Success criteria

A write-mode takeover is complete when:

- `workspace_guard.py verify` succeeds and the final audit has no unresolved Blocking finding;
- all writes remain in the approved documentation-only scope;
- pre-existing work, Git history/index state, submodule boundaries, and unsupported nested worktrees were handled according to `workspace-protection.md`;
- the actual taxonomy is coherent or explicitly mapped;
- R/S identity ownership is unique and stable;
- lifecycle, references, TODO, archive, and repository-carried rules are understandable by the next person or Agent.

An Audit is complete when it performs no writes and reports evidence-backed Blocking, Fix, Improve, and Pass results.

## Common pitfalls

- Treating single-document editing or vague “整理文档” as repository Takeover authority.
- Using Git-only safety steps in Audit or non-Git flows.
- Forcing default paths over a coherent custom taxonomy.
- Moving files before the migration map and `check-plan` exist.
- Using `git mv`, staging, or committing governance changes automatically.
- Treating guides/analyses as R/S identity owners because their filenames mention an ID.
- Treating navigation paths as identity instead of stable R/S references.
- Putting session-resume notes, guesses, or temporary Agent state into durable project truth.

## Maintaining this Skill

In the source package, use the smoke suite during normal iteration and the full suite before release:

```bash
python3 evals/test_governance.py --quick
python3 evals/test_governance.py --full
```

Use `audit_docs.py --skill-source` when auditing this Skill source tree so application-repository taxonomy/TODO requirements are not misapplied to test fixtures or package sources.

## Bundled resources

- `references/takeover-workflow.md` — mode selection and takeover stop conditions.
- `references/workspace-protection.md` — Git/worktree/index/path/submodule safety contract.
- `references/governance-config.md` — custom mapping and containment rules.
- `references/taxonomy-and-lifecycle.md` — classification, IDs, lifecycle, decisions, TODO, archive.
- `references/migration-playbook.md` — reviewable migration procedure.
- `references/audit-checklist.md` — deterministic audit severities.
- `scripts/workspace_guard.py` — snapshot, plan authorization, and verification.
- `scripts/inspect_docs.py` — configuration-aware inventory.
- `scripts/bootstrap_docs.py` — non-overwriting bootstrap.
- `scripts/next_doc_id.py` — next R/S identity.
- `scripts/audit_docs.py` — governance audit and Skill-source self-audit profile.
