# Git Workflow

## Branch Workflow

Use a dedicated feature branch for each new feature, bug fix, or investigation that may change code.

Before making commits:
1. Check `git status --short`.
2. Identify user-owned changes and do not overwrite or silently absorb unrelated work.
3. Keep local commits frequent enough that recovery is possible if a later change goes wrong.

## Commit Message Format

```text
<emoji> <type>(<scope>): <description>

<optional body>
```

Types: feat, fix, refactor, docs, test, chore, perf, ci.

Emoji should follow the repository's existing history when a project has one. Common defaults:

- `✨ feat(...)`: new functionality or capability
- `🐞 fix(...)`: behavior correction, test/debug fix, regression fix
- `🐳 chore(...)`: tooling, scripts, build plumbing, maintenance
- `📝 docs(...)`: documentation-only changes
- `♻️ refactor(...)`: structure change without intentional behavior change

Note: Attribution disabled globally via ~/.claude/settings.json.

## Atomic Commit Strategy

Commit by intent, not by session.

Required practice:
1. Inspect `git status`, `git diff`, and `git diff --cached` before each commit.
2. Avoid `git add .` when the worktree contains logs, core files, generated artifacts, local debug output, or unrelated user changes.
3. Group changes by the smallest useful functional boundary: base module, integration wiring, behavior fix, config, scripts, docs, third-party binary update, and generated artifact cleanup should be separate commits.
4. A single commit should make it obvious what changed and why from `git show --stat` and the commit message alone.
5. Commit binary/library updates separately from source changes unless the source cannot compile without that exact binary update.
6. If a branch accumulated broad changes, rewrite local history before sharing so the final diff is a sequence of clear atomic commits.

## Feat/Fix Development Rhythm

For exploratory or hardware-heavy work, commits may follow this rhythm:

1. `feat`: land the smallest implementation slice or integration skeleton.
2. `fix`: run focused verification, capture observed failures, and commit the correction.
3. Repeat `feat` -> `fix` until the branch objective is complete.

A `feat` commit does not have to prove the full feature works end-to-end when the feature requires hardware, external services, or staged integration. A `fix` commit should include the evidence-driven correction and should be verified against the failure it addresses.

Do not use this rhythm as an excuse for sloppy commits: each `feat` still needs a coherent scope, and each `fix` should be tied to a concrete failure or validation result.

## Pull Request Workflow

When creating PRs:
1. Analyze full commit history, not just the latest commit.
2. Use `git diff [base-branch]...HEAD` to see all changes.
3. Draft a comprehensive PR summary organized by commit/function area.
4. Include a test plan with completed checks and TODOs.
5. Push with `-u` flag if new branch.

> For the full development process (planning, TDD, code review) before git operations,
> see [development-workflow.md](./development-workflow.md).
