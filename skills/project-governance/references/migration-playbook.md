# History-preserving documentation migration

## 1. Protect the baseline

Before any write:

```bash
BASELINE="$(mktemp -t project-governance-baseline.XXXXXX.json)"
python3 "$SKILL_DIR/scripts/workspace_guard.py" snapshot --repo . --output "$BASELINE"
git branch --show-current
git log --oneline --all -- docs | head -30
```

All recorded paths are read-only. A dirty initialized submodule, a nested Git repository, or a linked worktree blocks write-capable Takeover; use audit-only mode or resolve it manually first. Clean submodules are no-touch boundaries whose complete nested index and flags must remain unchanged; hidden-flag submodules block snapshot. Do not use reset, restore, checkout, clean, or stash to make the tree appear clean.

## 2. Write or identify the rule before applying it

Identify the repository mapping and governance guide first. If a coherent custom taxonomy exists, preserve it and declare its paths rather than converting it to the defaults.

## 3. Build the mapping table

Use:

| Old path | Responsibility | Existing or new ID | New path | Action | Evidence | Confidence |
|---|---|---|---|---|---|---|

Review IDs across configured active and archive paths. Never assign chronology from directory order alone.

## 4. Check planned path overlap

Put every old and new path in a temporary file and run:

```bash
python3 "$SKILL_DIR/scripts/workspace_guard.py" check-plan \
  --repo . --baseline "$BASELINE" --paths-from /tmp/project-governance-paths.txt
```

Remove reported paths from the batch. They remain unchanged and become Blocking report entries. `check-plan` also rejects any path that crosses a submodule or nested Git boundary, is ignored, or falls outside the explicit document whitelist. Ordinary files are limited to `.md`, `.markdown`, `.rst`, and `.txt`; only the selected governance JSON is a non-text exact-path exception; TODO, governance, and canonical instruction still require document extensions. Hard-linked files are denied.

## 5. Separate operations

Prefer separate batches for:

1. configuration, directories, and templates;
2. pure filesystem move/rename operations that leave the Git index unstaged;
3. frontmatter and decision normalization;
4. reference updates;
5. TODO and archive cleanup.

This keeps review and rollback understandable.

## 6. Move without staging

Use:

```bash
mv -- OLD_PATH NEW_PATH
```

Only move clean tracked files. Do not use `git mv`: it updates the index and violates the no-staging boundary. A normal filesystem move leaves the old path deleted and the new path untracked/unstaged; Git can detect the rename during review. An untracked or ignored file protected by the baseline is not eligible for a move.

Do not copy, rewrite, and delete a tracked document in one opaque operation.

## 7. Preserve meaning

Safe normalization includes:

- metadata supported by document content or Git history;
- an ID for a clearly identified Requirement or Spec;
- a structured record of an already-established decision;
- adding semantic identity to a path-only R/S reference while retaining an optional relative link;
- archiving material already known to be superseded or completed.

Unsafe without clarification includes:

- changing requirement wording;
- selecting among competing designs;
- declaring a draft approved;
- merging contradictory documents;
- inventing creation dates, owners, or supersession relationships;
- editing a protected baseline path.

## 8. Repair references

Search the repository while excluding build output, vendored dependencies, fenced examples, and immutable historical snapshots when appropriate.

For R/S documents, preserve semantic identity and optional navigation:

```markdown
参见 S14《Lines model》：[文档](../design/S14-lines-model.md)
```

Only the path-only form requires normalization.

## 9. Verify each batch

```bash
python3 "$SKILL_DIR/scripts/workspace_guard.py" verify --repo . --baseline "$BASELINE"
python3 "$SKILL_DIR/scripts/audit_docs.py" --repo .
git diff --check
git diff --name-status
git status --short
```

Stop further writes if baseline verification fails. Verification must also confirm that every observed path still matches the typed allowlist, remains a non-executable, non-hard-linked text document without a shebang or binary content, does not enter a clean submodule, and has not created or entered a nested Git worktree.

## 10. Idempotence and final report

Run the audit again without edits. Report:

- baseline paths protected and verified unchanged;
- mapping source and paths used;
- files created, moved, normalized, and archived;
- protected or ambiguous items left untouched;
- verification commands and exit results.
