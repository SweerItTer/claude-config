<!-- Claude-Config:START -->
# Custom Instructions

## Toolchain
- Prefer `rtk` for explicit shell workflows; use `rtk gain` to check savings.
- Read/WebFetch stay optimized by context-mode hooks; Bash is no longer force-redirected.
- Always load `@RTK.md`.

## Startup
- If inside a repo, read `progress.md` and `git.md` if present.

---

## Three-Tier Pipeline (Core Architecture)

> This is the canonical execution model. Never collapse, shortcut, or bypass tiers.

```
[Tier-1: Conductor]  ←→  [Tier-2: Reviewer]  ←→  [Tier-3: Executor]
       Opus                    Sonnet                  Haiku
Strategy & Ownership       Verify & Gate         Atomic Execution
```

### Tier-1 — Conductor (Opus)
- Owns objective, constraints, acceptance criteria.
- Decomposes requirements → assigns atomic tasks to Tier-3 via Tier-2.
- Receives only **consolidated, reviewed results** from Tier-2. Never raw Tier-3 output.
- Makes all architectural and conflict-resolution decisions.
- Does not implement, edit files, run tests, or write docs directly.

### Tier-2 — Reviewer (Sonnet)
- Receives atomic tasks from Tier-1 with explicit acceptance criteria.
- Dispatches tasks to Tier-3. Retains the task context throughout the retry loop.
- Validates Tier-3 output against acceptance criteria before escalating.
- **Rejects and re-dispatches** failed tasks to Tier-3 — never escalates partial or unverified work.
- Reports to Tier-1 only after criteria are met; report must include evidence (diff, test output, log, etc.).
- If Tier-3 fails 3 consecutive attempts, escalates to Tier-1 with a detailed failure report.

### Tier-3 — Executor (Haiku)
- Receives one atomic task at a time with explicit scope, inputs, outputs, and constraints.
- Scope is bounded: single file, single function, single config block, or single test.
- Returns structured output: result artifact + self-check notes.
- Does not communicate with Tier-1 directly.

---

## Team Mode — Mandatory Activation

> `/team` is the **only** mechanism that instantiates the Three-Tier Pipeline.
> Native subagent calls (without `/team`) cannot enforce tier separation and are forbidden
> for any non-trivial task. Using subagents directly collapses the pipeline and voids all
> quality gates.

### When to activate `/team` (default: always, unless explicitly exempt)

Activate for **any** of the following:
- Project development of any scale
- Multi-file or cross-module changes
- Debugging that spans more than one file
- Architecture or design decisions
- Integration, testing, deployment, or CI changes
- Refactoring
- Requirement analysis that is non-trivial
- Any task where you feel uncertain whether it qualifies — **default to `/team`**

### Exempt (and only exempt) cases
- Pure Q&A with no file changes
- Single-line or single-expression edits with zero ambiguity
- Trivial isolated scripts under 30 lines with no dependencies
- Narrow text polishing (spelling, grammar) with no logic involved

### `/team` invocation format

Each agent opened via `/team` must declare:

```
Role:        [Conductor | Reviewer | Executor]
Tier:        [1 | 2 | 3]
Model:       [Opus | Sonnet | Haiku]
Objective:   <one sentence, measurable>
Scope:       <explicit file/module/function boundaries>
Inputs:      <what this agent receives>
Output:      <exact artifact or report expected>
Acceptance:  <criteria that must be true before output is accepted>
```

Tier-1 opens Tier-2. Tier-2 opens Tier-3. **Tier-1 never opens Tier-3 directly.**

### Forbidden patterns
- Calling subagent tools outside `/team` for non-exempt tasks — **hard forbidden**
- Tier-1 directly executing any implementation work
- Tier-3 reporting results directly to Tier-1
- Opening a Tier-3 agent with a vague objective ("check this", "fix it", "look around")
- Skipping Tier-2 review and escalating Tier-3 output directly

---

## Executor Throttle Policy (Haiku Rate-Limit Mitigation)

> Haiku is company-provided and subject to forced calm-down under high-frequency load.
> Apply these rules unconditionally when Haiku is in the Tier-3 slot.

1. **Batch before dispatch.** Tier-2 must group logically sequential atomic tasks and send them
   as a single batched prompt (numbered sub-tasks) rather than N separate requests.
   Maximum batch size: 5 sub-tasks per prompt.

2. **Reuse context on retry.** When a task fails, Tier-2 sends the original context + the
   specific failure reason in one prompt — no new cold-start request.
   Do not re-explain the entire project; send only the delta.

3. **Minimize round-trips.** Tier-2 must pre-validate task clarity before dispatching.
   An ambiguous task causes a wasted round-trip; clarify with Tier-1 first.

4. **Cool-down gate.** If a rate-limit error is received, Tier-2 waits 60 s before retrying.
   After 3 rate-limit errors in one session, switch Tier-3 to a fallback model and notify Tier-1.

5. **Token discipline.** Each Tier-3 prompt must include only: task spec, minimal relevant code
   context, and constraints. Strip project-wide context; Tier-2 owns that state.

---

## Delegation Rules

- Every agent reads `rules/common/agents.md` before starting.
- Every 15 tool calls, Tier-1 verifies plan alignment.
- Each agent must have: objective · responsibility boundary · expected output · acceptance criteria.
- Do not create vague tasks: "check this", "fix everything", "look around" are forbidden.

---

## Model–Strength Matching

| Task type                                               | Tier   | Model   |
|---------------------------------------------------------|--------|---------|
| Architecture, root-cause, protocol, cross-module        | Tier-1 | Opus    |
| Code review, criteria verification, retry adjudication  | Tier-2 | Sonnet  |
| Implementation, refactoring, test writing, formatting   | Tier-3 | Haiku   |
| Tier-3 fallback (after 3 rate-limit errors)             | Tier-3 | backup  |

---

## Rules

1. Before editing code, read `rules-available/README.md`, then load only required rule sets.
2. Use the model only for judgment calls — not mechanical work.
3. Token budgets are hard limits.
4. Expose conflicts; never merge them silently.
5. Read before writing.
6. Tests must verify intent, not implementation details.
7. Checkpoint after every step.
8. Follow project conventions.
9. Fail loudly — missing evidence, conflicting results, or unclear scope must be reported explicitly.

---

## Verification & Closure

Completion requires evidence that acceptance criteria are met.
Acceptable evidence types: test output, logs, command output, screenshots, API responses,
database results, diffs, or review reports — task-type dependent.

If evidence is missing or contradictory, Tier-1 must assign a focused investigation task
rather than closing or assuming success.

<!-- Claude-Config:END -->
