# Branching and History Operations

Use this reference only when the task involves branches, worktrees, merge, rebase, conflicts, or branch cleanup.

## Contents

1. Branch/worktree safety
2. Choosing a branch strategy
3. Merge vs rebase
4. Rebase safety
5. Conflict handling
6. Branch naming and cleanup

## 1. Branch and Worktree Safety

Before creating, switching, rebasing, or merging:

```bash
git status --short --branch
```

Identify the current worktree, branch, and every uncommitted path. Do not assume a dirty worktree belongs to the current task.

- Preserve unrelated or user-owned changes.
- If current-task work is complete, prefer committing a coherent boundary before switching.
- If intentionally incomplete and a worktree is impractical, use a uniquely named stash and restore it by captured identity rather than position.
- If ownership is unclear, do not change branch/worktree state until the conflict is resolved.
- Prefer an isolated worktree for parallel or risky work.
- After switching/creating a worktree, rerun status and confirm the expected baseline.

## 2. Choosing a Branch Strategy

### GitHub Flow

Use for simple continuous-delivery workflows:

```text
main
 ├─ feature/user-auth → PR → main
 └─ fix/login-loop    → PR → main
```

Keep `main` deployable and feature branches short-lived.

### Trunk-Based Development

Use when the team has strong CI and feature flags. Keep branches extremely short-lived and integrate frequently.

### GitFlow

Use only when scheduled releases and separate release/hotfix branches justify the added complexity:

```text
main
 └─ develop
     ├─ feature/*
     ├─ release/*
     └─ hotfix/*
```

Do not introduce GitFlow ceremony into a project that does not need release branches.

## 3. Merge vs Rebase

Use merge when preserving shared branch topology matters or the branch is already collaborative/published.

Use rebase to linearize local/private feature history before integration when rewriting those commits is safe.

Never treat rebase as a default cleanup operation on shared history.

## 4. Rebase Safety

Before rebasing:

- fetch the target branch;
- confirm the current branch is not protected/shared in a way that makes rewriting unsafe;
- preserve unrelated working-tree changes;
- verify tests after conflict resolution.

Typical private-branch flow:

```bash
git fetch origin
git rebase origin/main
```

If the rewritten branch was already pushed but is safe to rewrite because no one else depends on it, use `--force-with-lease`, never blind `--force`.

Do not rebase protected branches, already-merged history, or shared commits that others may have based work on.

## 5. Conflict Handling

Inspect conflict state with:

```bash
git status
```

Resolve conflicts by understanding the intended combined behavior rather than mechanically selecting `ours` or `theirs`.

After resolving:

1. inspect the resulting diff;
2. stage only resolved files;
3. run relevant checks;
4. continue the merge/rebase only when the result preserves both the target history and current-task intent.

## 6. Branch Naming and Cleanup

Prefer descriptive names:

```text
feature/user-authentication
fix/login-redirect-loop
hotfix/critical-security-patch
release/1.2.0
experiment/new-cache
```

Delete branches only after confirming they are merged or intentionally disposable. Use safe deletion (`git branch -d`) by default; `-D` is destructive and requires confidence that the branch is no longer needed.
