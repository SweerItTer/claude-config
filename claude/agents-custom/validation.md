# Validation and delivery

## Feature delivery loop

**MUST** — Run in order for every requirement unit:

```
implement → unit test → integration test → smoke/e2e → code review → accept
```

**MUST** — "Done" = end-to-end path verified. Code written ≠ done.

**MUST** — Each step is a separate subtask dispatched by main agent. Main agent reviews output block only.

**SHOULD** — For API / service changes, verify live call chain, not just unit mocks.

---

## Error recovery

**MUST** — On subtask failure:
1. Retry the failed step once with the same subtask prompt
2. On second failure, escalate model tier by one level and retry
3. On third failure, halt and surface to user with full failure summary

**MUST NOT** — Silently loop more than 3 attempts on any single step.

**MUST NOT** — Skip a failed validation step and proceed to the next.

---

## Code review

**MUST** — Every feature branch requires a dedicated review subtask before merge.

**MUST** — Model tier: `sonnet` default · `opus` for security / high-risk / architecture changes.

**MUST** — Review subtask checks:
- Correctness against acceptance criteria
- Error handling and edge cases
- No regressions in affected paths
- Style consistency with codebase

**MUST** — Main agent dispatches a fix subtask if findings require changes. Main agent does not fix directly.

**MUST** — After fix subtask completes, re-run code review subtask. Do not skip re-review.
