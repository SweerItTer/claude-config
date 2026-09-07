---
name: parallel-agent-branching
description: >-
  Orchestrates multi-agent parallel development as a git pipeline: one
  develop/<topic> integration branch, one fix/<task> branch per task per
  subagent, each subagent in its own git worktree, merges folded back one by
  one with --no-ff, then a single reviewer pass over the whole develop diff
  before reporting to the user. Trigger FIRST on explicit multi-agent
  parallel keywords ("多代理并行", "parallel agents", "每个 bug 一个分支",
  "并行开发", "per-task branches", "merge each fix as it completes") — then
  GATE on context: the work must be one cohesive module or a batch of small
  self-contained tasks (bug fixes, small features, cleanups) whose file
  ownership can be partitioned. Do NOT use for work spanning many modules
  with hard cross-module sequencing, for a single trivial task, or when the
  project has no branch/worktree discipline to plug into. Always re-check
  fit against the actual project (branch model, CI, repo rules) before
  committing to the scheme; skip it when unsuitable.
license: CC-BY-SA-4.0
compatibility: Requires git >= 2.30 (worktrees) and a task-delegation tool
  that can run background subagents. Optional: docker for local CI
  rehearsal.
metadata:
  version: "1.1.0"
  category: workflow-orchestration
  language: en
---

# Parallel Agent Branching

Map "one batch of small tasks split across N parallel AI agents" onto a
standard git pipeline: one branch per atomic task, one isolated worktree per
agent, the main session acting only as orchestrator and merger. AI task
granularity is naturally smaller than human task granularity, which sidesteps
the classic "one owner, one huge module, merge-conflict hell" problem.

This skill is domain-agnostic. It works for bug-fix batches, small feature
additions, refactor splits, new-module scaffolding by slices — any work that
decomposes into independently committable, file-partitionable tasks. A
project-specific application is included at the end purely as an example.

## When to use (gate before dispatch)

Trigger candidates arrive via the keywords above, but keywords alone are not
enough. Check all of these; **if any fails, say so and fall back to plain
single-session work**:

1. **Single-module or cleanly partitionable scope.** The tasks must live in
   one cohesive module (or slices whose file ownership can be partitioned
   with no overlaps). Work that inherently threads through many modules in a
   fixed cross-module order is a pipeline, not a parallel batch — do it
   serially instead.
2. **Independent or serializable tasks.** Every task is either independent,
   or its prerequisite chain can be expressed as extra commits on one branch
   (see topology). If the dependency graph is dense, parallel agents only
   add coordination cost.
3. **Each task is small and atomically committable.** If one task needs more
   than one agent or spanning most of the repo, the split is wrong —
   re-decompose first.
4. **The project tolerates branches and worktrees** (repo rules allow
   feature/fix branches; nothing pins all work to one workspace).
5. **Cheap re-verification exists** — a build, test, or lint command that
   can smoke-check after each merge. Without one, merged breakage surfaces
   only at the end.

## Roles

| Role | Owns | Never does |
|---|---|---|
| **Main session (orchestrator)** | Creates develop branch; decomposes tasks; dispatches; merges; runs re-verification and the reviewer pass; reports to the user | Writes business code itself (users explicitly reject this) |
| **Fix agents (×N)** | Edit code and commit on their own branch inside their own worktree | Push; touch files owned by other agents; run repo-wide builds |
| **Reviewer agent** | Read-only review of the full develop diff | Edit anything |

## Branch topology

```
origin/main (or the project's integration base)
  └── develop/<topic>            ← integration branch, the authoritative result
        ├── fix/<task-1>         ← one branch per task, one worktree per agent
        ├── fix/<task-2>
        │   ├── commit A ─┐
        │   └── commit B ─┼─ serial prerequisites = multiple nodes on one branch
        ├── fix/<task-N>   ┘
        (each merged back into develop with --no-ff as it completes)
```

- **One branch = one atomic task.** Serial tasks with prerequisites are
  multiple commits on the same branch; fully independent tasks each get a
  branch.
- Name the integration branch `develop/<topic>`; pick per-branch prefixes
  (`fix/`, `feat/`, `chore/`) by the nature of each task.

## Workflow

### 1. Prepare (main session)

```bash
git fetch origin
git branch develop/<topic> origin/main     # from the latest integration base
git worktree add ../<repo>_<topic>-wt develop/<topic>   # orchestration worktree
```

- **Collect the full task list first** (review findings, bug list, user
  assignments) and give every task a stable short label; branch names and
  commits reuse it.
- If scattered uncommitted changes already exist (another worktree or the
  main workspace), back them up first with `git stash push -m <label>` and
  distribute by file. Never dump half-finished work directly onto develop.

### 2. Dispatch (main session → agents)

Each agent gets its own worktree and cuts its branch from develop:

```bash
git worktree add ../wt_<label> -b fix/<label> develop/<topic>
```

Each assignment states four sections: `# Target` (exact files/symbols),
`# Change` (steps), `# Acceptance` (observable criteria), and
`# Constraints` (coding standards, prohibitions, "commit but never push").
Cross-agent contracts (shared interfaces, file ownership) go into the
batch `context` — never let agents negotiate them among themselves.
**One file belongs to exactly one agent.** If sharing is unavoidable, the
main session serializes that boundary.

### 3. Agent commits and merges

Agents commit inside their own worktree (conventional prefix + emoji, one
atomic unit per task). **The main session performs all merges**:

```bash
cd ../<repo>_<topic>-wt
git merge --no-ff -m "merge: fix/<label> into develop" fix/<label>
```

- `--no-ff` preserves task boundaries; rollback and review stay at branch
  granularity.
- Smoke-verify immediately after each merge (build/test/lint); fix red
  before merging the next branch.
- **A merge conflict means the task split overlapped.** Stop and go back
  to dispatch with redrawn file ownership — never let agents resolve
  conflicts by randomly picking sides.

### 4. Reviewer gate (after all merges)

- Fixed diff scope: `git diff <base>..develop/<topic>`.
- Review brief = the full task-label list plus the project's coding
  standards or governance skills where they exist.
- Findings → one small `fix/<R-number>-<topic>` branch per finding, merged
  back with --no-ff, re-verified, and re-reviewed. Only then report
  success to the user.

### 5. Wrap-up

- develop is the deliverable: push it and open the MR/PR against the repo's
  template.
- Remove every subagent worktree (`git worktree remove`); delete merged
  fix branches.
- If the project has a local CI image, rehearse the gates in docker before
  pushing (see below).

## Local CI rehearsal (when a docker image exists)

Rehearse the same gates as the remote pipeline locally, without producing
pipeline records. Generic recipe — substitute the project's own gate
scripts and product/target names:

```bash
# Build gate: run the repo's build entry point inside the image.
docker run --rm -v "$PWD:/src" -w /src <ci-image> <build-cmd>

# Diff-based static-analysis gate: needs both a compile database / build
# config and git history. Watch out: a worktree's .git is a gitdir pointer
# file with an absolute path back to the main repo, so mounting the
# worktree alone yields "not a git repository". Mount the parent dir and
# inject explicit env:
docker run --rm -v "<main-repo-parent>:/work" \
  -e GIT_DIR=/work/<main-repo>/.git/worktrees/<worktree-name> \
  -e GIT_WORK_TREE=/work/<worktree-name> \
  -w /work/<worktree-name> <ci-image> <gate-cmd> <target> <base-branch>

# Merge gate: verify ancestry locally (base being an ancestor of develop
# guarantees a clean merge).
git merge-base --is-ancestor <base> develop/<topic>
```

## Battle-tested lessons

- **Baseline drift**: `git fetch` before cutting branches. If the base
  advanced during development, re-align the merge base first — never force
  a merge on a stale baseline.
- **A worktree's .git is a pointer file** (gitdir) with an absolute path to
  the main repo. Copying, container-mounting, or archiving a worktree breaks
  it; `git worktree repair` or explicit `GIT_DIR` fixes it.
- **Agent accidents must be recoverable.** Take a stash/worktree backup
  before dispatch; on an external bad reset or lost files, replay from the
  backup instead of making agents redo everything.
- **Never pile changes into the main workspace.** Any stray orchestrator
  edit pollutes later branch splitting; every change must live in some
  fix/* branch commit.
- **Commits are the authoritative state.** Session notes claiming "done"
  are not evidence — trust only
  `git log <base>..develop/<topic>`.

## Worked example (illustrative, not the scope)

A peripheral-subsystem review produced 15 bugs (P0–P3) in one embedded C
module. Applied as: `develop/periph-followups` from origin/main; ~15
`fix/<bug-label>` branches, one agent each in its own worktree; two
order-dependent fixes as two commits on one branch; merges folded in one by
one with a smoke build after each; a reviewer pass over
`origin/main..develop` found 7 more issues, each landed as its own
`fix/R<n>-<label>` branch and re-reviewed; local docker gates rehearsed
before push. Same shape applies unchanged to a batch of small features on a
new module — only the labels differ.
