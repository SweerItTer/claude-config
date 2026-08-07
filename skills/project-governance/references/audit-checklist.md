# Governance audit checklist

Audit only what repository evidence supports. `SKILL.md` is the governing semantic contract; scripts must implement it without replacing it with fixed path or string assumptions.

Report **Blocking**, **Fix**, **Improve**, and **Pass**.

## 1. Workspace safety

| Check | Severity when failing |
|---|---|
| Baseline captured before Takeover writes | Blocking |
| Planned source/destination paths do not overlap baseline changes or submodules, do not enter nested Git worktrees, and are persisted as a typed lexical/resolved document-whitelist allowlist | Blocking for affected paths |
| Pre-existing paths retain worktree bytes/type/mode, resolved destination, complete Git index entries/flags, and staged/unstaged/untracked/ignored/index-hidden classification | Blocking |
| Every source/destination was checked lexically and after symlink resolution; missing ignored destinations were detected; relevant ignored paths were enrolled | Blocking |
| No destructive Git command or automatic staging was used | Blocking |
| Every baseline-clean changed path matches plan intent and the explicit `.md`/`.markdown`/`.rst`/`.txt` or exact configured-file whitelist; clean submodules remain clean; complete index entries/flags, HEAD, and branch remain unchanged | Blocking |

Audit-only mode does not require a baseline because it performs no writes. Non-Git creation-only bootstrap does not use the Git guard and must not reference `$BASELINE`.

## 2. Authority and mapping

| Check | Severity when failing |
|---|---|
| Canonical repository instruction source is identifiable through configuration, a filesystem symlink, or a strict one-purpose adapter resolving to the exact repository-relative target; basename mention alone is insufficient, and a missing configured target does not suppress pairwise conflict checks | Blocking if two conflicting sources claim authority; Improve if none exists |
| Detailed governance file exists at the configured path | Fix |
| Custom taxonomy is explicitly mapped | Fix when non-default paths exist but responsibilities cannot be evaluated consistently |
| Mapping contains repository-relative, role-compatible paths; directory roles are pairwise non-overlapping lexically and after Linux symlink resolution | Blocking |
| Existing directory roles are real non-symlink directories or absent; file roles are non-hard-linked documentation files or absent, and lexical/resolved file-role identities do not collide | Blocking |
| Every configured/default path resolves inside the repository after symlink resolution | Blocking |
| Instruction summary points to detailed rules | Improve |


## 2.1 Write-scope whitelist

| Check | Severity when failing |
|---|---|
| Ordinary writable files are limited to `.md`, `.markdown`, `.rst`, and `.txt` | Blocking |
| Only the selected governance JSON is an exact-path extension exception; TODO, governance, and canonical instruction still satisfy the document whitelist; a second config candidate is Blocking | Blocking |
| Executable, shebang, binary, symlink, hard-linked, source, build, linker, Device Tree, board-config, generated, and unknown-extension files are rejected | Blocking |
| Directory plans recursively validate existing contents, and verify revalidates every actual changed file | Blocking |
| Dirty or index-hidden submodules block snapshot; clean submodules retain complete nested index/flags; nested repositories/linked worktrees block when in governance scope or plan | Blocking |

## 3. Taxonomy

| Check | Severity when failing |
|---|---|
| Configured category directories exist | Fix |
| Maintained documents have a clear responsibility | Fix |
| Requirements, Specs, guides, investigations, and history are distinguishable | Fix |
| Governance root is not an unclassified dumping ground | Improve or Fix depending on scale |
| A coherent custom taxonomy is preserved instead of forced into defaults | Blocking if proposed migration would destroy established meaning |

## 4. Stable identity and references

| Check | Severity when failing |
|---|---|
| R/S IDs are unique across identity-bearing Requirement, Spec, and archived R/S documents | Blocking |
| Guides/analyses that merely mention an R/S ID are not counted as identity owners | Pass |
| Existing IDs are preserved and archived IDs are not reused | Blocking |
| Numbered filenames begin with the correct ID | Fix |
| R/S references expose stable semantic identity | Improve |
| Semantic ID plus relative navigation link is accepted | Pass |
| A mutable path is the only visible R/S identity | Improve |

Legal:

```markdown
参见 S14《Lines model》：[文档](docs/specs/S14-lines-model.md)
```

Needs repair:

```markdown
参见 docs/specs/lines-model.md。
```

## 5. Lifecycle and decisions

| Check | Severity when failing |
|---|---|
| Active Specs have required frontmatter | Fix |
| Status and kind values are valid | Fix |
| `updated` is not cosmetically batch-refreshed | Improve |
| Supersession is explicit | Fix when two documents both claim current authority |
| Important decisions include rationale and alternatives | Improve |

## 6. TODO and temporary state

| Check | Severity when failing |
|---|---|
| Configured TODO contains current actionable work | Fix |
| Completed history is archived in the configured archive | Improve |
| Session resume notes and temporary Agent state are not committed as governance | Fix |
| Raw logs are not treated as approved design | Fix |

## 7. Paths, names, and links

| Check | Severity when failing |
|---|---|
| Repository rules contain no developer-machine absolute paths | Fix |
| CommonMark-style relative links resolve outside fenced and inline code examples, including angle destinations, balanced parentheses, titles, and reference-style links; absolute URI schemes and `//host/path` are excluded from local checks | Fix |
| Machine-local path checks are restricted to documentation and instruction files, not source code | Fix |
| Filenames do not encode `v2`, `final`, `latest`, or `new` lifecycle | Fix |
| Explicitly configured directories are scanned even when their names resemble build/install/dist output | Blocking if omitted |
| Document naming is coherent within each configured directory | Improve |

## 8. Migration hygiene

| Check | Severity when failing |
|---|---|
| Tracked clean moves use a filesystem rename/move, never `git mv`, and leave the Git index unstaged | Fix |
| Mapping table exists for non-trivial migrations | Improve |
| Movement and semantic rewriting are reviewable | Improve |
| Protected work and index-hidden paths are skipped; dirty/hidden-flag submodules and nested Git worktrees block before writes; clean submodules are no-touch boundaries with nested index/flag verification | Blocking if touched |

## Report format

```markdown
## Governance audit: repository, date

### Blocking (N)
- code, location, evidence, consequence, repair

### Fix (N)
- code, location, evidence, repair

### Improve (N)
- code, location, evidence, recommendation

### Pass
- check performed and evidence summary
```

A category with no findings says `None`. Passing checks are explicit so the user knows what was inspected.
