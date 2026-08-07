# Documentation governance

> This file is the repository's detailed source for documentation structure, identity, lifecycle, and migration rules. Keep only a concise index in the canonical repository instruction file.

## 1. Repository mapping

The repository uses the following responsibilities. When these paths differ from the default layout, declare the same mapping in `.project-governance.json` so audits and bootstrap scripts evaluate the actual project structure.

| Directory | Responsibility |
|---|---|
| `docs/requirement/` | Required behavior, constraints, and acceptance conditions |
| `docs/specs/` | Architecture, design, approved plans, and trade-offs |
| `docs/dev-guide/` | Repeatable development, build, debug, test, release, and operation procedures |
| `docs/analysis/` | One-time investigation, experiment, evidence, and incident analysis |
| `docs/archive/` | Superseded, completed, rejected, or unmaintained historical documents |

## 2. Stable identity

- Requirements under the configured Requirement path use `R` IDs; Specs under the configured Spec path use `S` IDs.
- Archived Requirement/Spec files preserve those identities. Guides and analyses that mention `Rxx` or `Sxx` do not become identity owners.
- IDs are unique across identity-bearing active and archived documents, never reused, and survive moves.
- Reference a document as `S14《Title》` or `R03《Title》` rather than by path alone.
- Reference a decision as `S14-D7` and a requirement item as `R03-4`.
- A relative link may remain for navigation when the visible text includes the matching semantic ID.

Legal:

```markdown
参见 S14《Title》：[文档](docs/specs/S14-title.md)
```

Path-only identity is not durable:

```markdown
参见 docs/specs/title.md。
```

## 3. Lifecycle

Specs use `draft -> active -> implemented -> archived` and `kind: design|plan`.

Do not encode versions with `v2`, `final`, `latest`, or `new` filenames. Use Git history and supersession metadata.

## 4. Decisions

Consequential Spec decisions record the selected option, rejected alternatives, reason, applicability boundary, and reconsideration condition.

## 5. TODO and archive

- `docs/TODO.md` contains only current actionable work.
- Completed history moves to `docs/archive/todo-history-YYYY-MM-DD.md`.
- Session checkpoints and unverified intermediate conclusions do not become repository governance.
- Archived documents are preserved rather than deleted.

## 6. Workspace protection

- Capture staged, unstaged, ordinary untracked, and index-hidden paths before governance migration.
- Dirty submodules block Takeover; clean submodules are no-touch boundaries. Nested repositories and linked worktrees are unsupported.
- Before every batch, check source and destination paths; lazily enroll ignored files/directories that intersect the plan.
- Compare both lexical paths and resolved in-repository paths so internal symlink aliases cannot bypass protection.
- Allow ordinary writes only to `.md`, `.markdown`, `.rst`, and `.txt`; allow governance JSON and instruction files only at exact configured paths.
- Reject executable, shebang, binary, symlink, source, build, linker, Device Tree, board-config, generated, and unknown-extension files.
- Treat every protected path as read-only.
- Never reset, restore, clean, stash, automatically stage, commit, or switch branches.
- Verify that every actual changed file remains whitelisted and that the index, HEAD, branch, and clean-submodule boundaries remain unchanged.

## 7. Path containment

- Governance paths must be repository-relative.
- Their resolved destinations must remain inside the repository after following symlinks.
- Directory roles must be real non-symlink directories or absent; file roles must be regular non-symlink files or absent.
- Compare directory roles both lexically and after symlink resolution; reject physical equality or ancestor/descendant overlap.
- File roles must not reuse each other, equal a category directory, or contain a category directory.
- Treat an unsafe role, target type, conflict, or external symlink destination as Blocking and do not bootstrap through it.

## 8. Migration

- Build an old-to-new mapping before mass movement.
- Use a filesystem rename/move for clean tracked files; never use `git mv`, because it stages the rename. Leave the Git index untouched for review.
- Separate movement from semantic rewrites.
- Repair references and run governance and workspace verification after each batch.

## 9. Project-specific extensions

Document project-specific naming, extra categories, ownership, and documentation build commands here. Do not create a competing governance file.

## 10. Instruction authority

One canonical instruction file owns repository rules. Additional tool-specific files must be a filesystem symlink or strict one-purpose adapter. A file that says `Ignore AGENTS.md`, `override AGENTS.md`, or adds competing rules is a Blocking conflict.
