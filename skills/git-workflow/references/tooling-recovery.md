# Git Tooling and Recovery

Use this reference for stash, recovery/undo, hooks, configuration, `.gitignore`, and common command guidance.

## Contents

1. Stash discipline
2. Recovery and undo
3. Useful configuration
4. Hooks
5. Ignore rules

## 1. Stash Discipline

Prefer a commit or isolated worktree when practical. When a stash is necessary, give it a unique label and capture its identity immediately:

```bash
git stash push -u -m "WIP: <task-id>"
git stash list --format='%H %gs'
```

Restore the identified entry, verify paths/status, then drop only that entry. Do not rely on `stash@{0}` remaining the same after other stash operations.

## 2. Recovery and Undo

Choose recovery based on whether history is private or published.

Keep changes while undoing a private last commit:

```bash
git reset --soft HEAD~1
```

Undo a published commit without rewriting history:

```bash
git revert <commit>
```

Avoid `reset --hard`, broad checkout/restore, and force pushes when user-owned changes or shared history may be affected.

## 3. Useful Configuration

Examples, only when appropriate for the user's environment:

```bash
git config --global init.defaultBranch main
git config --global push.default current
git config --global diff.algorithm histogram
```

Do not silently modify global Git configuration.

## 4. Hooks

Pre-commit hooks are useful for fast, deterministic checks such as linting, focused tests, formatting validation, and secret detection. Pre-push hooks can run broader checks.

Keep hooks fast enough that developers do not habitually bypass them, and prefer repository-managed hook tooling when the project already has one.

## 5. Ignore Rules

Ignore generated outputs, dependencies, local environment files, editor artifacts, caches, logs, and secrets according to project conventions.

Typical patterns:

```gitignore
node_modules/
build/
dist/
.env
*.log
.cache/
```

Do not add a file to `.gitignore` merely to hide a task-owned modification that should be reviewed.
