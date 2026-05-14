# Subagent rules

## Model selection

**MUST** — Match model to task type:

| Task type | Model |
|---|---|
| Read / grep / summary / formatting / boilerplate | `haiku` |
| Feature implementation / refactor / moderate logic | `sonnet` |
| Architecture / complex debug / security / high-risk | `opus` |

**MUST NOT** — Default all subtasks to `haiku`. Wrong tier = wasted retries.

---

## Required prompt block

**MUST** — Include verbatim in every Task prompt:

> Tool rules: (1) prefix every shell command with `rtk`. (2) use hook-backed ctx tools for Read/Grep/WebFetch. (3) decompose further only if sub-subtasks are independently parallelisable. (4) run `rtk gain` at end and include savings summary.

**MUST** — Pass minimum context only. Summarise relevant state; never copy conversation history.

---

## Required output format

**MUST** — Every subtask response must end with this block:

```
STATUS: done | failed | blocked
CHANGED: <file list or "none">
TESTS: passed | failed | skipped | n/a
RTK_GAIN: <rtk gain output>
ISSUES: <open issues or "none">
```

Main agent consumes only this block for checkpoint summary.

---

## Concurrency rules

**MUST** — Before dispatching parallel subtasks, assign each a non-overlapping file scope. Two subtasks MUST NOT write to the same file concurrently.

**MUST** — Each parallel subtask operates on its own branch. No subtask commits directly to `main` or `develop`.

**MUST** — Main agent merges branches sequentially after all parallel subtasks complete, not during parallel execution.

**SHOULD** — If file scope cannot be cleanly separated, run subtasks sequentially instead.
