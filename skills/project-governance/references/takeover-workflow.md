# Proactive takeover workflow

## 1. Resolve intent before writing

Use this decision table:

| Signal | Mode | Action |
|---|---|---|
| Explicit `/project-governance` | Takeover | Proactively organize safe documentation-only scope |
| Clear repository handover and whole-system documentation cleanup | Takeover | Proactively organize safe documentation-only scope |
| No coherent governance system | Bootstrap | Seed rules, then continue Takeover |
| Audit/inspect only or “do not modify” | Audit | Read-only; no baseline |
| Exact governed file, ID, lifecycle, or archive action | Targeted maintenance | Stay within the exact named scope |
| Vague “整理一下文档” | Triage | Ask whether repository-wide or single-file, and whether inspect-only or modify |

Generic writing, translation, summary, proofreading, README polishing, and formatting do not use this Skill.

## 2. Authorization boundary

Takeover authorizes:

- read-only repository inspection;
- creating missing documentation directories, mapping, and templates without overwriting;
- editing documentation-governance text;
- adding metadata supported by evidence;
- moving and renaming clearly classified clean documents with a filesystem move that leaves the index unstaged;
- repairing references caused by those moves;
- archiving completed or superseded documents without deletion;
- cleaning completed TODO items while preserving history.

It does not authorize:

- source code, build files, linker scripts, Device Tree, board configuration, tool scripts, generated files, executable/shebang files, binaries, or unknown-extension files;
- touching a path that was staged, unstaged, ordinary untracked, or hidden by `assume-unchanged` / `skip-worktree` before the run;
- touching an ignored path that intersects a checked source/destination, ancestor, or descendant, including a missing destination already matched by `.gitignore`;
- entering or modifying any submodule; a dirty submodule blocks Takeover, and any plan equal to, inside, or above a submodule is Blocking;
- entering a non-submodule nested repository or linked worktree; these topologies are unsupported and must fail safely;
- deleting uncertain content;
- inventing requirements or technical decisions;
- renumbering established IDs without a proven collision;
- writing through a symlink to an external path;
- staging, committing, switching branches, pushing, stashing, resetting, restoring, or cleaning.

## 3. Choose the repository safety profile

### Git-backed write mode

1. Find the Git repository root.
2. Create the workspace baseline before the first write, and keep the baseline file outside the repository checkout. The state file contains a SHA-256-sealed immutable `snapshot` plus mutable `authorization`; `check-plan` may update only authorization. A governance-config change after authorization starts requires a fresh state file.
3. Check every batch plan against lexical/resolved protected paths, index-hidden files, clean submodule boundaries including complete nested index/flags, and nested Git markers; lazily enroll relevant ignored paths; recursively validate existing directory contents against the explicit document whitelist; persist a typed file/directory allowlist.
4. Verify every observed file again after each batch, including ignored outputs, hard-link state, final governance-config validity, and clean-submodule nested index/flag state. If the governance configuration changes after it has been bound to the baseline, stop write-capable work and create a fresh baseline before any further batch.
5. Treat index entry or extension-flag changes, newly staged paths, HEAD changes, or branch changes as Blocking.

### Audit mode

Do not create a baseline. Run inventory and audit only. Never reference `$BASELINE`.

### Non-Git repository

Do not run the Git workspace guard. Automatic work is limited to read-only audit and creation-only, non-overwriting bootstrap. Existing files cannot be moved or rewritten without explicit acceptance of weaker rollback guarantees.

## 4. Inspect repository reality

1. Read canonical instructions and contributor guidance.
2. Detect `.project-governance.json` or `docs/project-governance.json`.
3. Validate lexical containment, resolved symlink destinations, path roles, existing target types, lexical and physical directory overlap, and category-directory symlink use.
4. Inventory documentation outside configured paths too.
5. Detect taxonomy, identity-bearing documents, templates, TODO, archive, and naming patterns.
6. Run the bundled inspection and audit scripts.

If path containment fails, stop all writes. Do not silently fall back to defaults.

## 5. Decide by evidence, not preference

Preserve coherent conventions. Apply defaults only where the repository has no durable equivalent.

Infer routine parameters when evidence is clear:

- document language;
- filename separator and language;
- canonical instruction source;
- documentation build commands;
- existing ID width;
- custom category paths.

Declare coherent custom paths in one mapping. Do not create a mapping merely to bless an accidental directory dump.

## 6. Continue around ambiguity and overlap

Classify each document:

- **High**: responsibility is explicit; organize now if safe.
- **Medium**: likely classification but meaning may shift; leave in place and propose a target.
- **Low**: mixed, contradictory, or historical role unclear; leave untouched and ask one focused question.
- **Protected**: overlaps baseline work or an index-hidden path; preserve worktree, complete index state/flags, and original classification. Dirty submodules block the run rather than being recursively protected, even when they are outside the planned documentation scope.
- **Approved file**: passed `check-plan`; only that exact lexical or resolved file may change.
- **Approved directory**: descendants may change only when every actual file is `.md`, `.markdown`, `.rst`, `.txt`, or an exact configured governance file, and is non-executable, non-shebang, non-binary, non-symlink, and non-ignored.
- **Unplanned**: any baseline-clean changed path outside the approved set; Blocking even when it is a Markdown file.

A medium, low, or protected file must not block unrelated high-confidence work.

## 7. Seed rules before migration

Create or repair:

1. one repository governance mapping when custom paths are used;
2. the configured governance guide;
3. Requirement and Spec templates;
4. configured category directories;
5. a concise governance index in the canonical instruction file, only when that file is safe to edit.

## 8. Migrate in small batches

Preferred order:

1. mapping, templates, and governance rules;
2. clearly misplaced guides and investigations;
3. Requirements;
4. Specs and decision records;
5. TODO and archive cleanup;
6. reference repair;
7. final audit.

For Git-backed work, check every source and destination path before a batch. After each batch run workspace verification, governance audit, and `git diff --name-status`.

## 9. Stop conditions

Stop modifying the affected path when:

- the next step would alter technical meaning;
- two rule sources conflict and neither is authoritative;
- the path overlaps baseline work;
- stable identity cannot be derived safely;
- a configured path resolves outside the repository;
- the repository is not writable;
- workspace verification fails;
- index entries/flags, ignored-output observation, clean-submodule boundary, nested-worktree rejection, document-whitelist enforcement, HEAD, or branch protection fails.

Continue read-only analysis and unrelated safe work. Stop the whole run only when repository-wide safety cannot be established.

## 10. Idempotence

A second run should produce little or no churn. Repair real drift without cosmetic date refreshes, frontmatter reordering, unnecessary remapping, identity overcounting, or removal of legal semantic-ID navigation links.

## 11. Instruction authority proof

Do not infer authority because one file merely mentions another filename. A safe relationship requires a filesystem symlink, or a structured `canonical_instruction` declaration plus a single-purpose adapter/link that resolves to the exact configured repository-relative target. Missing configured targets do not suppress conflict checks among files that exist. Explicit `ignore`, `override`, or `do not follow` language is Blocking.
