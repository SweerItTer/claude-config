---
name: git-workflow
description: >-
  Use for any Git task involving staging, commits, commit-message generation,
  splitting mixed changes into atomic commits, branch/worktree changes, rebases,
  merges, pull requests, releases, or history cleanup. Especially use before
  committing a multi-file or mixed-purpose diff: reconstruct a stable commit
  sequence by responsibility boundary, logical dependency, implementation order,
  rollback boundary, and verification evidence; then generate concise English
  Gitmoji Conventional Commit messages and execute commits only when authorized.
---

# Git Workflow

Keep Git history useful as an engineering record rather than a transcript of edit order.
For commit work, first reconstruct the logical change graph, then stage, verify, and commit one coherent node at a time.

For less common Git operations, load only the relevant reference:

- Branches, worktrees, rebase, merge, conflict handling: `references/branching-history.md`
- Pull requests, releases, tags, and collaboration: `references/collaboration-release.md`
- Configuration, hooks, ignore rules, stash, and recovery commands: `references/tooling-recovery.md`

## Operating Contract

Before changing Git state:

1. Run `git status --short --branch`.
2. Identify the current worktree, branch, staged changes, unstaged changes, and untracked paths.
3. Separate task-owned changes from unrelated or user-owned changes.
4. Preserve unrelated work. Do not reset, clean, stash, stage, amend, or absorb it silently.
5. Prefer explicit paths or `git add -p`; never use `git add .` as a substitute for ownership analysis.

Generating a plan or message does not authorize a commit. Run `git commit` only when the user's task includes committing. Treat push, force-push, rebase, squash, and published-history edits as separate authority boundaries.

## Commit Workflow

Use this workflow whenever there is more than one changed hunk, file, responsibility, or change intent.

```text
inspect workspace
      ↓
trace changed behavior and call/dependency paths
      ↓
assign every task-owned hunk to one responsibility
      ↓
build dependency-ordered atomic commit plan
      ↓
stage one planned slice
      ↓
inspect staged diff + verify slice
      ↓
generate stable commit message
      ↓
commit if authorized
      ↓
repeat
```

Do not let current diff order or edit chronology dictate history. The final commit sequence should explain how the implementation logically comes into existence.

## Atomic Commit Invariant

Each commit should answer one sentence cleanly:

> What behavior or invariant changes, which responsibility owns it, and why can this slice be reviewed and reverted as one unit?

Treat a commit as atomic when:

- it has one primary intent;
- it stays inside one coherent responsibility or rollback boundary;
- every included hunk is necessary for that intent;
- its dependency position is clear;
- it is independently understandable;
- it builds or passes the relevant focused check when the repository permits that boundary;
- reverting it does not silently revert unrelated behavior.

Atomic does not mean one file, one function, or minimum line count. Several files may belong together when they form one inseparable behavior boundary.

## Split Decision Order

When several possible cuts exist, decide in this order. Higher rules override lower ones.

1. **Responsibility / ownership boundary** — separate modules or layers that own different behavior or rollback independently.
2. **Logical dependency** — prerequisites precede the changes that depend on them.
3. **Behavior / invariant** — keep one observable behavior, policy, bug, or internal invariant per commit.
4. **Implementation order** — foundation before owned implementation; implementation before integration/caller wiring.
5. **Change intent** — independently valid `refactor`, `feat`, `fix`, `test`, `docs`, build/config, or mechanical cleanup should not be mixed.
6. **Verification lifecycle** — focused proof may travel with the behavior it exclusively verifies; independent test infrastructure or broad regression coverage may stand alone.
7. **Edit chronology** — use only as supporting evidence, never as the primary split rule.

Never split merely by filename order, directory order, diff order, or an arbitrary line-count target.

## Boundary Classes

Classify changed hunks before staging:

| Boundary | Typical contents | Split when |
|---|---|---|
| Contract | public API, type, ABI, schema, compatibility meaning | consumers depend on the new contract |
| Foundation | reusable helper, primitive, abstraction | independently valid and enables later behavior |
| Implementation | one module's owned production behavior | ownership or rollback differs |
| Integration | caller wiring, routing, registration, lifecycle connection | connects already-valid components |
| Verification | focused tests, fixtures, probes | proof has an independent lifecycle |
| Documentation | user/developer documentation | useful independently of mechanics |
| Fix | correction to an already coherent behavior | discovered after the earlier boundary exists |
| Mechanical | formatting, rename-only, generated/config churn | obscures semantic review |

## Dependency Ordering

Prefer a history shaped like:

```text
contract / primitive
        ↓
owned implementation
        ↓
integration / caller wiring
        ↓
verification / documentation
```

This is a reasoning model, not a mandatory four-commit template.

Apply these constraints:

- Keep a signature change with the minimum required callers when separating them would create a compile-breaking or meaningless intermediate commit.
- Put a preparatory refactor before a feature only when it is behavior-preserving and independently reviewable.
- Put a lower-level implementation before upper-level integration when each boundary can stand alone.
- Keep a focused unit test with its behavior when separating it adds no useful history.
- Split reusable test harnesses, broad regression suites, or independent verification capability when they have their own lifecycle.
- Put documentation after the behavior it describes unless the documentation itself defines a contract.
- Put a defect discovered after a coherent commit into a later `fix` commit rather than hiding it in unrelated work.
- If two proposed commits depend cyclically on each other or either would be false/broken alone, merge them into one larger atomic boundary.

## Commit Plan Gate

Before staging the first slice, establish a plan like:

```text
Commit 1: <proposed message>
Purpose: <one logical change>
Owns: <module or responsibility>
Includes: <paths or hunks>
Depends on: <none or earlier commit>
Evidence: <build/test/static/review checkpoint>

Commit 2: ...
```

The plan is ready only when:

- every task-owned hunk belongs to exactly one planned commit;
- unrelated or user-owned hunks belong to none;
- dependency direction is explicit and acyclic;
- each commit is independently understandable at its chosen boundary;
- the sequence reads naturally in `git log`;
- every proposed message describes the resulting behavior, not the editing activity.

If ownership of a hunk is uncertain, leave it unstaged and surface the ambiguity rather than attaching it to the nearest commit.

## Per-Commit Execution Loop

For each planned commit:

1. Inspect `git status --short`, `git diff`, and `git diff --cached`.
2. Stage only that commit's explicit paths/hunks with explicit paths or `git add -p`.
3. Re-read `git diff --cached`.
4. Confirm all staged hunks satisfy the same atomic invariant.
5. Run the smallest meaningful build/test/static check available for that slice.
6. Generate the message from the staged diff plus the plan intent.
7. Commit only if authorized.
8. Re-check status before moving to the next dependency node.

If verification fails because the proposed split is structurally invalid, revise the boundary. Do not create a known-broken intermediate commit just to keep the diff small.

## Commit Message Contract

Use Gitmoji plus Conventional Commits:

```text
<emoji> <type>(<scope>): <subject>

- <what changed and why>
- <important boundary or behavior detail>
- <verification or limitation when useful>
```

For trivial commits, omit the body when the subject completely explains the change and no rationale or caveat would be lost.

### Type and Gitmoji

Use the semantic type of the atomic slice, not the dominant file extension or largest diff.

| Type | Emoji | Meaning |
|---|---|---|
| `feat` | ✨ | new behavior or capability |
| `fix` | 🐞 | bug fix |
| `docs` | 📝 | documentation-only change |
| `style` | 💄 | formatting/style without behavior change |
| `refactor` | ♻️ | behavior-preserving restructuring |
| `perf` | ⚡️ | performance improvement |
| `test` | ✅ | test-only or independent verification change |
| `build` | 📦 | build system or dependency packaging |
| `ci` | 👷 | CI workflow/configuration |
| `chore` | 🔧 | maintenance/configuration not covered above |
| `i18n` | 🌐 | localization or translation |
| `revert` | ⏪ | explicit revert of an earlier commit |

A mixed diff does not justify a mixed commit. If `refactor + feat`, `fix + formatting`, or `docs + unrelated code` can stand independently, split them first and generate one message per atomic commit.

### Stable Scope Selection

Choose the narrowest stable responsibility a maintainer would search for later.

Prefer, in order:

1. existing repository/module vocabulary;
2. public subsystem or component name;
3. stable internal responsibility;
4. a concise file-family name only when no stronger module concept exists.

Good scopes:

```text
network-runtime
wifi-profile
wpa-control
auth-session
parser
cli-api
```

Avoid volatile or meaningless scopes such as:

```text
core
misc
changes
update
src
issue-123
```

Keep the same scope for the same responsibility across adjacent commits. Do not rename the scope merely because a later commit touches different files in that module.

### Subject Rules

Write the subject in English and make it stable enough to understand months later.

- use imperative mood;
- use lowercase after `:` unless a proper identifier requires otherwise;
- do not end with a period;
- keep the subject text at or below 50 characters when practical;
- name the resulting behavior, not the implementation activity;
- avoid vague verbs such as `update`, `change`, `modify`, `adjust`, `cleanup`, or `handle` unless the object makes the behavior precise.

Prefer:

```text
✨ feat(wifi-runtime): refresh address after reconnect
🐞 fix(wpa-control): preserve scan events during reconnect
♻️ refactor(network-runtime): extract dhcp activation path
```

Avoid:

```text
🔧 chore(core): update files
✨ feat(network): make changes
🐞 fix: fix issue
```

### Body Rules

Use an English bullet body when the rationale, boundary decision, evidence, or limitation is not obvious from the subject.

- use `-` bullets;
- explain what and why, not a line-by-line diff;
- wrap lines to about 72 characters when practical;
- mention verification when it materially increases trust;
- mention deferred behavior only when future maintainers could otherwise misread the commit as complete.

Example:

```text
✨ feat(network-runtime): add explicit dhcp activation

- keep address acquisition under explicit runtime control
- expose dhcp activation without coupling it to wifi enable
- verify with focused network runtime tests
```

## Message-Only Mode

When the user asks only for a commit message or provides a prepared staged diff for naming:

- inspect the supplied/staged diff;
- infer the narrowest valid atomic intent;
- if the diff actually contains several independent atomic changes, return separate proposed messages in dependency order rather than disguising them as one message;
- output only the commit message(s) when the user explicitly requested pure message output;
- do not stage, commit, amend, or push unless separately requested.

## History Quality Check

Before finalizing a commit sequence, ask whether a future maintainer can answer these from `git log` plus one commit diff at a time:

- What responsibility changed?
- Why did it change?
- What prerequisite came before it?
- What behavior did this commit establish?
- Can this commit be reviewed or reverted without dragging unrelated work with it?

If not, revise the split or message.

## Examples

### Good: dependency-ordered feature

```text
♻️ refactor(network-runtime): expose address refresh primitive
✨ feat(wifi-runtime): refresh address after reconnect
✅ test(wifi-runtime): cover reconnect address refresh
```

This is useful only when the refactor and tests truly have independent boundaries. If the first commit cannot stand without the feature, or the test exclusively proves the feature and adds no separate history value, keep them together instead.

### Good: one behavior across several files

A public API declaration, its implementation, and required caller updates may form one commit when splitting them would leave an invalid intermediate state:

```text
✨ feat(wifi-profile): add persistent profile removal
```

Atomicity follows the behavior boundary, not file count.

### Bad: edit transcript

```text
🔧 chore(network): update header
🔧 chore(network): update source
🔧 chore(network): fix compile
✨ feat(network): finish feature
```

This records editing chronology rather than engineering intent.

### Bad: mixed rollback boundaries

```text
✨ feat(network): add dhcp control and refactor parser
```

Split the unrelated parser refactor unless it is a necessary, behavior-preserving prerequisite to the DHCP change.

## Other Git Operations

Do not load generic Git guidance unless the task needs it:

- For branch/worktree creation, switching, merge/rebase, and conflicts, read `references/branching-history.md`.
- For PRs, releases, tags, and review conventions, read `references/collaboration-release.md`.
- For stash, recovery, configuration, hooks, `.gitignore`, and common commands, read `references/tooling-recovery.md`.
