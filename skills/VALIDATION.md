# Project Governance v10.0.0 — Validation

## Environment

- Linux container
- Python 3.13
- Git
- Skill Creator validation/package scripts supplied by the user

## Structural and static validation

```text
Skill Creator quick_validate.py: PASS
Python compileall (scripts + evals): PASS
JSON parse (evals/evals.json): PASS
Metadata version: 10.0.0
Workspace guard schema: 10
SKILL.md: 276 lines (v9.0.1: 385; reduction ≈ 28.3%)
Eval scenarios: 39
Regression test methods: 76
```

## Smoke mode

Command:

```bash
python3 evals/test_governance.py --quick
```

Result on the validation host:

```text
Ran 4 tests in 7.077s
OK
project-governance quick: 4 test(s) in 7.08s
```

The smoke set covers:

1. trigger/router and high-level safety contract;
2. custom governance mapping/config recognition;
3. staged/unstaged/untracked overlap blocking;
4. a basic planned tracked-document change followed by workspace verification.

This is the normal pre/post-edit confidence check for Skill maintenance.

## Full regression

Entry point:

```bash
python3 evals/test_governance.py --full
```

It enumerates all 76 test methods. The current execution harness heavily throttles long Git-heavy single commands, so release validation was executed as equivalent isolated shards/classes rather than waiting for one monolithic command. Every method in the `--full` set was executed and passed:

| Group | Passed |
|---|---:|
| `GovernanceAuditTests` | 14/14 |
| `WorkspaceGuardTests` | 19/19 |
| `WorkspaceGuardBoundaryV7Tests` | 12/12 |
| `ProjectGovernanceV8Tests` | 13/13 |
| `ProjectGovernanceV9Tests` | 14/14 |
| `ProjectGovernanceV10Tests` | 3/3 |
| `SkillContractTests` | 1/1 |
| **Total** | **76/76** |

The full suite retains the previous submodule, symlink, hard-link, ignored-path, nested-worktree, Git-index/flags, configuration, instruction-authority, and Markdown-link boundary coverage and adds v10 schema/self-audit tests.

## v10-specific acceptance coverage

### Immutable snapshot / mutable authorization

- a fresh state file starts with `authorization.revision == 0` and an empty approved path set;
- `check-plan` changes authorization while leaving the entire `snapshot` object and `snapshot_sha256` unchanged;
- modifying the immutable snapshot without updating its seal causes `verify` to fail with `immutable snapshot hash mismatch`;
- `save_snapshot` also refuses to persist guard state if the sealed snapshot no longer matches.

### Skill-source audit

Command:

```bash
python3 scripts/audit_docs.py --repo . --skill-source --json
```

Result:

```text
Blocking: 0
Fix:      0
Improve:  0
Pass:     7
```

This removes the previous expected noise caused by treating the Skill package as an application repository.

### Progressive disclosure / routing

Contract tests verify that:

- single-document work remains excluded from routing;
- main `SKILL.md` retains `workspace_guard.py verify` as the high-level safety invariant;
- low-level Git-index, hard-link, submodule, and hidden-index details remain in `references/workspace-protection.md`;
- the embedded restriction is described as a product/safety profile;
- quick/full and `--skill-source` maintenance entry points are documented.

## Self-audit

`self-audit.json` was generated with the v10 Skill-source profile and contains no Blocking, Fix, or Improve findings.

## Not run

A with-Skill versus without-Skill external Claude/subagent benchmark was not run because this environment does not expose the Skill Creator's external subagent runner. Deterministic scripts and authorization behavior are covered by the local regression suite.
