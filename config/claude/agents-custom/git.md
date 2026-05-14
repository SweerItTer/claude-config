# Git conventions

## Branch naming

```
feat/<short-slug>        # new feature
fix/<short-slug>         # bug fix
refactor/<short-slug>    # refactor, no behaviour change
chore/<short-slug>       # tooling, deps, config
review/<source-branch>   # code review branch off source
```

**MUST** — Main agent creates and names all branches. Subtasks commit to their assigned branch only.

---

## Commit format

```
<type>(<scope>): <short description>

<body if needed — what and why, not how>
```

Types: `feat` · `fix` · `refactor` · `chore` · `test` · `docs`

**MUST** — One logical change per commit. Do not bundle unrelated changes.

---

## Merge rules

**MUST** — No direct commits to `main` or `develop` from any subtask.

**MUST** — Main agent merges branches sequentially after all parallel subtasks complete and review passes.

**SHOULD** — Squash commits on merge if branch has more than 3 fixup commits.

---

## Forbidden operations

**MUST NOT** — Execute any of the following:
- `git push --force` or `git push -f`
- `git branch -D` on unmerged branches
- `git reset --hard` without explicit user instruction
- Any modification to `.claude/` directory contents
- `git rebase` on shared branches (`main`, `develop`)

**MUST** — If a task seems to require a forbidden operation, halt and ask user for explicit approval before proceeding.
