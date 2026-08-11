# Collaboration and Release

Use this reference for pull requests, reviews, tags, releases, and changelog work.

## Contents

1. Pull request structure
2. Review expectations
3. Release/versioning guidance
4. Tags and changelogs

## 1. Pull Request Structure

Use a title aligned with the dominant delivered behavior:

```text
<type>(<scope>): <description>
```

Keep the PR description focused on:

```markdown
## What
What the change delivers.

## Why
Why the behavior is needed.

## How
Important design/boundary choices.

## Testing
Checks actually run and known limitations.
```

A PR may contain several atomic commits when they form one coherent feature/fix series. Do not squash clear dependency-ordered commits merely to make the PR show one commit.

## 2. Review Expectations

Before requesting review:

- self-review the complete diff;
- confirm the commit sequence is understandable;
- run relevant build/test/lint/static checks;
- make non-obvious ownership, lock, cleanup, ABI, or compatibility constraints visible in code/docs;
- avoid mixing unrelated cleanup into the PR.

Reviewers should be able to inspect each atomic commit independently when that adds clarity.

## 3. Release and Versioning Guidance

Use semantic versioning when the project follows it:

```text
MAJOR.MINOR.PATCH
```

- MAJOR: incompatible API/behavior change
- MINOR: backward-compatible feature
- PATCH: backward-compatible bug fix

Follow repository-specific release policy when it differs.

## 4. Tags and Changelogs

Prefer annotated release tags when releases are formal:

```bash
git tag -a v1.2.0 -m "Release v1.2.0"
git push origin v1.2.0
```

Generate changelog material from stable commit history rather than reconstructing intent from a giant squashed diff:

```bash
git log v1.1.0..v1.2.0 --oneline --no-merges
```

Never push tags or publish releases unless the user requested that action.
